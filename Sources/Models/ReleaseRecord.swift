import Foundation

/// One completed (or attempted) release, persisted to disk by `HistoryStore`
/// so the matrix's "what version did we ship for Tivon, and when?" question
/// has an answer across restarts.
struct ReleaseRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let appName: String
    let appID: String
    let platform: String          // AppPlatform.rawValue, kept loose for JSON stability
    let target: String            // ReleaseTarget.rawValue
    let marketing: String         // e.g. "1.2.3"
    let build: String             // e.g. "8"
    let timestamp: Date
    let success: Bool
    /// The step title where the pipeline stopped, when success is false.
    let failureStep: String?

    init(appName: String,
         appID: String,
         platform: AppPlatform,
         target: ReleaseTarget,
         version: VersionPair?,
         success: Bool,
         failureStep: String? = nil,
         timestamp: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.appName = appName
        self.appID = appID
        self.platform = platform.rawValue
        self.target = target.rawValue
        self.marketing = version?.marketing ?? ""
        self.build = version?.build ?? ""
        self.timestamp = timestamp
        self.success = success
        self.failureStep = failureStep
    }

    /// "1.2.3 (8)" — the compact version string shown in history rows.
    var versionLabel: String {
        switch (marketing.isEmpty, build.isEmpty) {
        case (false, false): "\(marketing) (\(build))"
        case (false, true):  marketing
        case (true, false):  "build \(build)"
        case (true, true):   "—"
        }
    }
}
