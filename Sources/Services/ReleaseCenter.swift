import Combine
import Foundation
import SwiftUI

/// App-level home of the per-project coordinators (`ReleaseCoordinator` for
/// apps, `SitePublishCoordinator` for sites). Lifting ownership here (same
/// move `ConsoleRegistry` made for runners in v1.2) is what lets a release
/// keep running after its wizard sheet is dismissed: the sheet is just a
/// window onto the shared coordinator and can be reopened any time to watch
/// live progress.
///
/// Also the single place release *completion* is handled: it translates a
/// coordinator's outcome into a user notification and, when the notification
/// is clicked, publishes a pending-focus id for `ContentView` to navigate.
@MainActor
final class ReleaseCenter: ObservableObject {
    /// App id a notification click asked to navigate to; consumed (and
    /// cleared) by ContentView's sidebar binding.
    @Published private(set) var pendingFocusAppID: String?
    /// Same, for site deploy notifications.
    @Published private(set) var pendingFocusSiteID: String?

    private let registry: ConsoleRegistry
    private let catalog: ProjectCatalog
    private let historyStore: HistoryStore
    private var coordinators: [String: ReleaseCoordinator] = [:]
    private var siteCoordinators: [String: SitePublishCoordinator] = [:]
    private var cancellables: [String: AnyCancellable] = [:]
    private var catalogCancellable: AnyCancellable?

