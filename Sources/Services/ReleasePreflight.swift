import Foundation

enum PreflightStatus: Int, Comparable {
    case passed
    case warning
    case failed

    static func < (lhs: PreflightStatus, rhs: PreflightStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PreflightCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let status: PreflightStatus
}

/// Fast, read-only checks that make release failures visible before any version
/// file, archive, remote repository, or App Store state is changed.
struct ReleasePreflight {
    static func run(app: AppProject,
                    target: ReleaseTarget,
                    catalog: ProjectCatalogData) -> [PreflightCheck] {
        var checks: [PreflightCheck] = []
        let fm = FileManager.default

        checks.append(.init(
            id: "path",
            title: "项目路径",
            detail: app.existsOnDisk ? app.resolvedPath : "路径不存在: \(app.resolvedPath)",
            status: app.existsOnDisk ? .passed : .failed
        ))

        let projectFileExists = fm.fileExists(atPath: "\(app.resolvedPath)/project.yml") ||
            firstXcodeProject(in: app.resolvedPath) != nil
        checks.append(.init(
            id: "project",
            title: "工程文件",
            detail: projectFileExists ? "已找到 project.yml 或 .xcodeproj" : "未找到可构建工程",
            status: projectFileExists ? .passed : .failed
        ))

        if let version = VersionManager.read(app) {
            let marketingOK = version.marketing.range(
                of: #"^\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            ) != nil
            let buildOK = Int(version.build).map { $0 >= 0 } ?? false
            checks.append(.init(
                id: "version",
                title: "版本号",
                detail: "\(version.marketing) (\(version.build))",
                status: marketingOK && buildOK ? .passed : .failed
            ))
        } else {
            checks.append(.init(id: "version", title: "版本号",
                                detail: "无法读取 MARKETING_VERSION / CURRENT_PROJECT_VERSION",
                                status: .failed))
        }

        checks.append(contentsOf: engineChecks(app: app, target: target))
        checks.append(contentsOf: credentialChecks(app: app, target: target))

        // When the macOS flow will publish a GitHub Release, confirm gh is
        // installed and authenticated up front so the failure is visible before
        // a long build/notarize runs.
        if target == .macDistribution, app.releaseRepoSlug != nil {
            let gh = command("/usr/bin/env", ["gh", "auth", "status"], cwd: nil)
            checks.append(.init(
                id: "gh",
                title: "GitHub Release 发布",
                detail: gh.status == 0
                    ? "gh 已认证 → \(app.releaseRepoSlug!)"
                    : "gh 未安装或未登录（运行 `gh auth login`）",
                status: gh.status == 0 ? .passed : .failed
            ))
        }

        if fm.fileExists(atPath: "\(app.resolvedPath)/.git") {
            let git = command("/usr/bin/git", ["status", "--porcelain"], cwd: app.resolvedPath)
            let dirty = !git.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            checks.append(.init(
                id: "git",
                title: "Git 工作区",
                detail: git.status != 0 ? "无法读取 Git 状态" : (dirty ? "存在未提交修改,发布前请确认" : "工作区干净"),
                status: git.status != 0 ? .failed : (dirty ? .warning : .passed)
            ))
        } else {
            checks.append(.init(id: "git", title: "Git 工作区",
                                detail: "项目目录不是 Git 仓库",
                                status: .warning))
        }

        if let portal = catalog.sites.first(where: { $0.id == "portal" }) {
            let products = "\(portal.resolvedPath)/src/data/products.ts"
            let text = try? String(contentsOfFile: products, encoding: .utf8)
            let mapped = text?.range(of: #"id:\s*"\#(app.id)""#,
                                     options: .regularExpression) != nil
            checks.append(.init(
                id: "portal",
                title: "Portal 映射",
                detail: mapped ? "已映射产品 \(app.id)" : "Portal 中未找到产品 \(app.id);发布可继续但不会同步",
                status: mapped ? .passed : .warning
            ))
        }

        return checks
    }

    private static func engineChecks(app: AppProject, target: ReleaseTarget) -> [PreflightCheck] {
        guard ReleaseTarget.available(for: app).contains(target) else {
            return [.init(id: "target", title: "发布目标",
                          detail: "当前引擎不支持 \(target.title)", status: .failed)]
        }
        if target == .testFlight, let script = localUploadScript(for: app) {
            return [.init(id: "local-script", title: "本地上传方式",
                          detail: "优先使用 \((script as NSString).lastPathComponent)", status: .passed)]
        }
        if target == .testFlight, app.release.engine == .native {
            let identity = command("/usr/bin/security", ["find-identity", "-p", "codesigning", "-v"], cwd: nil)
            let found = identity.output.contains("Apple Distribution:")
            return [
                .init(id: "builtin-upload", title: "本地上传方式",
                      detail: "内置 IPA + altool", status: .passed),
                .init(id: "distribution-id", title: "Apple Distribution",
                      detail: found ? "已找到分发证书" : "本机没有 Apple Distribution 证书",
                      status: found ? .passed : .failed)
            ]
        }
        guard app.release.engine == .fastlane else {
            let identity = command("/usr/bin/security",
                                   ["find-identity", "-p", "codesigning", "-v"], cwd: nil)
            let found = identity.output.contains("Developer ID Application")
            return [.init(id: "developer-id", title: "Developer ID",
                          detail: found ? "已找到 Developer ID Application" : "钥匙串中没有 Developer ID Application",
                          status: found ? .passed : .failed)]
        }

        let fastfile = "\(app.resolvedPath)/fastlane/Fastfile"
        guard let text = try? String(contentsOfFile: fastfile, encoding: .utf8) else {
            return [.init(id: "fastfile", title: "Fastfile",
                          detail: "找不到 fastlane/Fastfile", status: .failed)]
        }
        var checks: [PreflightCheck] = [
            .init(id: "fastfile", title: "Fastfile", detail: "已找到 Fastfile", status: .passed)
        ]
        let uploadLane = target == .testFlight ? app.release.betaLane : app.release.releaseLane
        if let uploadLane {
            let found = containsLane(uploadLane, in: text)
            checks.append(.init(id: "upload-lane", title: "上传 lane",
                                detail: found ? uploadLane : "Fastfile 中缺少 \(uploadLane)",
                                status: found ? .passed : .failed))
        }
        if let signingLane = app.release.signingLane {
            let found = containsLane(signingLane, in: text)
            checks.append(.init(id: "signing-lane", title: "签名 lane",
                                detail: found ? signingLane : "Fastfile 中缺少 \(signingLane)",
                                status: found ? .passed : .failed))
        }
        let bundle = command("/bin/zsh", ["-l", "-c", "bundle check"], cwd: app.resolvedPath)
        checks.append(.init(id: "bundle", title: "Bundler 依赖",
                            detail: bundle.status == 0 ? "依赖完整" : "bundle check 失败,请先执行 bundle install",
                            status: bundle.status == 0 ? .passed : .failed))
        return checks
    }

    private static func localUploadScript(for app: AppProject) -> String? {
        let candidates = ["scripts/submit_testflight.sh", "scripts/resume_testflight.sh",
                          "scripts/upload-testflight.sh", "scripts/upload_testflight.sh"]
        return candidates.map { "\(app.resolvedPath)/\($0)" }
            .first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func credentialChecks(app: AppProject,
                                         target: ReleaseTarget) -> [PreflightCheck] {
        let hasTeam = KeychainStore.exists(.appleTeamID)
        let hasASC = KeychainStore.exists(.ascAPIKeyContent) &&
            KeychainStore.exists(.ascAPIKeyID) && KeychainStore.exists(.ascIssuerID)
        let hasAppleID = KeychainStore.exists(.appleID) &&
            KeychainStore.exists(.appSpecificPassword)
        let authOK = target == .macDistribution ? hasASC : (hasASC || hasAppleID)
        var checks: [PreflightCheck] = []
        if target != .macDistribution {
            checks.append(.init(id: "team", title: "Apple Team ID",
                                detail: hasTeam ? "已配置" : "未配置",
                                status: hasTeam ? .passed : .failed))
        }
        checks.append(
            .init(id: "auth", title: "Apple 发布认证",
                  detail: authOK ? (hasASC ? "ASC API Key" : "Apple ID") :
                    (target == .macDistribution ? "macOS 公证需要 ASC API Key" : "未配置 ASC API Key 或 Apple ID"),
                  status: authOK ? .passed : .failed)
        )
        if app.release.signing == .match {
            let hasMatchURL = !(app.release.matchGitURL?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                KeychainStore.exists(.matchGitURL)
            let matchOK = KeychainStore.exists(.matchPassword) && hasMatchURL
            checks.append(.init(id: "match", title: "Match 凭据",
                                detail: matchOK ? "仓库与密码已配置" : "缺少 Match 仓库或密码",
                                status: matchOK ? .passed : .failed))
        }
        return checks
    }

    private static func containsLane(_ lane: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: lane)
        return text.range(of: #"lane\s*:\s*\#(escaped)\b"#,
                          options: .regularExpression) != nil
    }

    private static func firstXcodeProject(in path: String) -> String? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
            .first(where: { $0.hasSuffix(".xcodeproj") })
    }

    private static func command(_ executable: String,
                                _ arguments: [String],
                                cwd: String?) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
