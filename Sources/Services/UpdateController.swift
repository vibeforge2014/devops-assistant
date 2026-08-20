import SwiftUI

/// Drives the update sheet's state machine: one `phase` for the UI, one
/// cancellable task at a time. The service does the network and process
/// work; launch-time auto-checks fail silently — only manual checks
/// surface errors.
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdateInfo)
        case downloading
        case verifying
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var showSheet = false

    let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private let service: AppUpdateService
    private var task: Task<Void, Never>?
    /// Latest known release — retry re-offers it without a re-check.
    private(set) var latest: AppUpdateInfo?

    init(service: AppUpdateService = AppUpdateService()) {
        self.service = service
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        if isBusy {
            if userInitiated { showSheet = true }
            return
        }
        phase = .checking
        if userInitiated { showSheet = true }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.service.latestRelease()
                self.latest = info
                if info.isNewer(than: self.currentVersion) {
                    self.phase = .available(info)
                    self.showSheet = true
                } else {
                    self.phase = .upToDate
                    if userInitiated { self.showSheet = true }
                }
            } catch is CancellationError {
            } catch {
                if userInitiated {
                    self.phase = .failed(error.localizedDescription)
                    self.showSheet = true
                } else {
                    self.phase = .idle
                }
            }
        }
    }

    func downloadAndInstall() {
        guard case .available(let info) = phase else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.phase = .downloading
                let dmg = try await self.service.download(info)
                self.phase = .verifying
                try await self.service.verifyNotarization(dmgURL: dmg)
                self.phase = .installing
                // Success relaunches and never returns; a return only
                // happens via throw (manual-install fallback, failures).
                try await self.service.installAndRelaunch(dmgURL: dmg)
            } catch is CancellationError {
                self.phase = self.latest.map { Phase.available($0) } ?? .idle
            } catch let error as AppUpdateError {
                if case .needsManualInstall(let dmgPath) = error {
                    NSWorkspace.shared.open(URL(fileURLWithPath: dmgPath))
                }
                self.phase = .failed(error.errorDescription ?? "更新失败")
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        task?.cancel()
    }

    /// Back to the "new version" card if we already know one, otherwise
    /// start a fresh check.
    func retry() {
        if let latest {
            phase = .available(latest)
        } else {
            checkForUpdates(userInitiated: true)
        }
    }

    func openReleasePage(_ info: AppUpdateInfo) {
        if let url = info.htmlURL { NSWorkspace.shared.open(url) }
    }
}
