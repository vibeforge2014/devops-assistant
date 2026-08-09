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
        return await runner.run(executable: "\(scriptsDir)/codesign-mac.sh",
                                args: [appPath], env: env, timeout: 900)
    }

    /// Notarize an artifact (dmg/pkg/zip) and staple the ticket.
    @discardableResult
    func notarize(artifact: String, stapleApp: String? = nil) async -> RunResult {
        let env = notaryEnv()
        runner.log("▶ Apple 公证 — \(artifact)")
        var args = [artifact]
        if let stapleApp { args.append(stapleApp) }
        return await runner.run(executable: "\(scriptsDir)/notarize.sh",
                                args: args, env: env, timeout: 3600)
    }

    /// Full macOS distribution pipeline: sign → (optionally build dmg) → notarize.
    @discardableResult
    func distribute(app: AppProject, appBundle: String, dmg: String? = nil) async -> RunResult {
        defer { cleanupTempKey() }
        // 1. Sign the app bundle.
        let signResult = await signAppBundle(at: appBundle)
        guard signResult.succeeded else { return signResult }

        // 2. Notarize the dmg if provided. Otherwise package the app as a ZIP;
        // raw .app bundles are not a portable notary submission artifact.
        if let dmg {
            return await notarize(artifact: dmg, stapleApp: appBundle)
        }
        let zip = "\(app.resolvedPath)/build/\(app.scheme).zip"
        try? FileManager.default.removeItem(atPath: zip)
        runner.log("▶ 打包公证 ZIP — \(zip)")
        let packaged = await runner.run(executable: "/usr/bin/ditto",
                                          args: ["-c", "-k", "--keepParent", appBundle, zip],
                                          timeout: 600)
        guard packaged.succeeded else { return packaged }
        return await notarize(artifact: zip, stapleApp: appBundle)
    }

    /// Build the notarytool auth env from an ASC API key stored in the keychain.
    /// The .p8 is written to a 0600 temp file inside a private subdirectory and
    /// removed once the notarization run completes, so the private key is never
    /// left on disk in world-readable form.
    private func notaryEnv() -> [String: String] {
        var env = CredentialEnv.build()
        if let keyID = KeychainStore.get(.ascAPIKeyID),
           let content = KeychainStore.get(.ascAPIKeyContent),
           let issuer = KeychainStore.get(.ascIssuerID) {
            let dir = NSTemporaryDirectory() + "vibeforge-notary/"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let tmp = dir + "AuthKey_\(keyID).p8"
            do {
                try content.write(toFile: tmp, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
                env["NOTARYTOOL_KEY"] = tmp
                env["NOTARYTOOL_KEY_ID"] = keyID
                env["NOTARYTOOL_ISSUER"] = issuer
                // Clean up after this run completes (best-effort).
                Task { @MainActor in
                    self.pendingCleanup = tmp
                }
            } catch {
                #if DEBUG
                print("[NotaryService] failed to write ASC key for notarize: \(error)")
                #endif
            }
        }
        return env
    }

    /// Called by the release flow after distributed(); removes the temp .p8.
    func cleanupTempKey() {
        guard let path = pendingCleanup else { return }
        try? FileManager.default.removeItem(atPath: path)
        pendingCleanup = nil
    }

    private var pendingCleanup: String?
}
