import Foundation
import SwiftUI
import Combine
import AppKit

/// A long-lived registry of per-project `ShellRunner`s, keyed by a stable id.
///
/// The original design stored a `@StateObject ShellRunner` inside each detail
/// view (`ProjectDetail` / `SiteDetail` / `PagesManagerView`). Because
/// `ContentView` switches detail views with `.id(id)` — which destroys the
/// whole view subtree — switching apps also destroyed the runner. That wiped
/// the console log and orphaned the running `Process` (its
/// `readabilityHandler` closures use `[weak self]`, so once the runner
/// deinitialized they stopped appending output even though the build kept
/// running). The fix: lift runner ownership to the App level so it survives
/// sidebar switches.
@MainActor
final class ConsoleRegistry: ObservableObject {
    /// Keys of runners currently mid-command, e.g. `"app:tivon"`,
    /// `"site:minuteflow"`, `"pages-manager"`. Maintained by observing each
    /// runner's `isRunning`, so the sidebar can render a live "who's running"
    /// indicator without polling.
    @Published private(set) var runningIds: Set<String> = []

    private var runners: [String: ShellRunner] = [:]
    private var cancellables: [String: AnyCancellable] = [:]

    init() {
        // Best-effort cleanup on quit: terminate any direct child process still
        // running in a cached runner. Foundation's `Process` can't kill the
        // whole process group, so grandchildren (e.g. xcodebuild spawned by the
        // zsh wrapper) may linger — a known limitation.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.terminateAll() }
        }
    }

    /// Return (creating on first use) the runner for `key`. Subscribes to its
    /// `isRunning` so `runningIds` stays in sync for the sidebar indicator.
    func runner(for key: String) -> ShellRunner {
        if let existing = runners[key] { return existing }
        let r = ShellRunner()
        runners[key] = r
        cancellables[key] = r.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                // Hop to the main actor: the closure isn't `@MainActor`-isolated,
                // and `runningIds` lives on this `@MainActor` class.
                Task { @MainActor in
                    guard let self else { return }
                    if running {
                        self.runningIds.insert(key)
                    } else {
                        self.runningIds.remove(key)
                    }
                }
            }
        return r
    }

    // MARK: - Convenience keys

    func runnerForApp(_ id: String) -> ShellRunner { runner(for: "app:\(id)") }
    func runnerForSite(_ id: String) -> ShellRunner { runner(for: "site:\(id)") }
    func runnerForPages() -> ShellRunner { runner(for: Self.pagesKey) }

    func isAppRunning(_ id: String) -> Bool { runningIds.contains("app:\(id)") }
    func isSiteRunning(_ id: String) -> Bool { runningIds.contains("site:\(id)") }

    static let pagesKey = "pages-manager"

    /// Terminate every still-running runner. Called on app quit.
    func terminateAll() {
        for (_, r) in runners where r.isRunning {
            r.terminate()
        }
    }
}
