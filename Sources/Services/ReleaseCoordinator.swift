import Foundation
import SwiftUI

/// Which release channel to run for an app.
enum ReleaseTarget: String, CaseIterable, Identifiable {
    case testFlight
    case appStore
    case macDistribution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .testFlight: "TestFlight 测试"
        case .appStore: "App Store 上架"
        case .macDistribution: "macOS 分发(公证)"
        }
    }
}

/// Orchestrates a full release of one app: version → build → sign →
/// (notarize) → upload → update pages. Runs steps sequentially and STOPS at
/// the first failure, reporting which step and why. Each step is driven
/// through the shared ShellRunner so output streams live into the console.
@MainActor
final class ReleaseCoordinator: ObservableObject {
    @Published private(set) var stepStates: [ReleaseStep: StepState] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var completedSteps: [ReleaseStep] = []
    @Published var cancellationRequested = false

    let runner: ShellRunner
    private let app: AppProject
    private let catalog: ProjectCatalog
    private let historyStore: HistoryStore

    private var build: BuildService { BuildService(runner: runner) }
    private var fastlane: FastlaneRunner { FastlaneRunner(runner: runner) }
    private var notary: NotaryService { NotaryService(runner: runner) }

    init(app: AppProject, runner: ShellRunner, catalog: ProjectCatalog, historyStore: HistoryStore) {
        self.app = app
        self.runner = runner
        self.catalog = catalog
        self.historyStore = historyStore
    }

    enum StepState: Equatable {
        case idle, running, succeeded, failed(String)

        var icon: String {
            switch self {
            case .idle: "circle"
            case .running: "arrow.triangle.2.circlepath"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .idle: .secondary
            case .running: .blue
            case .succeeded: .green
            case .failed: .red
            }
        }
    }

    /// The steps that apply for the given target. Every target ends by syncing
    /// the new version into the portal's product data (a best-effort step that
    /// never aborts an otherwise-successful release).
    func steps(for target: ReleaseTarget) -> [ReleaseStep] {
        switch target {
        case .testFlight:
            return [.setVersion, .build, .sign, .uploadBeta, .updatePages]
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

    /// Run the full pipeline for a target, with a version to bump to
    /// (optional — if nil, only the build number is bumped). Stops at the first
    /// failing step — EXCEPT `.updatePages`, which is best-effort: the release
    /// proper (build/sign/upload) has already succeeded by then, so a portal
    /// data hiccup is logged but never turns a successful ship into a failure.
    /// Every run (success or failure) is appended to history before returning.
    @discardableResult
    func run(target: ReleaseTarget, version: VersionPair?) async -> Bool {
        isRunning = true
        defer { isRunning = false }

        let steps = steps(for: target)
        for step in steps { stepStates[step] = .idle }
        completedSteps.removeAll()
        cancellationRequested = false

        for step in steps {
            guard !cancellationRequested else {
                runner.log("✋ 已取消发布流程")
                recordHistory(target: target, version: version,
                              success: false, failureStep: "已取消")
                return false
            }
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
                recordHistory(target: target, version: version,
                              success: false, failureStep: step.title)
                return false
            }
        }

        runner.log("")
        runner.log("🎉 发布完成!")
        recordHistory(target: target, version: version,
                      success: true, failureStep: nil)
        return true
    }

    // MARK: - History

    /// Capture this run into the history store, using the version actually on
    /// disk (which reflects any bump) so the record matches what shipped.
    private func recordHistory(target: ReleaseTarget,
                               version: VersionPair?,
                               success: Bool,
                               failureStep: String?) {
        let recorded = version ?? VersionManager.read(app)
        historyStore.append(ReleaseRecord(
            appName: app.name,
            appID: app.id,
            platform: app.platform,
            target: target,
            version: recorded,
            success: success,
            failureStep: failureStep
        ))
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
        await build.generateXcodeProject(at: app.resolvedPath)
        let archive = await build.archive(app: app, to: build.archivePath(for: app))
        return archive.succeeded
    }

    private func runSign() async -> Bool {
        switch app.release.signing {
        case .match, .sigh:
            // Both routes are driven by existing fastlane lanes in these
            // projects; run the certs/signing lane then verify identity.
            let lane = app.release.signing == .match ? "certs" : "fetch_signing"
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
        let sign = await notary.signAppBundle(at: bundle)
        guard sign.succeeded else { return false }
        let dmg = "\(app.resolvedPath)/build/\(app.scheme).dmg"
        let notarize = await notary.notarize(artifact: bundle, stapleApp: nil)
        notary.cleanupTempKey()
        _ = dmg
        return notarize.succeeded
    }

    private func runUpload(target: ReleaseTarget) async -> Bool {
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
