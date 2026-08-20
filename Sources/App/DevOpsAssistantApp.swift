import SwiftUI

/// Quit interception: with tasks mid-flight (a release, a build), exiting
/// silently would orphan them with no history record and no flushed log.
/// The confirm-and-interrupt path records an "应用退出中断" entry first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var registry: ConsoleRegistry?
    var releaseCenter: ReleaseCenter?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let registry, !registry.runningIds.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "有 \(registry.runningIds.count) 个任务仍在运行"
        alert.informativeText = "退出会中断正在执行的发布或构建。已完成的部分会写入发布历史,但被中断的后台上传可能继续且不再有记录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "中断并退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        releaseCenter?.markAllInterrupted()
        registry.terminateAll()
        return .terminateNow
    }
}

@main
struct DevOpsAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var catalog: ProjectCatalog
    @StateObject private var historyStore: HistoryStore
    @StateObject private var registry: ConsoleRegistry
    @StateObject private var releaseCenter: ReleaseCenter
    @StateObject private var storeInfo = AppStoreInfoService()
    @StateObject private var navigation = NavigationModel()
    @StateObject private var updateController = UpdateController()
    @State private var showOnboarding = false

    init() {
        // Wire the object graph by hand: ReleaseCenter needs the other three,
        // so they're constructed here (once — StateObject keeps the first
        // instance across any App re-inits) and injected via StateObject.
        let catalog = ProjectCatalog()
        let historyStore = HistoryStore()
        let registry = ConsoleRegistry()
        _catalog = StateObject(wrappedValue: catalog)
        _historyStore = StateObject(wrappedValue: historyStore)
        _registry = StateObject(wrappedValue: registry)
        _releaseCenter = StateObject(wrappedValue: ReleaseCenter(
            registry: registry, catalog: catalog, historyStore: historyStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .environmentObject(historyStore)
                .environmentObject(registry)
                .environmentObject(releaseCenter)
                .environmentObject(storeInfo)
                .environmentObject(navigation)
                .frame(minWidth: 980, minHeight: 620)
                .sheet(isPresented: $updateController.showSheet) {
                    UpdateView()
                        .environmentObject(updateController)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                        .environmentObject(catalog)
                }
                .onAppear {
                    // First run: if essential credentials are missing, walk the
                    // user through onboarding (which auto-imports what it can).
                    appDelegate.registry = registry
                    appDelegate.releaseCenter = releaseCenter
                    if !OnboardingService.isFullyConfigured {
                        showOnboarding = true
                    }
                    // Silent update check shortly after launch; the sheet only
                    // appears when a newer release actually exists (or on
                    // manual checks). Failures here stay invisible.
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        updateController.checkForUpdates(userInitiated: false)
                    }
                }
                .onReceive(catalog.$data) { data in
                    // Deleting a project must drop its cached console/store
                    // state, or a new project reusing the id would inherit
                    // the old logs, running flags and price data.
                    registry.evict(keepingAppIDs: Set(data.apps.map(\.id)),
                                   keepingSiteIDs: Set(data.sites.map(\.id)))
                    storeInfo.evict(keepingAppIDs: Set(data.apps.map(\.id)))
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {} // no new-window
            CommandMenu("运维") {
                Button("检查更新…") { updateController.checkForUpdates(userInitiated: true) }
                Divider()
                Button("重新配置凭据…") { showOnboarding = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(catalog)
                .environmentObject(registry)
        }
    }
}
