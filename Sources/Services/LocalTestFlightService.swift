import Foundation

enum LocalUploadMethod: Equatable {
    case script(path: String, arguments: [String])
    case fastlane(lane: String)
    case builtIn
}

/// Local-only TestFlight strategy: project script, local Fastlane lane, then
/// native IPA packaging + altool upload. It never pushes tags or invokes CI.
@MainActor
final class LocalTestFlightService {
    let runner: ShellRunner

    init(runner: ShellRunner) { self.runner = runner }

    func method(for app: AppProject) -> LocalUploadMethod {
        if let script = preferredScript(for: app) { return script }
        if let lane = app.release.betaLane, fastfileContains(lane: lane, app: app) {
            return .fastlane(lane: lane)
        }
        return .builtIn
    }

    func upload(app: AppProject) async -> RunResult {
        switch method(for: app) {
        case .script(let path, let arguments):
            runner.log("▶ 本地 TestFlight 脚本 — \((path as NSString).lastPathComponent)")
            var env = CredentialEnv.build(for: app)
            env["DEVOPS_ASSISTANT_ALLOW_DIRTY_LOCAL"] = "true"
            let key = TemporaryAPIKey()
            if let key { env["APP_STORE_CONNECT_KEY_PATH"] = key.url.path }
            return await runner.run(executable: "/bin/bash", args: [path] + arguments,
                                    cwd: app.resolvedPath, env: env, timeout: 3600)
        case .fastlane(let lane):
            runner.log("ℹ 未检测到本地上传脚本，使用项目本地 Fastlane lane")
            return await FastlaneRunner(runner: runner).runLane(lane, app: app)
        case .builtIn:
            return await builtInUpload(app: app)
        }
    }

    private func builtInUpload(app: AppProject) async -> RunResult {
        runner.log("ℹ 未检测到上传脚本或 Fastlane beta lane，使用内置 IPA + altool")
        let artifact = await ArtifactPackagingService(runner: runner).packageIPA(app: app)
        guard artifact.succeeded, let ipa = artifact.path else {
            return artifact.result
        }
        // Packaging succeeded — its exit code says nothing about the upload
        // below. A missing/unreadable ASC key here must NOT be reported as a
        // successful upload (that once made the release pipeline record a
        // "shipped" build Apple never received).
        guard let key = TemporaryAPIKey() else {
            runner.log("✗ ASC API 密钥不可用 — 请在「凭据设置」检查 .p8 / Key ID / Issuer ID")
            return RunResult(exitCode: -1, cancelled: false)
        }
        runner.log("▶ altool 上传 TestFlight — \(app.name)")
        return await runner.run(executable: "/usr/bin/xcrun", args: [
            "altool", "--upload-app", "-f", ipa, "-t", "ios",
            "--api-key", key.keyID, "--api-issuer", key.issuerID,
            "--p8-file-path", key.url.path
        ], cwd: app.resolvedPath, timeout: 3600)
    }

    private func preferredScript(for app: AppProject) -> LocalUploadMethod? {
        let candidates: [(String, [String])] = [
            ("scripts/submit_testflight.sh", ["--local"]),
            ("scripts/resume_testflight.sh", []),
            ("scripts/upload-testflight.sh", []),
            ("scripts/upload_testflight.sh", []),
        ]
        for (relative, args) in candidates {
            let path = "\(app.resolvedPath)/\(relative)"
            if FileManager.default.fileExists(atPath: path) { return .script(path: path, arguments: args) }
        }
        return nil
    }

    private func fastfileContains(lane: String, app: AppProject) -> Bool {
        guard let text = try? String(contentsOfFile: "\(app.resolvedPath)/fastlane/Fastfile", encoding: .utf8) else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: lane)
        return text.range(of: #"lane\s*:\s*\#(escaped)\b"#, options: .regularExpression) != nil
    }

}
