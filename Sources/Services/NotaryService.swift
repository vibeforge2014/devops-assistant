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
    /// The .p8 lands in a 0700 private directory as a 0600 file — created with
    /// those permissions from the start, so there is never a world-readable
    /// window — and is removed once the notarization run completes.
    private func notaryEnv() -> [String: String] {
        var env = CredentialEnv.build()
        if let keyID = KeychainStore.get(.ascAPIKeyID),
           let content = KeychainStore.get(.ascAPIKeyContent),
           let issuer = KeychainStore.get(.ascIssuerID) {
            let dir = NSTemporaryDirectory() + "vibeforge-notary/"
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let tmp = dir + "AuthKey_\(keyID).p8"
            // Drop any stale copy left by a crashed run, then create the
            // fresh file 0600 directly (write-then-chmod leaks a window).
            try? FileManager.default.removeItem(atPath: tmp)
            if FileManager.default.createFile(
                atPath: tmp, contents: Data(content.utf8),
                attributes: [.posixPermissions: 0o600]) {
                env["NOTARYTOOL_KEY"] = tmp
                env["NOTARYTOOL_KEY_ID"] = keyID
                env["NOTARYTOOL_ISSUER"] = issuer
                // Registered synchronously: we're already on the main actor,
                // and scheduling a Task would race distribute()'s defer on
                // fast failures (leaking the key file).
                pendingCleanups.append(tmp)
            } else {
                #if DEBUG
                print("[NotaryService] failed to write ASC key for notarize")
                #endif
            }
        }
        return env
    }

    /// Called by the release flow after distributed(); removes the temp .p8s.
    func cleanupTempKey() {
        for path in pendingCleanups {
            try? FileManager.default.removeItem(atPath: path)
        }
        pendingCleanups.removeAll()
    }

    /// Paths of key files awaiting cleanup — a list, so overlapping notarize
    /// runs can't drop each other's entries.
    private var pendingCleanups: [String] = []
}
