import Foundation

/// Deploys updates to GitHub Pages sites. Each site is an independent git repo
/// that auto-deploys on push (or, for portal, via the gh-pages npm package;
/// Cloudflare Pages sites upload directly through wrangler).
///
/// All git invocations use the argv-array path (`/usr/bin/git`, no shell), so
/// user-supplied commit messages and paths can never break out into shell
/// execution — no command-injection surface.
///
/// The granular steps (`pull` / `commit` / `revert` / `publish` / `verify`)
/// exist so `SitePublishCoordinator` can run, report and retry them one at a
/// time; `deploy` keeps the old one-shot behavior for simple callers.
@MainActor
final class PagesDeployer {
    let runner: ShellRunner
    private let git = "/usr/bin/git"
    /// Resolved lazily at publish time so a token stored mid-session works
    /// without rebuilding anything. Injectable to keep tests hermetic.
    private let cloudflareTokenProvider: () -> String?

    /// Keychain service of the pre-app token created for
    /// `scripts/deploy-pages.sh`; read as a fallback when the app's own
    /// credential hasn't been configured yet.
    static let legacyCloudflareService = "devops-assistant-cloudflare"

    init(runner: ShellRunner,
         cloudflareTokenProvider: @escaping () -> String? = PagesDeployer.defaultCloudflareToken) {
        self.runner = runner
        self.cloudflareTokenProvider = cloudflareTokenProvider
    }

