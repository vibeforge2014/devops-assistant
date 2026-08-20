import Foundation
import SwiftUI

/// Orchestrates a full release of one app: version → build → sign →
/// (notarize) → upload → update pages. Runs steps sequentially and STOPS at
/// the first failure, reporting which step and why. Each step is driven
/// through the shared ShellRunner so output streams live into the console.
///
/// A failed run keeps enough state (`lastFailedRun` + `completedSteps`) that
/// `retry()` can resume from the failed step instead of redoing — and
/// re-bumping — everything that already succeeded. Every run is mirrored to a
/// log file on disk so failures remain investigatable after the app quits.
@MainActor
final class ReleaseCoordinator: ObservableObject {
    @Published private(set) var stepStates: [ReleaseStep: StepState] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var completedSteps: [ReleaseStep] = []
    @Published var cancellationRequested = false

    /// Outcome of the most recent run attempt (drives the wizard's status
    /// line and retry affordances).
    @Published private(set) var lastOutcome: RunOutcome?
    /// The target/version of the most recent failed attempt, when a retry
    /// would have something to resume from.
    @Published private(set) var lastFailedRun: FailedRun?
    /// Target currently (or most recently) executed — the wizard reopens on
    /// it when brought back over a backgrounded run.
    @Published private(set) var activeTarget: ReleaseTarget?
    /// Step executing right now (nil between runs / before the first step).
    /// Drives the wizard's "运行中 · <step>" status line.
    @Published private(set) var currentStep: ReleaseStep?
    /// Wall-clock seconds each step took, for its trailing duration label.
    /// A retry keeps the previous attempt's timings for skipped steps.
    @Published private(set) var stepDurations: [ReleaseStep: TimeInterval] = [:]
    /// When the current attempt started (drives the header's ticking timer).
    @Published private(set) var runStartedAt: Date?
    /// Total seconds of the last finished attempt (set when the defer runs).
    @Published private(set) var runTotalElapsed: TimeInterval?

    /// Fired once per run attempt with its final outcome. Wired by
    /// `ReleaseCenter` to post a user notification; keeps this class free of
    /// UserNotifications concerns.
    var onFinish: (@MainActor (RunOutcome, ReleaseTarget, VersionPair?) -> Void)?

    let runner: ShellRunner
    private let app: AppProject
    private let catalog: ProjectCatalog
    private let historyStore: HistoryStore

    /// Log file the current/last attempt wrote to (nil when logging to disk
    /// failed; the run proceeds console-only rather than aborting). Readable
    /// so the wizard can offer a "打开日志" jump straight to the file.
    private(set) var logSinkURL: URL?

    private var build: BuildService { BuildService(runner: runner) }
    private var fastlane: FastlaneRunner { FastlaneRunner(runner: runner) }
    private var localTestFlight: LocalTestFlightService { LocalTestFlightService(runner: runner) }
    private var notary: NotaryService { NotaryService(runner: runner) }

    init(app: AppProject, runner: ShellRunner, catalog: ProjectCatalog, historyStore: HistoryStore) {
        self.app = app
        self.runner = runner
        self.catalog = catalog
        self.historyStore = historyStore
    }

    // Both types used to be nested here; they were lifted to top level when
    // site publishing needed the same step/outcome vocabulary. Aliases keep
    // existing signatures (e.g. ReleaseCenter's onFinish wiring) unchanged.
    typealias StepState = PipelineStepState
    typealias RunOutcome = PipelineOutcome

    struct FailedRun: Equatable {
        let target: ReleaseTarget
        /// The version pair the failed attempt shipped (explicit or read
        /// back from disk after the bump) — a retry must reuse it, never
        /// bump again.
        let version: VersionPair?
    }

    /// The steps that apply for the given target. Every target ends by syncing
    /// the new version into the portal's product data (a best-effort step that
    /// never aborts an otherwise-successful release).
    func steps(for target: ReleaseTarget) -> [ReleaseStep] {
        guard ReleaseTarget.available(for: app).contains(target) else { return [] }
        switch target {
        case .testFlight:
            // Local scripts/lanes own archive + signing; don't build twice.
            return [.setVersion, .uploadBeta, .updatePages]
        case .appStore:
            return [.setVersion, .build, .sign, .uploadRelease, .updatePages]
        case .macDistribution:
            return [.setVersion, .build, .sign, .notarize, .updatePages]
        }
    }

    /// Reset step states to idle (used when switching target in the UI).
    func resetSteps() {
        for key in stepStates.keys { stepStates[key] = .idle }
    }

    var canRetry: Bool { lastFailedRun != nil && !isRunning }

    /// Run the full pipeline for a target, with a version to bump to
    /// (optional — if nil, only the build number is bumped). Stops at the first
    /// failing step — EXCEPT `.updatePages`, which is best-effort: the release
    /// proper (build/sign/upload) has already succeeded by then, so a portal
    /// data hiccup is logged but never turns a successful ship into a failure.
    /// Every run (success or failure) is appended to history before returning.
    @discardableResult
    func run(target: ReleaseTarget, version: VersionPair?, clearLog: Bool = true) async -> Bool {
        await runPipeline(target: target, version: version, skipping: [], clearLog: clearLog)
    }

