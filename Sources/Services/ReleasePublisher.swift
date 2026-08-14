import Foundation
import Security
import CryptoKit

/// Publishes a finished macOS distribution: creates (or updates) a GitHub
/// Release carrying the notarized DMG + its SHA256, and — for projects that
/// own a Cloudflare-Pages landing page (detected by a `docs/index.html` next
/// to a `wrangler.jsonc`) — regenerates `docs/version.json` and redeploys so
/// the download button never needs a hand-edit. All shell calls go through
/// `ShellRunner` via the argv path (no shell interpolation of paths/notes).
@MainActor
final class ReleasePublisher {
    let runner: ShellRunner
    init(runner: ShellRunner) { self.runner = runner }

    /// Publish `dmgPath` for `app` as a GitHub Release tagged `v<marketing>`.
    /// If the tag already exists (a re-release), the asset is clobbered instead.
    /// Returns true when a downloadable release exists afterwards.
    @discardableResult
    func publish(app: AppProject, dmgPath: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: dmgPath) else {
            runner.log("✗ 找不到 DMG: \(dmgPath)，跳过 Release 发布")
            return false
        }
        guard let slug = app.releaseRepoSlug else {
            runner.log("ℹ 仓库不在 GitHub（\(app.repositoryURL)），跳过 Release 发布")
            return false
        }
        guard let version = VersionManager.read(app) else {
            runner.log("✗ 读不到版本号，跳过 Release 发布")
            return false
        }
        guard await ghAvailable() else {
            runner.log("✗ 未找到已认证的 gh（运行 `gh auth login` 后重试）")
            return false
        }

        let tag = "v\(version.marketing)"
        let sha = sha256(of: dmgPath) ?? "—"
        let notes = Self.notes(app: app, version: version, dmgPath: dmgPath, sha: sha)
        let releaseName = app.name.replacingOccurrences(of: " ", with: "-")
        let assetName = "\(releaseName)-\(version.marketing).dmg"