    init(registry: ConsoleRegistry, catalog: ProjectCatalog, historyStore: HistoryStore) {
        self.registry = registry
        self.catalog = catalog
        self.historyStore = historyStore

        ReleaseNotifier.shared.activate()
        ReleaseNotifier.shared.onFocusAppID = { [weak self] id in
            guard let self, self.catalog.app(id: id) != nil else { return }
            self.pendingFocusAppID = id
        }
        ReleaseNotifier.shared.onFocusSiteID = { [weak self] id in
            guard let self, self.catalog.site(id: id) != nil else { return }
            self.pendingFocusSiteID = id
        }
        RunLogStore.enforceRetention()

        // Project edits (new path, new lanes) take effect on the next
        // release: drop idle coordinators so they're rebuilt from fresh
        // catalog data. A coordinator mid-run keeps its snapshot — that's
        // the config the running pipeline started with.
        catalogCancellable = catalog.$data.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (id, coordinator) in self.coordinators where !coordinator.isRunning {
                    self.coordinators[id] = nil
                    self.cancellables[id] = nil
                }
                for (id, coordinator) in self.siteCoordinators where !coordinator.isRunning {
                    self.siteCoordinators[id] = nil
                    self.cancellables["site:\(id)"] = nil
                }
            }
        }
    }

    /// Return (creating on first use) the shared coordinator for an app.
    /// Its runner comes from the registry under `release:<id>`, so the
    /// sidebar's live "who's running" indicator covers releases too.
    func coordinator(for app: AppProject) -> ReleaseCoordinator {
        if let existing = coordinators[app.id] { return existing }

        let runner = registry.runnerForRelease(app.id)
        let coordinator = ReleaseCoordinator(app: app, runner: runner,
                                             catalog: catalog, historyStore: historyStore)
        coordinator.onFinish = { [weak self] outcome, target, version in
            self?.handleFinish(app: app, outcome: outcome, target: target, version: version)
        }
        coordinators[app.id] = coordinator
        cancellables[app.id] = coordinator.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                Task { @MainActor in
                    guard running else { return }
                    // Ask once, right before the first release could finish
                    // while the user is elsewhere.
                    await ReleaseNotifier.shared.requestAuthorizationIfNeeded()
                }
            }
        return coordinator
    }

    /// Return (creating on first use) the shared publish coordinator for a
    /// site. Its runner comes from the registry under `site-release:<id>`.
    func siteCoordinator(for site: SiteProject) -> SitePublishCoordinator {
        if let existing = siteCoordinators[site.id] { return existing }

        let runner = registry.runnerForSiteRelease(site.id)
        let coordinator = SitePublishCoordinator(site: site, runner: runner,
                                                 historyStore: historyStore)
        coordinator.onFinish = { [weak self] outcome, commitHash in
            self?.handleSiteFinish(site: site, outcome: outcome, commitHash: commitHash)
        }
        siteCoordinators[site.id] = coordinator
        cancellables["site:\(site.id)"] = coordinator.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                Task { @MainActor in
                    guard running else { return }
                    await ReleaseNotifier.shared.requestAuthorizationIfNeeded()
                }
            }
        return coordinator
    }

    func clearFocus() {
        pendingFocusAppID = nil
        pendingFocusSiteID = nil
    }

    /// Called by the quit path after the user confirms an interrupting exit:
    /// leaves a history record + flushed log for every in-flight run.
    func markAllInterrupted() {
        for coordinator in coordinators.values where coordinator.isRunning {
            coordinator.markInterrupted()
        }
        for coordinator in siteCoordinators.values where coordinator.isRunning {
            coordinator.markInterrupted()
        }
    }

    // MARK: - Batch site publishing

    struct BatchPublishSummary: Equatable {
        var published = 0
        var nothingToPublish = 0
        var failed: [String] = []
        var skipped: [String] = []

        var line: String {
            var parts = ["成功 \(published)"]
            if nothingToPublish > 0 { parts.append("无变更 \(nothingToPublish)") }
            if !failed.isEmpty { parts.append("失败 \(failed.count):\(failed.joined(separator: "、"))") }
            if !skipped.isEmpty { parts.append("跳过 \(skipped.count):\(skipped.joined(separator: "、"))") }
            return parts.joined(separator: " · ")
        }
    }

    /// Publish several sites sequentially through the full pipeline (pull →
    /// commit → publish), each with its own history record and run log, all
    /// streaming into the pages-manager console. One summary notification at
    /// the end instead of one per site.
    @discardableResult
    func runBatchPublish(sites: [SiteProject], message: String) async -> BatchPublishSummary {
        let runner = registry.runnerForPages()
        runner.clear()
        var summary = BatchPublishSummary()

        for site in sites {
            // A site whose own runner got busy since selection would race
            // this batch on the same clone — skip it explicitly.
            guard !registry.isSiteBusy(site.id) else {
                runner.log("⏭ \(site.name) 正在执行其他操作,本次跳过")
                summary.skipped.append(site.name)
                continue
            }
            let coordinator = SitePublishCoordinator(site: site, runner: runner,
                                                     historyStore: historyStore)
            // clearLog: false keeps earlier sites' output on the console;
            // a fresh coordinator still opens its own per-site log file.
            let succeeded = await coordinator.run(message: message, clearLog: false)
            if succeeded {
                summary.published += 1
            } else if coordinator.lastOutcome == .nothingToPublish {
                summary.nothingToPublish += 1
            } else {
                summary.failed.append(site.name)
            }
        }

        await ReleaseNotifier.shared.requestAuthorizationIfNeeded()
        if summary.published == 0, summary.nothingToPublish > 0, summary.failed.isEmpty {
            ReleaseNotifier.shared.post(title: "批量站点部署",
                                        body: "所有站点均无需要发布的变更")
        } else {
            ReleaseNotifier.shared.post(title: summary.failed.isEmpty ? "批量站点部署完成" : "批量站点部署结束",
                                        body: summary.line)
        }
        return summary
    }

    // MARK: - Notifications

    private func handleFinish(app: AppProject,
                              outcome: ReleaseCoordinator.RunOutcome,
                              target: ReleaseTarget,
                              version: VersionPair?) {
        let versionLabel = version.map { "\($0.marketing) (\($0.build))" } ?? ""
        switch outcome {
        case .success:
            ReleaseNotifier.shared.post(
                title: "\(app.name) 发布完成",
                body: "\(target.title) · \(versionLabel)".trimmingCharacters(in: .whitespaces),
                focusAppID: app.id)
        case .failed(let step):
            ReleaseNotifier.shared.post(
                title: "\(app.name) 发布失败",
                body: "「\(step)」步骤中断 · \(target.title)",
                focusAppID: app.id)
        case .cancelled:
            ReleaseNotifier.shared.post(
                title: "\(app.name) 已取消发布",
                body: target.title,
                focusAppID: app.id)
        case .nothingToPublish:
            // Only site pipelines produce this; apps never do.
            break
        }
    }

    private func handleSiteFinish(site: SiteProject,
                                  outcome: PipelineOutcome,
                                  commitHash: String?) {
        let hashLabel = commitHash.map { "commit \($0)" } ?? ""
        switch outcome {
        case .success:
            ReleaseNotifier.shared.post(
                title: "\(site.name) 部署完成",
                body: "站点部署 · \(hashLabel)".trimmingCharacters(in: .whitespaces),
                focusSiteID: site.id)
        case .failed(let step):
            ReleaseNotifier.shared.post(
                title: "\(site.name) 部署失败",
                body: "「\(step)」步骤中断",
                focusSiteID: site.id)
        case .cancelled:
            ReleaseNotifier.shared.post(
                title: "\(site.name) 已取消部署",
                body: "站点部署",
                focusSiteID: site.id)
        case .nothingToPublish:
            ReleaseNotifier.shared.post(
                title: "\(site.name) 无需部署",
                body: "工作区干净,没有领先远端的提交",
                focusSiteID: site.id)
        }
    }
}