    /// Resume the most recent failed run from where it stopped: steps that
    /// already succeeded (including `setVersion`, so the build number is
    /// never bumped twice) are skipped, the log file is continued rather
    /// than truncated.
    @discardableResult
    func retry() async -> Bool {
        guard let failed = lastFailedRun, !isRunning else { return false }
        let alreadyDone = completedSteps
        return await runPipeline(target: failed.target, version: failed.version,
                                 skipping: alreadyDone, clearLog: false)
    }

    /// Cancel both the coordinator and the command that is currently running.
    func cancel() {
        cancellationRequested = true
        runner.terminate()
    }

    /// Quit-path bookkeeping for an in-flight run: the pipeline task is about
    /// to be abandoned with the process, so it can't record its own history
    /// or flush its log sink — do both here, synchronously.
    func markInterrupted() {
        guard isRunning else { return }
        cancellationRequested = true
        isRunning = false
        lastOutcome = .cancelled
        runner.log("✋ 应用退出 — 发布流程中断")
        if let target = activeTarget {
            recordHistory(target: target, version: nil,
                          success: false, failureStep: "应用退出中断")
        }
        // Releasing the sink runs its flush queue before the handle closes,
        // so the on-disk log gets its tail even though the run never returns.
        runner.logSink = nil
    }

