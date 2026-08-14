import Foundation
import CryptoKit

enum CredentialValidationStatus: Equatable {
    case passed, warning, failed
}

struct CredentialValidationResult: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let guidance: String?
    let status: CredentialValidationStatus
}

/// Validates syntax, local signing material, Apple authentication and Match
/// repository/password access without uploading or changing remote state.
struct CredentialValidationService {
    static func validate(catalog: ProjectCatalogData) async -> [CredentialValidationResult] {
        let snapshot = Snapshot(catalog: catalog)
        return await Task.detached(priority: .userInitiated) { snapshot.validate() }.value
    }

    /// Build an App Store Connect ES256 JWT directly from .p8 key material.
    /// Returns nil if the PEM can't be loaded as a P-256 key (malformed / wrong
    /// type). Replaces the deprecated `xcrun altool --generate-jwt`. Exposed for
    /// tests and reuse by other services.
    static func makeES256JWT(keyContent: String, keyID: String, issuerID: String) -> String? {
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: keyContent)
        } catch { return nil }
        let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
        let now = Int(Date().timeIntervalSince1970)
        let payload = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 1200),"aud":"appstoreconnect-v1"}"#
        let signingInput = "\(b64url(header)).\(b64url(payload))"
        guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else {
            return nil
        }
        return "\(signingInput).\(b64url(signature.rawRepresentation))"
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func b64url(_ string: String) -> String {
        b64url(Data(string.utf8))
    }

    private struct Snapshot: @unchecked Sendable {
        let keyContent: String?
        let keyID: String?
        let issuerID: String?
        let teamID: String?
        let appleID: String?
        let appPassword: String?
        let matchPassword: String?
        let matchURLs: [String]

        init(catalog: ProjectCatalogData) {
            keyContent = KeychainStore.get(.ascAPIKeyContent)
            keyID = KeychainStore.get(.ascAPIKeyID)
            issuerID = KeychainStore.get(.ascIssuerID)
            teamID = KeychainStore.get(.appleTeamID)
            appleID = KeychainStore.get(.appleID)
            appPassword = KeychainStore.get(.appSpecificPassword)
            matchPassword = KeychainStore.get(.matchPassword)
            matchURLs = Array(Set(catalog.apps.compactMap(\.release.matchGitURL))).sorted()
        }

        func validate() -> [CredentialValidationResult] {
            var results: [CredentialValidationResult] = []
            results.append(validateASC())
            results.append(validateTeam())
            results.append(contentsOf: validateMatch())
            results.append(validateAppleIDFallback())
            return results
        }

        private func validateASC() -> CredentialValidationResult {
            guard let keyContent, !keyContent.isEmpty,
                  let keyID, keyID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
                  let issuerID, UUID(uuidString: issuerID) != nil else {
                return .init(id: "asc", title: "App Store Connect API Key",
                             detail: "缺失或格式不正确", guidance: "导入 AuthKey_XXXXXXXXXX.p8，并填写 10 位 Key ID 与 Issuer UUID。",
                             status: .failed)
            }
            // Generate the ASC JWT natively (ES256) instead of the deprecated
            // `xcrun altool --generate-jwt`. Loading the key via CryptoKit also
            // validates its integrity, replacing the old `openssl pkey` parse.
            guard let token = CredentialValidationService.makeES256JWT(keyContent: keyContent,
                                                                        keyID: keyID, issuerID: issuerID) else {
                return .init(id: "asc", title: "App Store Connect API Key",
                             detail: "私钥内容无法解析或签名失败", guidance: "请使用 App Store Connect 下载的原始 .p8 文件，并确认 Key ID 匹配。", status: .failed)
            }
            // A read-only apps listing validates the JWT against Apple without
            // creating builds or changing App Store Connect state.
            let remote = command("/usr/bin/curl", ["--silent", "--show-error", "--output", "/dev/null",
                "--write-out", "%{http_code}", "--header", "Authorization: Bearer \(token)",
                "https://api.appstoreconnect.apple.com/v1/apps?limit=1"], timeout: 45)
            if remote.status == 0 && remote.output.trimmingCharacters(in: .whitespacesAndNewlines) == "200" {
                return .init(id: "asc", title: "App Store Connect API Key",
                             detail: "Apple 认证成功", guidance: nil, status: .passed)
            }
            return .init(id: "asc", title: "App Store Connect API Key",
                         detail: "Apple 认证失败（HTTP \(remote.output.trimmingCharacters(in: .whitespacesAndNewlines))）",
                         guidance: "确认 Key ID、Issuer ID 属于同一把有效密钥，且角色至少为 App Manager。", status: .failed)
        }

        private func validateTeam() -> CredentialValidationResult {
            guard let teamID, teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
                return .init(id: "team", title: "Apple Team ID", detail: "缺失或格式不正确",
                             guidance: "填写 Apple Developer Membership 页面中的 10 位 Team ID。", status: .failed)
            }
            let identities = command("/usr/bin/security", ["find-identity", "-p", "codesigning", "-v"])
            let hasDistribution = identities.output.contains("Apple Distribution:") && identities.output.contains("(\(teamID))")
            return .init(id: "team", title: "Apple Team ID",
                         detail: hasDistribution ? "已找到对应 Apple Distribution 证书" : "Team ID 有效，但本机缺少对应分发证书",
                         guidance: hasDistribution ? nil : "先运行项目签名脚本或 Fastlane certs/match 安装分发证书。",
                         status: hasDistribution ? .passed : .warning)
        }

        private func validateMatch() -> [CredentialValidationResult] {
            guard !matchURLs.isEmpty else { return [] }
            guard let matchPassword, !matchPassword.isEmpty else {
                return [.init(id: "match-password", title: "Match 签名（可选）", detail: "未配置，已跳过",
                              guidance: "仅当项目使用 Fastlane Match 管理证书时才需要填写。", status: .warning)]
            }
            return matchURLs.map { url in
                let slug = URL(fileURLWithPath: url).deletingPathExtension().lastPathComponent
                let reachable = command("/usr/bin/git", ["ls-remote", url, "HEAD"], timeout: 30)
                guard reachable.status == 0 else {
                    return .init(id: "match-\(url)", title: "Match · \(slug)",
                                 detail: "仓库不可访问", guidance: "检查仓库地址和本机 SSH/GitHub 权限。", status: .failed)
                }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vibeforge-match-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                let fastlaneTemp = temp.appendingPathComponent("fastlane", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: fastlaneTemp,
                                                            withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                } catch {
                    return .init(id: "match-\(url)", title: "Match · \(slug)", detail: "无法创建临时检查目录",
                                 guidance: "检查系统临时目录权限后重试。", status: .failed)
                }

                // `MATCH_GIT_URL` is not consumed by the standalone
                // `fastlane match decrypt` command. The URL must be supplied
                // explicitly; otherwise Fastlane exits with "No value found
                // for git_url", which was previously misreported as a bad
                // password. Keep Fastlane's clone beneath our disposable
                // directory so repeated checks do not leave decrypted files.
                let decrypt = command(
                    "/usr/bin/env",
                    ["fastlane", "match", "decrypt", "--git_url", url],
                    cwd: temp.path,
                    env: ["MATCH_PASSWORD": matchPassword,
                          "FASTLANE_SKIP_UPDATE_CHECK": "true",
                          "TMPDIR": fastlaneTemp.path],
                    timeout: 60
                )
                let output = decrypt.output.lowercased()
                let passwordRejected = output.contains("invalid password") ||
                    output.contains("bad decrypt") || output.contains("wrong final block")
                let toolMissing = output.contains("no such file or directory") ||
                    output.contains("not found") || output.contains("command not found")
                let failureDetail: String
                let failureGuidance: String
                if toolMissing {
                    failureDetail = "未找到 fastlane 命令"
                    failureGuidance = "本机 PATH 未包含 fastlane。通过 Homebrew 安装 (brew install fastlane)，或确认 app 能解析到 /opt/homebrew/bin。"
                } else if passwordRejected {
                    failureDetail = "仓库可访问，但密码无法解密"
                    failureGuidance = "确认该密码属于当前证书仓库；不同 Match 仓库可能使用不同密码。"
                } else {
                    failureDetail = "Fastlane 解密检查失败"
                    failureGuidance = "仓库和密码未被判定为错误，请检查本机 Fastlane 配置后重试。"
                }
                return .init(id: "match-\(url)", title: "Match · \(slug)",
                             detail: decrypt.status == 0 ? "仓库与解密密码有效" : failureDetail,
                             guidance: decrypt.status == 0 ? nil : failureGuidance,
                             status: decrypt.status == 0 ? .passed : .failed)
            }
        }

        private func validateAppleIDFallback() -> CredentialValidationResult {
            let present = !(appleID?.isEmpty ?? true) && !(appPassword?.isEmpty ?? true)
            return .init(id: "apple-id", title: "Apple ID 备用认证",
                         detail: present ? "已配置（ASC API Key 可用时不会使用）" : "未配置（可选）",
                         guidance: present ? nil : "仅在需要 Apple ID 登录的旧脚本中录入 Apple ID 与 App 专用密码。",
                         status: .warning)
        }
    }

    private static func command(_ executable: String, _ arguments: [String], cwd: String? = nil,
                                env: [String: String] = [:], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var merged = ProcessInfo.processInfo.environment
        // GUI apps inherit launchd's minimal PATH (no Homebrew). Mirror
        // ShellRunner so PATH-resolved tools such as `fastlane` are found;
        // without this the Match decrypt check fails with "command not found",
        // which the password heuristics below misreport as a decryption error.
        if env["PATH"] == nil {
            merged["PATH"] = DeveloperToolPath.resolved(inheritedPath: merged["PATH"])
        }
        merged.merge(env) { _, new in new }
        process.environment = merged
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeforge-validation-log-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { return (-1, "无法创建验证日志") }
        process.standardOutput = log
        process.standardError = log
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? log.synchronize()
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }

}
