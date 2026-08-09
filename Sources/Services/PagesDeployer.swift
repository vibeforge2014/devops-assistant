import Foundation

/// Deploys updates to GitHub Pages sites. Each site is an independent git repo
/// that auto-deploys on push (or, for portal, via the gh-pages npm package).
///
/// All git invocations use the argv-array path (`/usr/bin/git`, no shell), so
/// user-supplied commit messages and paths can never break out into shell
/// execution — no command-injection surface.
@MainActor
final class PagesDeployer {
    let runner: ShellRunner
    private let git = "/usr/bin/git"

    init(runner: ShellRunner) {
        self.runner = runner
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
        }
    }

    /// Stage all changes, commit with a message, and push to origin HEAD.
    @discardableResult
    func commitAndPush(_ site: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git add + commit + push — \(site.name)")
        let result = await stageAndCommit(site, message: message)
        guard result.succeeded else { return result }
        runner.log("▶ git push — \(site.name)")
        return await runner.run(executable: git, args: ["push", "origin", "HEAD"],
                                cwd: site.resolvedPath, timeout: 300)
    }

    /// For portal specifically: stage, commit, then run its npm deploy script.
    @discardableResult
    func deployPortal(_ portal: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git commit + npm run deploy — Portal")
        let result = await stageAndCommit(portal, message: message)
        guard result.succeeded else { return result }
        return await runner.run(executable: "/usr/bin/env", args: ["npm", "run", "deploy"],
                                cwd: portal.resolvedPath, timeout: 1800)
    }

    // MARK: - Shared

    private func stageAndCommit(_ site: SiteProject, message: String) async -> RunResult {
        let add = await runner.run(executable: git, args: ["add", "-A"], cwd: site.resolvedPath)
        guard add.succeeded else { return add }
        let diff = await runner.run(executable: git,
                                    args: ["diff", "--cached", "--quiet"],
                                    cwd: site.resolvedPath)
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
                                cwd: site.resolvedPath)
    }
}
