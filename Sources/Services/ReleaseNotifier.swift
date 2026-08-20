import AppKit
import Foundation
import UserNotifications

/// Posts release-finished notifications and routes notification clicks back
/// into the app. The delegate must be installed before any notification is
/// delivered, so `activate()` is called once from `ReleaseCenter`'s init
/// (which runs at app startup) — macOS drops `didReceive` callbacks for
/// notifications delivered before a delegate exists.
final class ReleaseNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReleaseNotifier()

    /// Set by `ReleaseCenter`: called on the main actor with the app id a
    /// notification click should navigate to.
    var onFocusAppID: (@MainActor (String) -> Void)?
    /// Same, for site deploy notifications.
    var onFocusSiteID: (@MainActor (String) -> Void)?

    private var authorizationRequested = false

    private override init() { super.init() }

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for alert+sound permission the first time a release starts.
    /// Denied (or failing) authorization is fine — the release proceeds and
    /// simply finishes silently, like before notifications existed.
    func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Fire-and-forget: notification delivery is best-effort and never
    /// blocks or fails the release. Exactly one of the focus ids should be
    /// set — it routes a notification click back to the project.
    func post(title: String, body: String, focusAppID: String? = nil, focusSiteID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let focusAppID {
            content.userInfo = ["focusAppID": focusAppID]
        } else if let focusSiteID {
            content.userInfo = ["focusSiteID": focusSiteID]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when this app is frontmost — the whole point is
    /// telling a user who switched away *back* (and one who stayed put).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let appID = userInfo["focusAppID"] as? String
        let siteID = userInfo["focusSiteID"] as? String
        guard appID != nil || siteID != nil else {
            completionHandler()
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let appID {
                self.onFocusAppID?(appID)
            } else if let siteID {
                self.onFocusSiteID?(siteID)
            }
        }
        completionHandler()
    }
}
