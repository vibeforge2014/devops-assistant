import Foundation
import SwiftUI

/// The discrete steps of a site publish, in execution order.
enum SitePublishStep: String, CaseIterable, Identifiable {
    case pull       // git pull --ff-only
    case commit     // git add -A + commit
    case revert     // git revert --no-edit HEAD (rollback flow)
    case publish    // push origin HEAD / npm run deploy / wrangler, per DeployMethod
    case verify     // gh run watch: confirm the Actions deploy really went live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pull: "拉取远端更新"
        case .commit: "提交变更"
        case .revert: "回滚上一版"
        case .publish: "部署上线"
        case .verify: "确认部署生效"
        }
    }

    var systemImage: String {
        switch self {
        case .pull: "arrow.down.to.line"
        case .commit: "checkmark.circle"
        case .revert: "arrow.uturn.backward"
        case .publish: "paperplane.fill"
        case .verify: "checkmark.shield"
        }
    }
}

/// Orchestrates publishing one site: pull → commit → go live, mirroring
/// `ReleaseCoordinator`'s shape (step states, retry from the failed step,
/// history record, run log on disk, background-safe ownership). A clean tree
/// with nothing ahead of upstream short-circuits as `.nothingToPublish`
/// instead of recording a no-op "successful" deployment. The rollback flow
/// (`runRollback`) swaps the commit step for a revert and records history
/// under the 站点回滚 target.
@MainActor
final class SitePublishCoordinator: ObservableObject {
    @Published private(set) var stepStates: [SitePublishStep: PipelineStepState] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var completedSteps: [SitePublishStep] = []
    @Published var cancellationRequested = false
    @Published private(set) var lastOutcome: PipelineOutcome?
    /// Whether the last attempt failed somewhere a retry can resume from.
    @Published private(set) var lastAttemptFailed = false
    @Published private(set) var currentStep: SitePublishStep?
    @Published private(set) var stepDurations: [SitePublishStep: TimeInterval] = [:]
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var runTotalElapsed: TimeInterval?
    /// Whether the last (or running) attempt is a rollback; read by
    /// `ReleaseCenter` to word its notifications and by the wizard's banner.
    @Published private(set) var lastWasRollback = false

    /// Fired once per attempt with the final outcome and the deployed
    /// commit's short hash (nil when the attempt stopped before committing).
    /// Wired by `ReleaseCenter` to post a notification.
    var onFinish: (@MainActor (PipelineOutcome, String?) -> Void)?

    let runner: ShellRunner
    let site: SiteProject
    private let historyStore: HistoryStore

    /// Log file the current/last attempt wrote to (nil when logging to disk
    /// failed; the run proceeds console-only rather than aborting).
    private(set) var logSinkURL: URL?

    /// The commit message of the last attempt — a retry reuses it, since the
    /// message belonged to a run the user already approved.
    private var lastMessage: String?

    /// The step list of the last attempt — a retry resumes that same shape
    /// (a rollback retry keeps its revert step, a publish retry its commit).
    private var lastSteps: [SitePublishStep] = []

    private var deployer: PagesDeployer { PagesDeployer(runner: runner) }

    /// Base publish flow for every deploy method — only the publish step's
    /// command differs (`DeployMethod` decides push / npm / wrangler).
    /// Push-to-main sites append a verify step: the push itself only queues
    /// the GitHub Actions deploy, so "published" isn't "live" until the run
    /// succeeds.
    static func publishSteps(for site: SiteProject) -> [SitePublishStep] {
        [.pull, .commit, .publish] + (site.deploy == .gitPushMain ? [.verify] : [])
    }

    /// Rollback flow: revert the last commit instead of creating one. No
    /// nothing-to-publish short-circuit — there is always a HEAD to revert.
    static func rollbackSteps(for site: SiteProject) -> [SitePublishStep] {
        [.pull, .revert, .publish] + (site.deploy == .gitPushMain ? [.verify] : [])
    }

    init(site: SiteProject, runner: ShellRunner, historyStore: HistoryStore) {
        self.site = site
        self.runner = runner
        self.historyStore = historyStore
    }

    /// Reset step states to idle (used when starting a fresh attempt after a
    /// previous one finished).
    func resetSteps() {
        for key in stepStates.keys { stepStates[key] = .idle }
    }

    var canRetry: Bool { lastAttemptFailed && !isRunning }

