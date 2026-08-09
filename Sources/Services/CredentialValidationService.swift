import Foundation

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
            guard let temp = makeKeyFile(content: keyContent, keyID: keyID) else {
                return .init(id: "asc", title: "App Store Connect API Key",
                             detail: "无法创建临时验证文件", guidance: "重新导入 .p8 文件。", status: .failed)
            }
            defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
            // macOS ships LibreSSL, whose `openssl pkey` command does not
            // support OpenSSL 3's `-check` flag (it interprets "check" as an
            // unknown cipher). Parsing the key with `-noout` is the portable
            // local integrity check; JWT generation and Apple's read-only API
            // request below verify that the key is also usable and authorized.
            let parse = command("/usr/bin/openssl", ["pkey", "-in", temp.path, "-noout"])
            guard parse.status == 0 else {
                return .init(id: "asc", title: "App Store Connect API Key",
                             detail: "私钥内容无法解析", guidance: "请使用 App Store Connect 下载的原始 .p8 文件。", status: .failed)
            }
            let generated = command("/usr/bin/xcrun", ["altool", "--generate-jwt",
                "--apiKey", keyID, "--apiIssuer", issuerID, "--p8-file-path", temp.path], timeout: 20)
            guard generated.status == 0,
                  let token = extractJWT(from: generated.output) else {
                return .init(id: "asc", title: "App Store Connect API Key",
                             detail: "无法使用私钥生成认证令牌", guidance: "确认 Key ID 与 .p8 文件匹配。", status: .failed)
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

        /// `altool --generate-jwt` writes explanatory text and the JWT to the
        /// same stream. Some explanatory tokens also contain two periods, so
        /// merely counting segments can select the wrong value and cause a
        /// misleading HTTP 401. A JWT is exactly three non-empty Base64URL
        /// segments separated by periods.
        private func extractJWT(from output: String) -> String? {
            output.split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .first { candidate in
                    let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
                    guard segments.count == 3 else { return false }
                    return segments.allSatisfy { segment in
                        !segment.isEmpty && segment.allSatisfy { character in
                            character.isLetter || character.isNumber || character == "-" || character == "_"
                        }
                    }
                }
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
                let failureDetail = passwordRejected ? "仓库可访问，但密码无法解密" : "Fastlane 解密检查失败"
                let failureGuidance = passwordRejected
                    ? "确认该密码属于当前证书仓库；不同 Match 仓库可能使用不同密码。"
                    : "仓库和密码未被判定为错误，请检查本机 Fastlane 配置后重试。"
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

    private static func makeKeyFile(content: String, keyID: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vibeforge-validation-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("AuthKey_\(keyID).p8")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(content.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { try? fm.removeItem(at: dir); return nil }
    }

    private static func command(_ executable: String, _ arguments: [String], cwd: String? = nil,
                                env: [String: String] = [:], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var merged = ProcessInfo.processInfo.environment
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