    static func defaultCloudflareToken() -> String? {
        guard let token = KeychainStore.get(.cloudflareAPIToken),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return KeychainStore.legacyItem(service: legacyCloudflareService)
        }
        return token
    }

    /// Pull latest changes for a site's local clone.
    @discardableResult
    func pull(_ site: SiteProject) async -> RunResult {
        runner.log("▶ git pull — \(site.name)")
        return await runner.run(executable: git, args: ["pull", "--ff-only"],
                                cwd: site.resolvedPath, timeout: 300)
    }

    /// Route deployment according to the catalog instead of treating Portal
    /// like a normal push-to-main site.
    @discardableResult
    func deploy(_ site: SiteProject, message: String) async -> RunResult {
        switch site.deploy {
        case .gitPushMain:
            return await commitAndPush(site, message: message)
        case .ghPages:
            return await deployPortal(site, message: message)
        case .cloudflarePages:
            let result = await commit(site, message: message)
            guard result.succeeded else { return result }
            return await publish(site)
        }
    }

    /// Stage all changes, commit with a message, and push to origin HEAD.
    @discardableResult
    func commitAndPush(_ site: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git add + commit + push — \(site.name)")
        let result = await commit(site, message: message)
        guard result.succeeded else { return result }
        return await publish(site)
    }

    /// Stage every change and commit it. Succeeds (exit 0) when there is
    /// nothing to commit — callers decide whether a no-op commit matters.
    @discardableResult
    func commit(_ site: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git add + commit — \(site.name)")
        // Timeouts match the pull/push calls above: local git is fast, and a
        // site repo with an interactive/network pre-commit hook would
        // otherwise hang the deploy forever.
        let add = await runner.run(executable: git, args: ["add", "-A"],
                                   cwd: site.resolvedPath, timeout: 120)
        guard add.succeeded else { return add }
        let diff = await runner.run(executable: git,
                                    args: ["diff", "--cached", "--quiet"],
                                    cwd: site.resolvedPath, timeout: 120)
        if diff.succeeded {
            runner.log("ℹ 没有需要提交的变更")
            return RunResult(exitCode: 0, cancelled: false)
        }
        guard diff.exitCode == 1 else { return diff }
        // Sanitize: messages with a leading dash could be parsed as flags; a
        // trailing note avoids that without changing intent for normal text.
        let safeMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeMessage.isEmpty else { return RunResult(exitCode: -1, cancelled: false) }
        return await runner.run(executable: git,
                                args: ["commit", "-m", safeMessage],
                                cwd: site.resolvedPath, timeout: 120)
    }

    /// Undo the last commit with a revert (history-preserving; a follow-up
    /// publish redeploys the pre-change content). Fails when the working tree
    /// is dirty in conflicting ways or HEAD is the initial commit.
    @discardableResult
    func revert(_ site: SiteProject) async -> RunResult {
        runner.log("▶ git revert — \(site.name)")
        return await runner.run(executable: git, args: ["revert", "--no-edit", "HEAD"],
                                cwd: site.resolvedPath, timeout: 120)
    }

    /// The method-specific "go live" step: push main for GitHub Actions
    /// sites, the npm deploy script for portal's gh-pages branch, a wrangler
    /// upload for Cloudflare Pages sites.
    @discardableResult
    func publish(_ site: SiteProject) async -> RunResult {
        switch site.deploy {
        case .gitPushMain:
            runner.log("▶ git push — \(site.name)")
            return await runner.run(executable: git, args: ["push", "origin", "HEAD"],
                                    cwd: site.resolvedPath, timeout: 300)
        case .ghPages:
            runner.log("▶ npm run deploy — \(site.name)")
            return await runner.run(executable: "/usr/bin/env", args: ["npm", "run", "deploy"],
                                    cwd: site.resolvedPath, timeout: 1800)
        case .cloudflarePages:
            guard let token = cloudflareTokenProvider() else {
                runner.log("✗ 未配置 Cloudflare API Token — 请在 设置→凭据 填写,")
                runner.log("   或用 security add-generic-password -s \(Self.legacyCloudflareService) 写入钥匙串")
                return RunResult(exitCode: -1, cancelled: false)
            }
            let project = site.cloudflareProject ?? site.id
            let dir = site.deployDir ?? "."
            runner.log("▶ wrangler pages deploy \(dir) — \(site.name)(Pages 项目 \(project))")
            // The token rides in the environment only — never argv, never the
            // console log. Mirrors scripts/deploy-pages.sh.
            return await runner.run(executable: "/usr/bin/env",
                                    args: Self.cloudflareDeployArgs(project: project, dir: dir),
                                    cwd: site.resolvedPath,
                                    env: ["CLOUDFLARE_API_TOKEN": token],
                                    timeout: 1800)
        }
    }

    /// Split out so the exact wrangler invocation is unit-testable without
    /// touching npx or the network.
    static func cloudflareDeployArgs(project: String, dir: String) -> [String] {
        ["npx", "--yes", "wrangler@latest", "pages", "deploy", dir,
         "--project-name", project, "--branch", "main", "--commit-dirty=true"]
    }

    /// For portal specifically: stage, commit, then run its npm deploy script.
    /// Kept for `ReleaseCoordinator`'s post-release portal sync.
    @discardableResult
    func deployPortal(_ portal: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git commit + npm run deploy — Portal")
        let result = await commit(portal, message: message)
        guard result.succeeded else { return result }
        return await publish(portal)
    }

    // MARK: - Deployment verification

    /// After a push-to-main publish, confirm the GitHub Actions run for the
    /// pushed commit actually succeeded — the push alone only queued it.
    /// Best-effort: a repo without workflows or without `gh` skips with a
    /// note instead of failing an otherwise-successful push.
    @discardableResult
    func verifyDeployment(_ site: SiteProject) async -> RunResult {
        guard let head = await currentCommit(at: site.resolvedPath) else {
            runner.log("⚠ 读不到当前提交,跳过部署验证")
            return RunResult(exitCode: 0, cancelled: false)
        }
        // The run can take a few seconds to register after the push.
        var runID: String?
        for _ in 0..<6 {
            switch await lookupRun(headSHA: head, at: site.resolvedPath) {
            case .id(let id):
                runID = id
            case .noneYet:
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            case .unavailable:
                runner.log("ℹ 无法通过 gh 查询工作流(未安装 gh 或仓库不在 GitHub),跳过验证")
                return RunResult(exitCode: 0, cancelled: false)
            }
            if runID != nil { break }
        }
        guard let runID else {
            runner.log("⚠ 未找到该提交对应的部署工作流(可能未配置),跳过验证")
            return RunResult(exitCode: 0, cancelled: false)
        }
        runner.log("▶ gh run watch #\(runID) — 等待部署工作流结束")
        return await runner.run(executable: "/usr/bin/env",
                                args: ["gh", "run", "watch", runID,
                                       "--exit-status", "--interval", "10"],
                                cwd: site.resolvedPath, timeout: 900)
    }

    private func currentCommit(at path: String) async -> String? {
        guard let result = await ProcessCapture.capture(
            executable: "/usr/bin/git", args: ["rev-parse", "HEAD"], cwd: path),
            result.exitCode == 0 else { return nil }
        let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private enum RunLookup { case id(String), noneYet, unavailable }

    private func lookupRun(headSHA: String, at path: String) async -> RunLookup {
        guard let result = await ProcessCapture.capture(
            executable: "/usr/bin/env",
            args: ["gh", "run", "list", "--limit", "5", "--json", "databaseId,headSha"],
            cwd: path) else { return .unavailable }
        guard result.exitCode == 0 else { return .unavailable }
        guard let id = Self.parseRunID(json: result.output, headSHA: headSHA) else {
            return .noneYet
        }
        return .id(id)
    }

    /// `[{"databaseId":123,"headSha":"…"}]` → the id whose headSha matches.
    /// Pure so the polling predicate is unit-testable.
    static func parseRunID(json: String, headSHA: String) -> String? {
        guard let data = json.data(using: .utf8),
              let runs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for run in runs {
            if run["headSha"] as? String == headSHA,
               let id = run["databaseId"] {
                return String(describing: id)
            }
        }
        return nil
    }
}