    /// Run the full publish pipeline with a commit message. Stops at the
    /// first failing step; every finished attempt except `.nothingToPublish`
    /// is appended to history before returning.
    @discardableResult
    func run(message: String, clearLog: Bool = true) async -> Bool {
        await runPipeline(message: message, steps: Self.publishSteps(for: site),
                          rollback: false, skipping: [], clearLog: clearLog)
    }

    /// Undo the last deployed commit (git revert) and redeploy the site.
    /// History is recorded under the 站点回滚 target so the two flows stay
    /// distinguishable in 发布历史.
    @discardableResult
    func runRollback(clearLog: Bool = true) async -> Bool {
        let subject = await Self.lastCommitSubject(at: site.resolvedPath)
        return await runPipeline(message: "Revert \"\(subject ?? "上一版")\"",
                                 steps: Self.rollbackSteps(for: site),
                                 rollback: true, skipping: [], clearLog: clearLog)
    }

    /// Resume the most recent failed attempt from where it stopped: steps
    /// that already succeeded are skipped, the log file is continued rather
    /// than truncated.
    @discardableResult
    func retry() async -> Bool {
        guard lastAttemptFailed, !isRunning else { return false }
        let alreadyDone = completedSteps
        return await runPipeline(message: lastMessage ?? "更新站点内容",
                                 steps: lastSteps.isEmpty ? Self.publishSteps(for: site) : lastSteps,
                                 rollback: lastWasRollback,
                                 skipping: alreadyDone, clearLog: false)
    }

    /// Cancel the coordinator and the command currently running.
    func cancel() {
        cancellationRequested = true
        runner.terminate()
    }

    /// Quit-path bookkeeping for an in-flight run (mirrors
    /// `ReleaseCoordinator.markInterrupted`): record history, flush the log.
    func markInterrupted() {
        guard isRunning else { return }
        cancellationRequested = true
        isRunning = false
        lastOutcome = .cancelled
        runner.log("✋ 应用退出 — 发布流程中断")
        historyStore.append(ReleaseRecord(
            siteName: site.name,
            siteID: site.id,
            commitShortHash: nil,
            success: false,
            failureStep: "应用退出中断",
            logPath: logSinkURL?.path
        ))
        // Releasing the sink runs its flush queue before the handle closes,
        // so the on-disk log gets its tail even though the run never returns.
        runner.logSink = nil
    }

    // MARK: - Pipeline

