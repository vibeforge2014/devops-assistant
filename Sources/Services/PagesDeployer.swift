import Foundation

/// Deploys updates to GitHub Pages sites. Each site is an independent git repo
/// that auto-deploys on push (or, for portal, via the gh-pages npm package).
/// This service performs the standard pull → edit → commit → push cycle and
/// surfaces the result.
@MainActor
final class PagesDeployer {
    let runner: ShellRunner

    init(runner: ShellRunner) {
        self.runner = runner
    }

    /// Pull latest changes for a site's local clone.
    @discardableResult
    func pull(_ site: SiteProject) async -> RunResult {
        runner.log("▶ git pull — \(site.name)")
        return await runner.run("git pull --ff-only", cwd: site.resolvedPath)
    }

    /// Commit all changes with a message and push to origin main.
    @discardableResult
    func commitAndPush(_ site: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git add + commit + push — \(site.name)")
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = """
        git add -A && \
        git commit -m "\(escaped)" && \
        git push origin HEAD
        """
        return await runner.run(cmd, cwd: site.resolvedPath)
    }

    /// Full deploy cycle: pull, apply an edit closure, then commit & push.
    /// The closure receives the site path and performs any file edits.
    @discardableResult
    func deploy(_ site: SiteProject,
                message: String,
                edit: (String) throws -> Void) async -> RunResult {
        let pullResult = await pull(site)
        guard pullResult.succeeded else { return pullResult }

        do {
            try edit(site.resolvedPath)
        } catch {
            runner.log("✗ 编辑失败: \(error.localizedDescription)")
            return RunResult(exitCode: -1, cancelled: false)
        }

        return await commitAndPush(site, message: message)
    }

    /// For portal specifically: run its npm deploy script (gh-pages) after edits.
    @discardableResult
    func deployPortal(_ portal: SiteProject, message: String) async -> RunResult {
        runner.log("▶ git commit + npm run deploy — Portal")
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = """
        git add -A && \
        git commit -m "\(escaped)" && \
        npm run deploy
        """
        let push = await runner.run(cmd, cwd: portal.resolvedPath)
        return push
    }
}
