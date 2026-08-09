import Foundation

/// The platform an app or site targets.
enum AppPlatform: String, Codable, CaseIterable {
    case ios
    case macos
    case tvos
    case web

    var displayName: String {
        switch self {
        case .ios: "iOS"
        case .macos: "macOS"
        case .tvos: "tvOS"
        case .web: "Web"
        }
    }
}

/// How a project's marketing/build version is stored on disk. The
/// `VersionManager` adapts its read/write logic to this source.
enum VersionSource: String, Codable, CaseIterable {
    case projectYml = "project.yml"
    case pbxproj
    case xcconfig
}

/// The signing mechanism a release uses. Drives how credentials are injected.
enum SigningMethod: String, Codable, CaseIterable {
    case match       // fastlane match (encrypted git repo)
    case sigh        // fastlane cert + sigh
    case developerID = "developer-id"   // macOS Developer ID hand-signing
    case manual      // hand-maintained ExportOptions.plist
}

/// The build/release engine that drives a project.
enum ReleaseEngine: String, Codable, CaseIterable {
    case fastlane    // delegate to an existing Fastfile lane
    case native      // assistant drives xcodebuild/notarytool directly
}

/// Release configuration for an app — how to build, sign, and ship it.
struct ReleaseConfig: Codable, Equatable {
    let engine: ReleaseEngine
    /// fastlane lane for TestFlight beta uploads (nil when engine != fastlane).
    let betaLane: String?
    /// fastlane lane for App Store release (nil when engine != fastlane).
    let releaseLane: String?
    /// Optional lane that only prepares/installs signing assets. Some Fastfiles
    /// perform signing inside beta/release and therefore intentionally omit it.
    let signingLane: String?
    let signing: SigningMethod
    /// Per-project Match repository. A single global URL is only a fallback:
    /// different apps may intentionally keep profiles in different repos.
    let matchGitURL: String?
    /// Whether macOS notarization is required after signing.
    let notarize: Bool

    init(engine: ReleaseEngine,
         betaLane: String? = nil,
         releaseLane: String? = nil,
         signingLane: String? = nil,
         signing: SigningMethod,
         matchGitURL: String? = nil,
         notarize: Bool = false) {
        self.engine = engine
        self.betaLane = betaLane
        self.releaseLane = releaseLane
        self.signingLane = signingLane
        self.signing = signing
        self.matchGitURL = matchGitURL
        self.notarize = notarize
    }
}

/// One app in the VibeForge product matrix.
struct AppProject: Codable, Identifiable, Equatable {
    let id: String          // stable slug, e.g. "tivon"
    let name: String        // display name, e.g. "Tivon"
    let path: String        // absolute or ~-prefixed project root
    let repositoryURL: String // complete Git clone URL (SSH or HTTPS)
    let platform: AppPlatform
    let scheme: String      // Xcode scheme to build
    let bundleId: String
    let versionSource: VersionSource
    let release: ReleaseConfig

    /// Expand a leading ~ to the user's home directory.
    var resolvedPath: String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }

    /// Whether the project root exists on disk.
    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: resolvedPath)
    }
}

/// One GitHub Pages site (support/release page) in the matrix.
struct SiteProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String        // local clone root
    let repositoryURL: String // complete Git clone URL (SSH or HTTPS)
    let deploy: DeployMethod

    init(id: String, name: String, path: String,
         repositoryURL: String, deploy: DeployMethod) {
        self.id = id
        self.name = name
        self.path = path
        self.repositoryURL = repositoryURL
        self.deploy = deploy
    }

    /// Decode the current full-URL shape and the legacy `repo: owner/name`
    /// shape used by bundled catalogs before project management was editable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        deploy = try container.decode(DeployMethod.self, forKey: .deploy)
        if let url = try container.decodeIfPresent(String.self, forKey: .repositoryURL) {
            repositoryURL = url
        } else {
            let legacy = try container.decode(String.self, forKey: .repo)
            repositoryURL = legacy.contains("://") || legacy.hasPrefix("git@")
                ? legacy
                : "git@github.com:\(legacy).git"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(repositoryURL, forKey: .repositoryURL)
        try container.encode(deploy, forKey: .deploy)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, repositoryURL, repo, deploy
    }

    var resolvedPath: String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: resolvedPath)
    }
}

/// How a site is published after a push.
enum DeployMethod: String, Codable, CaseIterable {
    /// Push to main triggers a GitHub Actions workflow that builds & deploys.
    case gitPushMain = "git-push-main"
    /// The portal: gh-pages npm package pushes out/ to the gh-pages branch.
    case ghPages = "gh-pages"
}

/// A release destination exposed by the one-click release flow.
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

    static func available(for app: AppProject) -> [ReleaseTarget] {
        if app.platform == .macos {
            return app.release.notarize ? [.macDistribution] : []
        }
        guard app.platform == .ios || app.platform == .tvos else { return [] }
        // Every local iOS project can use the built-in IPA + altool fallback.
        var targets: [ReleaseTarget] = [.testFlight]
        if app.release.releaseLane != nil { targets.append(.appStore) }
        return targets
    }
}

/// The top-level catalog: all apps and sites managed by the assistant.
struct ProjectCatalogData: Codable {
    let apps: [AppProject]
    let sites: [SiteProject]
}