    private func runPipeline(message: String,
                             steps: [SitePublishStep],
                             rollback: Bool,
                             skipping: [SitePublishStep],
                             clearLog: Bool) async -> Bool {
        guard !isRunning else {
            runner.log("✗ 已有发布流程在运行,已忽略重复启动")
            return false
        }
        lastMessage = message
        lastSteps = steps
        lastWasRollback = rollback
        guard site.existsOnDisk else {
            runner.log("✗ 本地克隆不存在,无法发布 — 请先克隆仓库")
            lastOutcome = .failed("本地克隆不存在")
            lastAttemptFailed = false
            onFinish?(.failed("本地克隆不存在"), nil)
            return false
        }

        if clearLog {
            runner.clear()
            attachNewLogSink()
        } else {
            resumeLogSink()
        }
        if !skipping.isEmpty {
            runner.log("↻ 重试:跳过已完成的 \(skipping.count) 步,从失败步骤继续")
        }
        if rollback, skipping.isEmpty {
            runner.log("↺ 回滚模式:将撤销最近一次提交并重新部署")
        }

        runStartedAt = Date()
        runTotalElapsed = nil
        if clearLog { stepDurations = [:] }
        isRunning = true
        defer {
            isRunning = false
            currentStep = nil
            if let started = runStartedAt {
                runTotalElapsed = Date().timeIntervalSince(started)
            }
            runner.logSink = nil // releases the sink → file handle closes after flush
        }

        let remaining = steps.filter { !skipping.contains($0) }
        for step in steps { stepStates[step] = skipping.contains(step) ? .succeeded : .idle }
        completedSteps = steps.filter { skipping.contains($0) }
        cancellationRequested = false

        // A clean tree with nothing to push needs no pipeline at all — bail
        // out before anything runs so history stays free of no-op
        // deployments. Skipped on retry when commit already succeeded (the
        // failure was in publishing already-committed work), and never
        // applies to rollback (reverting always produces a commit).
        if remaining.contains(.commit),
           let status = await SiteStatusService.status(at: site.resolvedPath),
           status.hasNothingToPublish {
            runner.log("ℹ 工作区干净,且没有领先远端的提交 — 没有需要发布的内容")
            lastOutcome = .nothingToPublish
            lastAttemptFailed = false
            onFinish?(.nothingToPublish, status.lastCommit?.shortHash)
            return false
        }

        for step in remaining {
            guard !cancellationRequested else {
                return finishCancelled(at: step)
            }
            let stepStartedAt = Date()
            currentStep = step
            stepStates[step] = .running
            runner.log("")
            runner.log("━━━ Step \(step.title) ━━━")

            let ok: Bool
            switch step {
            case .pull:
                ok = await deployer.pull(site).succeeded
            case .commit:
                ok = await deployer.commit(site, message: message).succeeded
            case .revert:
                ok = await deployer.revert(site).succeeded
            case .publish:
                ok = await deployer.publish(site).succeeded
            case .verify:
                ok = await deployer.verifyDeployment(site).succeeded
            }
            stepDurations[step] = Date().timeIntervalSince(stepStartedAt)

            if cancellationRequested {
                return finishCancelled(at: step)
            }

            if ok {
                stepStates[step] = .succeeded
                completedSteps.append(step)
            } else {
                stepStates[step] = .failed("步骤失败,已中断")
                runner.log("✗ \(step.title) 失败 — 发布中断")
                lastOutcome = .failed(step.title)
                lastAttemptFailed = true
                let hash = await SiteStatusService.currentCommitShortHash(at: site.resolvedPath)
                appendHistory(success: false, failureStep: step.title, commitHash: hash)
                onFinish?(.failed(step.title), hash)
                return false
            }
        }

        runner.log("")
        runner.log(rollback ? "🎉 回滚完成,站点已重新部署!" : "🎉 站点发布完成!")
        lastOutcome = .success
        lastAttemptFailed = false
        let hash = await SiteStatusService.currentCommitShortHash(at: site.resolvedPath)
        appendHistory(success: true, failureStep: nil, commitHash: hash)
        onFinish?(.success, hash)
        return true
    }

    private func finishCancelled(at step: SitePublishStep) -> Bool {
        stepStates[step] = .failed("已取消")
        runner.log("✋ 已取消发布流程")
        lastOutcome = .cancelled
        lastAttemptFailed = false
        appendHistory(success: false, failureStep: "已取消", commitHash: nil)
        onFinish?(.cancelled, nil)
        return false
    }

    // MARK: - Run log files

    private func attachNewLogSink() {
        guard let sink = RunLogStore.makeSink(appID: "site-\(site.id)",
                                              target: lastWasRollback ? "rollback" : "deploy") else {
            logSinkURL = nil
            runner.logSink = nil
            runner.log("⚠ 无法创建运行日志文件,本次仅保留控制台输出")
            return
        }
        logSinkURL = sink.url
        runner.logSink = sink
        runner.log("📝 运行日志: \(sink.url.path)")
    }

    private func resumeLogSink() {
        if let url = logSinkURL, FileManager.default.fileExists(atPath: url.path),
           let sink = FileLogSink(url: url, append: true) {
            runner.logSink = sink
            runner.log("↻ 续写运行日志: \(url.path)")
        } else {
            attachNewLogSink()
        }
    }

    // MARK: - History

    private func appendHistory(success: Bool, failureStep: String?, commitHash: String?) {
        historyStore.append(ReleaseRecord(
            siteName: site.name,
            siteID: site.id,
            commitShortHash: commitHash,
            success: success,
            failureStep: failureStep,
            logPath: logSinkURL?.path,
            target: lastWasRollback ? ReleaseRecord.siteRollbackTarget : ReleaseRecord.siteDeployTarget
        ))
    }

    // MARK: - Rollback helpers

    /// Subject line of the commit a rollback would revert, fetched lazily for
    /// the rollback flow's commit message (nil outside a repository or with
    /// no commits).
    static func lastCommitSubject(at path: String) async -> String? {
        guard let result = await ProcessCapture.capture(
            executable: "/usr/bin/git",
            args: ["log", "-1", "--pretty=format:%s"],
            cwd: path), result.exitCode == 0 else { return nil }
        let subject = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? nil : subject
    }
}
