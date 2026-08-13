import XCTest

/// Hermetic tests for `ProjectLocator`. Each test builds a throwaway tree that
/// mirrors real layouts (origin-matched checkouts, a deep scheme-only nest like
/// TuneSync, nested support sites, gitdir pointers) under a temp root and passes
/// that root explicitly — nothing on the real machine is ever scanned.
final class ProjectLocatorTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ProjectLocator-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - App relocation

    func testRelocatesAppByOriginMatchAtTopLevel() throws {
        let checkout = makeDir(root, "vibeforge/atvtool")
        makeGitConfig(at: checkout, origin: "git@github.com:vibeforge2014/atvtool.git")
        makeDir(checkout, "ATVTool.xcodeproj")

        let app = appFixture(scheme: "ATVTool",
                             repositoryURL: "git@github.com:vibeforge2014/atvtool.git")
        let locator = ProjectLocator(roots: [root.path])

        XCTAssertEqual(locator.relocate(app)?.resolvedPath,
                       resolved(root.appendingPathComponent("vibeforge/atvtool").path))
    }

    func testRelocatesAppWithNestedXcodeprojInsideOriginMatch() throws {
        // minuteflow-style monorepo: origin matches, but the .xcodeproj is nested.
        let checkout = makeDir(root, "vibeforge/minuteflow")
        makeGitConfig(at: checkout, origin: "https://github.com/vibeforge2014/minuteflow-source.git")
        let project = makeDir(checkout, "ios/MeetingAssistant")
        makeDir(project, "MeetingAssistant.xcodeproj")

        let app = appFixture(scheme: "MeetingAssistant",
                             repositoryURL: "git@github.com:vibeforge2014/minuteflow-source.git")
        let locator = ProjectLocator(roots: [root.path])

        XCTAssertEqual(locator.relocate(app)?.resolvedPath, resolved(project.path))
    }

    func testFallsBackToSchemeSearchWhenOriginDiffers() throws {
        // TuneSync-style: the configured repo URL no longer matches the local
        // remote, and the .xcodeproj is deeply nested. Only scheme search finds it.
        let nest = makeDir(root, "Desktop/TuneSync/ios-native/TuneSync")
        makeGitConfig(at: nest, origin: "git@github.com:JackZhen1324/TuneSync.git")
        makeDir(nest, "TuneSync.xcodeproj")

        let app = appFixture(scheme: "TuneSync",
                             repositoryURL: "git@github.com:vibeforge2014/TuneSync-iOS.git")
        let locator = ProjectLocator(roots: [root.appendingPathComponent("Desktop").path])

        XCTAssertEqual(locator.relocate(app)?.resolvedPath, resolved(nest.path))
    }

    func testLeavesValidPathAlone() throws {
        let checkout = makeDir(root, "vibeforge/atvtool")
        let app = AppProject(id: "tivon", name: "Tivon", path: checkout.path,
                             repositoryURL: "git@github.com:vibeforge2014/atvtool.git",
                             platform: .ios, scheme: "ATVTool", bundleId: "com.atvtool.ios",
                             versionSource: .projectYml,
                             release: ReleaseConfig(engine: .native, signing: .manual))
        let locator = ProjectLocator(roots: [root.path])

        XCTAssertNil(locator.relocate(app), "An existing path must never be overwritten")
    }

    func testReturnsNilWhenNothingMatches() {
        let app = appFixture(scheme: "DoesNotExist", repositoryURL: "git@github.com:x/y.git")
        let locator = ProjectLocator(roots: [root.path])
        XCTAssertNil(locator.relocate(app))
    }

    // MARK: - Site relocation

    func testRelocatesNestedSiteByOrigin() throws {
        // tivon-support lives under an unrelated parent (atvtool/support-site);
        // only its own origin identifies it, not its directory name.
        let site = makeDir(root, "vibeforge/atvtool/support-site")
        makeGitConfig(at: site, origin: "git@github.com:vibeforge2014/tivon-support.git")

        let project = SiteProject(id: "tivon-support", name: "Tivon 发布页", path: "",
                                  repositoryURL: "git@github.com:vibeforge2014/tivon-support.git",
                                  deploy: .gitPushMain)
        let locator = ProjectLocator(roots: [root.path])

        XCTAssertEqual(locator.relocate(project)?.resolvedPath, resolved(site.path))
    }

    func testRelocatesTopLevelSiteByOrigin() throws {
        let portal = makeDir(root, "vibeforge/portal")
        makeGitConfig(at: portal, origin: "https://github.com/vibeforge2014/portal.git")

        let project = SiteProject(id: "portal", name: "Portal", path: "",
                                  repositoryURL: "git@github.com:vibeforge2014/portal.git",
                                  deploy: .ghPages)
        let locator = ProjectLocator(roots: [root.path])

        XCTAssertEqual(locator.relocate(project)?.resolvedPath, resolved(portal.path))
    }

    func testDoesNotGuessSiteWithoutOriginMatch() throws {
        // A directory whose name matches but whose origin differs must NOT be
        // adopted — sites have no scheme, so a name match alone is unsafe.
        let decoy = makeDir(root, "vibeforge/portal")
        makeGitConfig(at: decoy, origin: "git@github.com:someone-else/portal.git")

        let project = SiteProject(id: "portal", name: "Portal", path: "",
                                  repositoryURL: "git@github.com:vibeforge2014/portal.git",
                                  deploy: .ghPages)
        let locator = ProjectLocator(roots: [root.path])

        XCTAssertNil(locator.relocate(project))
    }

    // MARK: - Remote normalization & parsing

    func testNormalizeEquivalenceAcrossUrlForms() {
        let ssh = ProjectLocator.normalize("git@github.com:Owner/Repo.git")
        let https = ProjectLocator.normalize("https://github.com/Owner/Repo.git")
        let sshPrefix = ProjectLocator.normalize("ssh://git@github.com/Owner/Repo.git")
        XCTAssertEqual(ssh, "owner/repo")
        XCTAssertEqual(https, ssh)
        XCTAssertEqual(sshPrefix, ssh)
        XCTAssertEqual(ProjectLocator.normalize("https://github.com/Owner/Repo"), ssh)
    }

    func testOriginRemoteReadsGitdirPointer() throws {
        // A submodule/worktree stores a `.git` *file* pointing at the real gitdir.
        // That gitdir's `config` lives at its root (bare-style layout).
        let checkout = makeDir(root, "worktree")
        let bareGitdir = makeDir(root, "real.git")
        try "gitdir: \(bareGitdir.path)\n".write(
            to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:vibeforge2014/atvtool.git
        """
        try config.write(to: bareGitdir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ProjectLocator.originRemote(at: checkout.path),
                       "git@github.com:vibeforge2014/atvtool.git")
    }

    func testOriginRemoteNilForNonRepository() {
        let notARepo = makeDir(root, "plain-dir")
        XCTAssertNil(ProjectLocator.originRemote(at: notARepo.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeDir(_ parent: URL, _ relativePath: String) -> URL {
        let url = parent.appendingPathComponent(relativePath, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeGitConfig(at checkout: URL, origin: String) {
        let gitDir = checkout.appendingPathComponent(".git")
        try? fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = \(origin)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        """
        try? config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    private func appFixture(scheme: String, repositoryURL: String) -> AppProject {
        AppProject(id: "fixture", name: "Fixture", path: "",
                   repositoryURL: repositoryURL, platform: .ios, scheme: scheme,
                   bundleId: "example.fixture", versionSource: .projectYml,
                   release: ReleaseConfig(engine: .native, signing: .manual))
    }

    /// Compares paths symlink-blind: macOS temp dirs live under `/var`, a
    /// symlink to `/private/var`, so the locator's canonical output (resolved
    /// by FileManager) and the test's constructed path differ in spelling only.
    /// `URL.resolvingSymlinksInPath` does not resolve `/var`, so use realpath.
    private func resolved(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return path }
        return String(cString: buf)
    }
}
