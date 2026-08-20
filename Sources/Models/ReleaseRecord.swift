import Foundation

/// What a history record was produced by. Records written before site
/// publishing existed decode as `.app`.
enum RecordKind: String, Codable {
    case app
    case site
}

/// One completed (or attempted) release, persisted to disk by `HistoryStore`
/// so the matrix's "what version did we ship for Tivon, and when?" question
/// has an answer across restarts. Also covers site deployments, where
/// `marketing` stays empty and `build` carries the deployed commit's short
/// hash so history rows stay identifiable without inventing fake versions.
struct ReleaseRecord: Codable, Identifiable, Equatable {
    /// Raw target value recorded for site deployments (apps record their
    /// `ReleaseTarget` rawValues instead).
    static let siteDeployTarget = "siteDeploy"
    /// Raw target value for site rollbacks — reverts the last deployed commit
    /// and redeploys.
    static let siteRollbackTarget = "siteRollback"

    let id: UUID
    let appName: String
    let appID: String
    let kind: RecordKind
    let platform: String          // AppPlatform.rawValue, kept loose for JSON stability
    let target: String            // ReleaseTarget.rawValue, or siteDeployTarget
    let marketing: String         // e.g. "1.2.3"
    let build: String             // e.g. "8"; site records: commit short hash
    let timestamp: Date
    let success: Bool
    /// The step title where the pipeline stopped, when success is false.
    let failureStep: String?
    /// Full run log for this attempt (nil for records written before logs
    /// were persisted, or when the log file couldn't be created).
    let logPath: String?

    init(appName: String,
         appID: String,
         platform: AppPlatform,
         target: ReleaseTarget,
         version: VersionPair?,
         success: Bool,
         failureStep: String? = nil,
         logPath: String? = nil,
         timestamp: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.appName = appName
        self.appID = appID
        self.kind = .app
        self.platform = platform.rawValue
        self.target = target.rawValue
        self.marketing = version?.marketing ?? ""
        self.build = version?.build ?? ""
        self.timestamp = timestamp
        self.success = success
        self.failureStep = failureStep
        self.logPath = logPath
    }

    /// A site deployment record: `platform` is web, the deployed commit's
    /// short hash rides in `build` (empty when the run stopped before
    /// committing), and `target` distinguishes deploys from rollbacks.
    init(siteName: String,
         siteID: String,
         commitShortHash: String?,
         success: Bool,
         failureStep: String? = nil,
         logPath: String? = nil,
         target: String = ReleaseRecord.siteDeployTarget,
         timestamp: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.appName = siteName
        self.appID = siteID
        self.kind = .site
        self.platform = AppPlatform.web.rawValue
        self.target = target
        self.marketing = ""
        self.build = commitShortHash ?? ""
        self.timestamp = timestamp
        self.success = success
        self.failureStep = failureStep
        self.logPath = logPath
    }

    /// Hand-rolled so fields added later (`logPath`, `kind`) decode with
    /// defaults from history files written by older versions instead of
    /// failing the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appName = try c.decode(String.self, forKey: .appName)
        appID = try c.decode(String.self, forKey: .appID)
        kind = try c.decodeIfPresent(RecordKind.self, forKey: .kind) ?? .app
        platform = try c.decode(String.self, forKey: .platform)
        target = try c.decode(String.self, forKey: .target)
        marketing = try c.decode(String.self, forKey: .marketing)
        build = try c.decode(String.self, forKey: .build)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        success = try c.decode(Bool.self, forKey: .success)
        failureStep = try c.decodeIfPresent(String.self, forKey: .failureStep)
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(appName, forKey: .appName)
        try c.encode(appID, forKey: .appID)
        try c.encode(kind, forKey: .kind)
        try c.encode(platform, forKey: .platform)
        try c.encode(target, forKey: .target)
        try c.encode(marketing, forKey: .marketing)
        try c.encode(build, forKey: .build)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(success, forKey: .success)
        try c.encodeIfPresent(failureStep, forKey: .failureStep)
        try c.encodeIfPresent(logPath, forKey: .logPath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, appName, appID, kind, platform, target, marketing, build
        case timestamp, success, failureStep, logPath
    }

    /// "1.2.3 (8)" — the compact version string shown in history rows.
    /// Site rows show their deployed commit instead ("3f2a1b2").
    var versionLabel: String {
        switch (kind, marketing.isEmpty, build.isEmpty) {
        case (.site, _, false):   build
        case (_, false, false):   "\(marketing) (\(build))"
        case (_, false, true):    marketing
        case (_, true, false):    "build \(build)"
        case (_, true, true):     "—"
        }
    }

    /// Human label for the recorded target (apps: TestFlight/App Store/…;
    /// sites: 站点部署 / 站点回滚).
    var targetLabel: String {
        switch target {
        case Self.siteDeployTarget: return "站点部署"
        case Self.siteRollbackTarget: return "站点回滚"
        default: return ReleaseTarget(rawValue: target)?.title ?? target
        }
    }

    /// Whether the run log still exists on disk (drives the history row's
    /// "打开日志" button).
    var logFileExists: Bool {
        guard let logPath else { return false }
        return FileManager.default.fileExists(atPath: logPath)
    }
}
