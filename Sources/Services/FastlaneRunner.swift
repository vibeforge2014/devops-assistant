import Foundation

/// Builds the credential environment variables that fastlane/xcodebuild expect,
/// read from the central Keychain. This is the bridge between KeychainStore
/// (storage) and ShellRunner (execution) — it never persists anything itself.
struct CredentialEnv {
    /// A map suitable for passing to `ShellRunner.run(_:env:)`.
    static func build() -> [String: String] {
        var env: [String: String] = [:]

        // Apple team id (used by cert/sigh/match defaults).
        if let teamID = KeychainStore.get(.appleTeamID) {
            env["TEAM_ID"] = teamID
            env["APPLE_TEAM_ID"] = teamID
            env["ITC_TEAM_ID"] = teamID
        }

        // App Store Connect API key auth.
        if let keyID = KeychainStore.get(.ascAPIKeyID) {
            env["APP_STORE_CONNECT_KEY_ID"] = keyID
        }
        if let issuer = KeychainStore.get(.ascIssuerID) {
            env["APP_STORE_CONNECT_ISSUER_ID"] = issuer
        }
        if let content = KeychainStore.get(.ascAPIKeyContent) {
            // fastlane accepts base64-encoded key content directly.
            env["APP_STORE_CONNECT_KEY_CONTENT"] = Data(content.utf8).base64EncodedString()
        } else if let keyID = KeychainStore.get(.ascAPIKeyID) {
            // Fall back to the on-disk key file convention.
            env["APP_STORE_CONNECT_KEY_PATH"] = "\(home)/.appstoreconnect/private_keys/AuthKey_\(keyID).p8"
        }

        // match (encrypted git repo) credentials.
        if let pw = KeychainStore.get(.matchPassword) {
            env["MATCH_PASSWORD"] = pw
        }
        if let url = KeychainStore.get(.matchGitURL) {
            env["MATCH_GIT_URL"] = url
        }

        // Apple ID + app-specific password (used by notarytool's Apple-ID auth
        // and as a fastlane fallback when no ASC API Key is available).
        if let appleID = KeychainStore.get(.appleID) {
            env["APPLE_ID"] = appleID
            env["FASTLANE_APPLE_ID"] = appleID
        }
        if let asp = KeychainStore.get(.appSpecificPassword) {
            env["FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD"] = asp
            env["NOTARYTOOL_APPLE_ID"] = KeychainStore.get(.appleID) ?? ""
            env["NOTARYTOOL_PASSWORD"] = asp
        }

        return env
    }

    private static var home: String {
        NSHomeDirectory()
    }
}

/// Drives fastlane lanes for projects whose `release.engine == .fastlane`.
/// It delegates to the project's existing Fastfile rather than redefining any
/// lane — the assistant only injects credentials and surfaces output.
@MainActor
final class FastlaneRunner {
    let runner: ShellRunner

    init(runner: ShellRunner) {
        self.runner = runner
    }

    /// Run a fastlane lane for an app, injecting credential env.
    @discardableResult
    func runLane(_ lane: String, app: AppProject, platform: String = "ios") async -> RunResult {
        let cmd = "bundle exec fastlane \(platform) \(lane)"
        runner.log("▶ fastlane \(platform) \(lane) — \(app.name)")
        return await runner.run(cmd, cwd: app.resolvedPath, env: CredentialEnv.build())
    }

    /// Whether fastlane is installed and available on PATH.
    static var isAvailable: Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which fastlane"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
