import Foundation

/// Drives macOS Developer-ID signing and notarization for apps whose
/// `release.notarize == true` (ChargePilot). Delegates to the bundled
/// `codesign-mac.sh` and `notarize.sh` scripts so the actual notarytool /
/// codesign invocations live in one audited shell file.
@MainActor
final class NotaryService {
    let runner: ShellRunner

    init(runner: ShellRunner) {
        self.runner = runner
    }

    /// Locate the bundled scripts directory.
    private var scriptsDir: String {
        Bundle.main.resourcePath ?? ""
    }

    /// Sign a .app bundle with Developer ID.
    @discardableResult
    func signAppBundle(at appPath: String, entitlements: String? = nil) async -> RunResult {
        var env: [String: String] = CredentialEnv.build()
        if let entitlements { env["ENTITLEMENTS"] = entitlements }
        runner.log("▶ Developer ID 签名 — \(appPath)")
        return await runner.run("'\(scriptsDir)/codesign-mac.sh' '\(appPath)'", env: env)
    }

    /// Notarize an artifact (dmg/pkg/zip) and staple the ticket.
    @discardableResult
    func notarize(artifact: String, stapleApp: String? = nil) async -> RunResult {
        var env = notaryEnv()
        let stapleArg = stapleApp.map { "'\($0)'" } ?? ""
        runner.log("▶ Apple 公证 — \(artifact)")
        return await runner.run("'\(scriptsDir)/notarize.sh' '\(artifact)' \(stapleArg)", env: env)
    }

    /// Full macOS distribution pipeline: sign → (optionally build dmg) → notarize.
    @discardableResult
    func distribute(app: AppProject, appBundle: String, dmg: String? = nil) async -> RunResult {
        // 1. Sign the app bundle.
        let signResult = await signAppBundle(at: appBundle)
        guard signResult.succeeded else { return signResult }

        // 2. Notarize the dmg if provided, else the app.
        if let dmg {
            return await notarize(artifact: dmg, stapleApp: appBundle)
        } else {
            return await notarize(artifact: appBundle)
        }
    }

    /// Build the notarytool auth env. Prefer a keychain profile; fall back to
    /// the ASC API key triple from the keychain.
    private func notaryEnv() -> [String: String] {
        var env = CredentialEnv.build()
        // If an ASC API key is stored, write it to a temp .p8 and point
        // notarytool at it.
        if let keyID = KeychainStore.get(.ascAPIKeyID),
           let content = KeychainStore.get(.ascAPIKeyContent),
           let issuer = KeychainStore.get(.ascIssuerID) {
            let tmp = "\(NSTemporaryDirectory())AuthKey_\(keyID).p8"
            try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
            env["NOTARYTOOL_KEY"] = tmp
            env["NOTARYTOOL_KEY_ID"] = keyID
            env["NOTARYTOOL_ISSUER"] = issuer
        }
        return env
    }
}