    private func runPipeline(target: ReleaseTarget,
                             version: VersionPair?,
                             skipping: [ReleaseStep],
                             clearLog: Bool) async -> Bool {
        // Re-entry guard: the UI disables buttons while running, but a fast
        // double-click (or any future direct caller) can enqueue a second
        // pipeline before isRunning flips — two pipelines would clobber each
        // other's runner state and step tables.
        guard !isRunning else {
            runner.log("✗ 已有发布流程在运行,已忽略重复启动")
            return false
        }
        guard ReleaseTarget.available(for: app).contains(target) else {
            runner.log("✗ 当前项目不支持 \(target.title)")
            lastOutcome = .failed("目标不可用")
            onFinish?(.failed("目标不可用"), target, nil)
            return false
        }

        activeTarget = target
        if clearLog {
            runner.clear()
            attachNewLogSink(target: target)
        } else {
            // Retry: keep the previous attempt's console output on screen and
            // continue the same log file — the failure stays visible above
            // the retry output.
            resumeLogSink(target: target)
        }
        if !skipping.isEmpty {
            runner.log("↻ 重试:跳过已完成的 \(skipping.count) 步,从失败步骤继续")
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

        let steps = steps(for: target)
        let remaining = steps.excludingCompleted(skipping)
        for step in steps { stepStates[step] = skipping.contains(step) ? .succeeded : .idle }
        completedSteps = steps.filter { skipping.contains($0) }
        cancellationRequested = false

        for step in remaining {
            guard !cancellationRequested else {
                runner.log("✋ 已取消发布流程")
                stepStates[step] = .failed("已取消")
                lastOutcome = .cancelled
                lastFailedRun = nil
                let recorded = recordHistory(target: target, version: version,
                                             success: false, failureStep: "已取消")
                onFinish?(.cancelled, target, recorded)
                return false
            }
            let stepStartedAt = Date()
            currentStep = step
            stepStates[step] = .running
            runner.log("")
            runner.log("━━━ Step \(step.title) ━━━")

            let ok: Bool
            switch step {
            case .setVersion:
                if let version {
                    ok = VersionManager.write(version, to: app)
                } else {
                    ok = VersionManager.bumpBuild(app) != nil
                }
            case .build:
                ok = await runBuild()
            case .sign:
                ok = await runSign()
            case .notarize:
                ok = await runNotarize()
            case .uploadBeta:
                ok = await runUpload(target: .testFlight)
            case .uploadRelease:
                ok = await runUpload(target: .appStore)
            case .updatePages:
                ok = await runUpdatePages()
            }
            stepDurations[step] = Date().timeIntervalSince(stepStartedAt)

            if cancellationRequested {
                stepStates[step] = .failed("已取消")
                runner.log("✋ 已取消发布流程")
                lastOutcome = .cancelled
                lastFailedRun = nil
                let recorded = recordHistory(target: target, version: version,
                                             success: false, failureStep: "已取消")
                onFinish?(.cancelled, target, recorded)
                return false
            }

            if ok {
                stepStates[step] = .succeeded
                completedSteps.append(step)
            } else if step == .updatePages {
                // Best-effort: the release itself succeeded. Surface the
                // warning in the console but don't mark the run as failed.
                runner.log("⚠ \(step.title) 未成功,但发布主体已完成 — 不中断")
                stepStates[step] = .succeeded
                completedSteps.append(step)
            } else {
                stepStates[step] = .failed("步骤失败,已中断")
                runner.log("✗ \(step.title) 失败 — 发布中断")
                let outcome = RunOutcome.failed(step.title)
                lastOutcome = outcome
                let recorded = recordHistory(target: target, version: version,
                                             success: false, failureStep: step.title)
                lastFailedRun = FailedRun(target: target, version: recorded)
                onFinish?(outcome, target, recorded)
                return false
            }
        }

        runner.log("")
        runner.log("🎉 发布完成!")
        lastOutcome = .success
        lastFailedRun = nil
        let recorded = recordHistory(target: target, version: version,
                                     success: true, failureStep: nil)
        onFinish?(.success, target, recorded)
        return true
    }

    // MARK: - Run log files

    private func attachNewLogSink(target: ReleaseTarget) {
        guard let sink = RunLogStore.makeSink(appID: app.id, target: target.rawValue) else {
            logSinkURL = nil
            runner.logSink = nil
            runner.log("⚠ 无法创建运行日志文件,本次仅保留控制台输出")
            return
        }
        logSinkURL = sink.url
        runner.logSink = sink
        runner.log("📝 运行日志: \(sink.url.path)")
    }

    /// Reopen the previous attempt's log file in append mode so a retry
    /// continues the same file; falls back to a fresh file if it's gone.
    private func resumeLogSink(target: ReleaseTarget) {
        if let url = logSinkURL, FileManager.default.fileExists(atPath: url.path),
           let sink = FileLogSink(url: url, append: true) {
            runner.logSink = sink
            runner.log("↻ 续写运行日志: \(url.path)")
        } else {
            attachNewLogSink(target: target)
        }
    }

    // MARK: - History

    /// Capture this run into the history store, using the version actually on
    /// disk (which reflects any bump) so the record matches what shipped.
    /// Returns the recorded pair so callers (notifications, retries) reuse it.
    @discardableResult
    private func recordHistory(target: ReleaseTarget,
                               version: VersionPair?,
                               success: Bool,
                               failureStep: String?) -> VersionPair? {
        let recorded = version ?? VersionManager.read(app)
        historyStore.append(ReleaseRecord(
            appName: app.name,
            appID: app.id,
            platform: app.platform,
            target: target,
            version: recorded,
            success: success,
            failureStep: failureStep,
            logPath: logSinkURL?.path
        ))
        return recorded
    }

    // MARK: - Pages / portal sync

    /// Push the just-released version into the portal's product data and
    /// redeploy it. The portal is looked up from the catalog by its `portal`
    /// id; if absent or its clone missing, we warn and treat as best-effort ok.
    private func runUpdatePages() async -> Bool {
        guard let portal = catalog.site(id: "portal") else {
            runner.log("ℹ 未找到 portal 站点,跳过发布页更新")
            return false
        }
        guard let version = VersionManager.read(app) else {
            runner.log("ℹ 读不到当前版本,跳过发布页更新")
            return false
        }
        let sync = PortalSync(runner: runner)
        let updated = await sync.updateVersion(productID: app.id,
                                               version: version,
                                               portal: portal)
        guard updated else { return false }

        // Re-deploy the portal so the new version goes live.
        if portal.existsOnDisk {
            let deployer = PagesDeployer(runner: runner)
            let result = await deployer.deployPortal(portal, message: "chore: bump \(app.name) → \(version.marketing)")
            return result.succeeded
        }
        return true
    }

    // MARK: - Step implementations

    private func runBuild() async -> Bool {
        let generated = await build.generateXcodeProject(at: app.resolvedPath)
        guard generated.succeeded else { return false }
        let archive = await build.archive(app: app, to: build.archivePath(for: app))
        return archive.succeeded
    }

    private func runSign() async -> Bool {
        switch app.release.signing {
        case .match, .sigh:
            guard let lane = app.release.signingLane else {
                runner.log("ℹ 签名由上传 lane 内部处理")
                return true
            }
            let r = await fastlane.runLane(lane, app: app)
            return r.succeeded
        case .developerID:
            // macOS: no pre-sign step needed; the .app isn't signed until
            // after archive. Signing happens in notarize step for ChargePilot.
            runner.log("ℹ Developer ID 签名将在公证阶段执行")
            return true
        case .manual:
            runner.log("ℹ 手动签名 — 使用项目自带 ExportOptions")
            return true
        }
    }

    private func runNotarize() async -> Bool {
        // Only applies to macOS apps flagged for notarization.
        guard app.release.notarize else {
            runner.log("ℹ 该项目无需公证")
            return true
        }
        let bundle = "\(build.archivePath(for: app))/Products/Applications/\(app.scheme).app"
        guard FileManager.default.fileExists(atPath: bundle) else {
            runner.log("✗ 找不到 .app: \(bundle)")
            return false
        }
        let service = NotaryService(runner: runner)
        return (await service.distribute(app: app, appBundle: bundle)).succeeded
    }

    private func runUpload(target: ReleaseTarget) async -> Bool {
        if target == .testFlight {
            return (await localTestFlight.upload(app: app)).succeeded
        }
        switch app.release.engine {
        case .fastlane:
            let lane = target == .testFlight
                ? (app.release.betaLane ?? "beta")
                : (app.release.releaseLane ?? "release")
            let r = await fastlane.runLane(lane, app: app)
            return r.succeeded
        case .native:
            runner.log("✗ \(app.name) 原生引擎暂未内置上传 lane,请先为其生成 Fastfile")
            return false
        }
    }
}