        runner.log("▶ 发布 GitHub Release \(tag) → \(slug)")
        let exists = await releaseExists(tag: tag, slug: slug)
        let ok: Bool
        if exists {
            runner.log("ℹ \(tag) 已存在 — 覆盖 asset \(assetName)")
            // Copy the asset under the canonical name, then clobber-upload.
            let named = copyAsset(dmgPath, named: assetName)
            let uploaded = await runner.run(
                executable: "/usr/bin/env",
                args: ["gh", "release", "upload", tag, named,
                       "--repo", slug, "--clobber"],
                timeout: 600)
            ok = uploaded.succeeded
            if ok { try? await editNotes(tag: tag, slug: slug, notes: notes) }
        } else {
            let named = copyAsset(dmgPath, named: assetName)
            let created = await runner.run(
                executable: "/usr/bin/env",
                args: ["gh", "release", "create", tag, named,
                       "--repo", slug,
                       "--title", "\(app.name) \(version.marketing)",
                       "--notes", notes],
                timeout: 600)
            ok = created.succeeded
        }
        if ok {
            runner.log("✓ Release \(tag) 已发布: https://github.com/\(slug)/releases/tag/\(tag)")
            await syncLandingPage(app: app, version: version, assetName: assetName, sha: sha)
        }
        return ok
    }

    // MARK: - Landing page (Cloudflare Pages) self-sync

    /// Only projects that ship their own landing page (a `docs/index.html`
    /// alongside a `wrangler.jsonc`) get this. Writes `docs/version.json` and
    /// redeploys via wrangler (token from the keychain). Best-effort: a deploy
    /// hiccup never fails an otherwise-successful release.
    private func syncLandingPage(app: AppProject, version: VersionPair,
                                 assetName: String, sha: String) async {
        let docsIndex = "\(app.resolvedPath)/docs/index.html"
        let wrangler = "\(app.resolvedPath)/wrangler.jsonc"
        guard FileManager.default.fileExists(atPath: docsIndex),
              FileManager.default.fileExists(atPath: wrangler) else { return }
        guard let slug = app.releaseRepoSlug else { return }

        let url = "https://github.com/\(slug)/releases/download/v\(version.marketing)/\(assetName)"
        let date = ISO8601DateFormatter().string(from: Date())
        // Hand-built JSON (tiny, fixed shape) keeps this dependency-free.
        let json = """
        {
          "version": "\(version.marketing)",
          "build": "\(version.build)",
          "url": "\(url)",
          "sha256": "\(sha)",
          "date": "\(date)"
        }
        """
        let versionFile = "\(app.resolvedPath)/docs/version.json"
        do {
            try json.write(toFile: versionFile, atomically: true, encoding: .utf8)
        } catch {
            runner.log("⚠ 无法写入 \(versionFile): \(error.localizedDescription)")
            return
        }
        runner.log("▶ 部署落地页 — Cloudflare Pages（project: \(app.id)）")
        var env = ["CLOUDFLARE_API_TOKEN": cloudflareToken()]
        env["PATH"] = nil  // let ShellRunner resolve Homebrew/npx
        let deployed = await runner.run(
            executable: "/usr/bin/env",
            args: ["npx", "--yes", "wrangler@latest", "pages", "deploy",
                   "\(app.resolvedPath)/docs",
                   "--project-name", app.id, "--branch", "main", "--commit-dirty=true"],
            env: env, timeout: 300)
        if !deployed.succeeded {
            runner.log("⚠ 落地页部署未成功 — Release 已发布，可稍后手动 ./scripts/deploy-pages.sh")
        }
    }

    // MARK: - Helpers

    /// Is `gh` installed and authenticated? `gh auth status` exits 0 when logged in.
    private func ghAvailable() async -> Bool {
        let r = await runner.run(executable: "/usr/bin/env",
                                 args: ["gh", "auth", "status"], timeout: 30)
        return r.succeeded
    }

    private func releaseExists(tag: String, slug: String) async -> Bool {
        let r = await runner.run(executable: "/usr/bin/env",
                                 args: ["gh", "release", "view", tag, "--repo", slug],
                                 timeout: 30)
        return r.succeeded
    }

    private func editNotes(tag: String, slug: String, notes: String) async {
        _ = await runner.run(executable: "/usr/bin/env",
                             args: ["gh", "release", "edit", tag, "--repo", slug,
                                    "--notes", notes],
                             timeout: 60)
    }

    /// Copy (or hardlink-fallback) the DMG to its canonical release asset name
    /// so the GitHub download URL is stable across re-releases.
    private func copyAsset(_ dmgPath: String, named assetName: String) -> String {
        let dir = (dmgPath as NSString).deletingLastPathComponent
        let target = "\(dir)/\(assetName)"
        try? FileManager.default.removeItem(atPath: target)
        do {
            try FileManager.default.linkItem(atPath: dmgPath, toPath: target)
        } catch {
            try? FileManager.default.copyItem(atPath: dmgPath, toPath: target)
        }
        return target
    }

    private func sha256(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Cloudflare token lives in the keychain (see AGENTS.md). Empty when unset.
    private func cloudflareToken() -> String {
        let s = "devops-assistant-cloudflare"
        return (try? readKeychain(service: s)) ?? ""
    }

    // Bridge to the C Keychain API without importing Security here.
    private func readKeychain(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: "ReleasePublisher", code: Int(status))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Build the release notes body (version, size, SHA256, notarization note).
    static func notes(app: AppProject, version: VersionPair,
                      dmgPath: String, sha: String) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: dmgPath)) ?? [:])[.size] as? Int ?? 0
        let mib = Double(size) / 1_048_576.0
        return """
        ## \(app.name) \(version.marketing)（build \(version.build)）

        - 文件：\((dmgPath as NSString).lastPathComponent)（\(String(format: "%.1f", mib)) MB · 通用架构）
        - SHA256：`\(sha)`
        - Developer ID 签名 + Apple 公证 + 已装订票据（spctl：Notarized Developer ID）

        > macOS 14+，下载后双击挂载、拖入「应用程序」即可，Gatekeeper 全程放行。
        """
    }
}
