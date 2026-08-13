import XCTest

@MainActor
final class ProjectCatalogTests: XCTestCase {
    private var root: URL!
    private var userURL: URL!
    private var bundledURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        userURL = root.appendingPathComponent("support/projects.json")
        bundledURL = root.appendingPathComponent("bundled.json")
        try encode(ProjectCatalogData(apps: [makeApp()], sites: [makeSite()]), to: bundledURL)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFirstLaunchSeedsUserCatalogAndReloadUsesIt() throws {
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [])
        XCTAssertEqual(catalog.apps.map(\.id), ["fixture"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: userURL.path))

        try catalog.addSite(SiteProject(id: "new-site", name: "New", path: "/missing",
                                        repositoryURL: "https://github.com/example/new-site.git",
                                        deploy: .gitPushMain))
        let reloaded = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [])
        XCTAssertEqual(reloaded.sites.map(\.id), ["fixture-site", "new-site"])
    }

    func testCRUDPersistsAndDeleteDoesNotTouchProjectDirectory() throws {
        let projectDirectory = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [])
        let added = makeApp(id: "second", path: projectDirectory.path)
        try catalog.addApp(added)

        let updated = AppProject(id: added.id, name: "Renamed", path: added.path,
                                 repositoryURL: "git@github.com:example/renamed.git",
                                 platform: added.platform, scheme: added.scheme,
                                 bundleId: added.bundleId, versionSource: added.versionSource,
                                 release: added.release)
        try catalog.updateApp(updated, originalID: added.id)
        XCTAssertEqual(catalog.app(id: "second")?.name, "Renamed")

        try catalog.deleteApp(id: added.id)
        XCTAssertNil(catalog.app(id: added.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDirectory.path))
    }

    func testCorruptUserFileFallsBackWithoutOverwritingIt() throws {
        try FileManager.default.createDirectory(at: userURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: userURL)
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [])

        XCTAssertEqual(catalog.apps.map(\.id), ["fixture"])
        XCTAssertNotNil(catalog.errorMessage)
        XCTAssertEqual(try Data(contentsOf: userURL), corrupt)
    }

    func testPersistenceFailureDoesNotPublishMutation() throws {
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockingFile)
        let impossibleURL = blockingFile.appendingPathComponent("projects.json")
        let catalog = ProjectCatalog(fileURL: impossibleURL, bundledURL: bundledURL, relocationRoots: [])
        let before = catalog.apps

        XCTAssertThrowsError(try catalog.addApp(makeApp(id: "second")))
        XCTAssertEqual(catalog.apps, before)
    }

    func testValidationRejectsInvalidAndDuplicateIDsAndURLs() throws {
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [])
        XCTAssertThrowsError(try catalog.addApp(makeApp(id: "Bad ID")))
        XCTAssertThrowsError(try catalog.addApp(makeApp()))
        var invalid = makeApp(id: "invalid-url")
        invalid = AppProject(id: invalid.id, name: invalid.name, path: invalid.path,
                             repositoryURL: "example/repo", platform: invalid.platform,
                             scheme: invalid.scheme, bundleId: invalid.bundleId,
                             versionSource: invalid.versionSource, release: invalid.release)
        XCTAssertThrowsError(try catalog.addApp(invalid))
        XCTAssertTrue(ProjectCatalog.isValidRepositoryURL("git@github.com:owner/repo.git"))
        XCTAssertTrue(ProjectCatalog.isValidRepositoryURL("https://github.com/owner/repo.git"))
        XCTAssertTrue(ProjectCatalog.isValidRepositoryURL("ssh://git@github.com/owner/repo.git"))
    }

    func testLegacySiteRepoDecodesAndReencodesAsFullURL() throws {
        let json = #"{"id":"legacy","name":"Legacy","path":"/tmp/missing","repo":"owner/repo","deploy":"git-push-main"}"#
        let site = try JSONDecoder().decode(SiteProject.self, from: Data(json.utf8))
        XCTAssertEqual(site.repositoryURL, "git@github.com:owner/repo.git")
        let encoded = String(data: try JSONEncoder().encode(site), encoding: .utf8)!
        XCTAssertTrue(encoded.contains("repositoryURL"))
        XCTAssertFalse(encoded.contains("\"repo\""))
    }

    func testLoadAutoRelocatesStalePathAndPersists() throws {
        // A checkout that matches the configured repo lives under a temp root.
        let scanRoot = root.appendingPathComponent("scan", isDirectory: true)
        let checkout = scanRoot.appendingPathComponent("vibeforge/atvtool", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try makeGitConfig(at: checkout, origin: "git@github.com:vibeforge2014/atvtool.git")
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent("ATVTool.xcodeproj"), withIntermediateDirectories: true)

        // Seed a catalog whose path is stale (the checkout "moved").
        let staleApp = AppProject(id: "tivon", name: "Tivon", path: "/old/removed",
                                  repositoryURL: "git@github.com:vibeforge2014/atvtool.git",
                                  platform: .ios, scheme: "ATVTool", bundleId: "com.atvtool.ios",
                                  versionSource: .projectYml,
                                  release: ReleaseConfig(engine: .native, signing: .manual))
        try encode(ProjectCatalogData(apps: [staleApp], sites: []), to: bundledURL)

        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [scanRoot.path])

        XCTAssertEqual(catalog.app(id: "tivon")?.resolvedPath, resolved(checkout.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userURL.path))

        // A fresh load retains the discovered path (it now exists, so it's left alone).
        let reloaded = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [scanRoot.path])
        XCTAssertEqual(reloaded.app(id: "tivon")?.resolvedPath, resolved(checkout.path))
    }

    func testRescanPathsRelocatesAfterMoveAndReportsCount() throws {
        let scanRoot = root.appendingPathComponent("scan", isDirectory: true)
        let checkout = scanRoot.appendingPathComponent("vibeforge/atvtool", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try makeGitConfig(at: checkout, origin: "git@github.com:vibeforge2014/atvtool.git")
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent("ATVTool.xcodeproj"), withIntermediateDirectories: true)

        let staleApp = AppProject(id: "tivon", name: "Tivon", path: "",
                                  repositoryURL: "git@github.com:vibeforge2014/atvtool.git",
                                  platform: .ios, scheme: "ATVTool", bundleId: "com.atvtool.ios",
                                  versionSource: .projectYml,
                                  release: ReleaseConfig(engine: .native, signing: .manual))
        try encode(ProjectCatalogData(apps: [staleApp], sites: []), to: bundledURL)

        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL, relocationRoots: [scanRoot.path])
        // Load auto-relocates the stale path…
        XCTAssertEqual(catalog.app(id: "tivon")?.resolvedPath, resolved(checkout.path))
        XCTAssertNil(catalog.rescanNotice)

        // …then the checkout is moved. rescanPaths() must rediscover it.
        let moved = scanRoot.appendingPathComponent("vibeforge/atvtool-renamed", isDirectory: true)
        try FileManager.default.moveItem(at: checkout, to: moved)
        catalog.rescanPaths()

        XCTAssertEqual(catalog.app(id: "tivon")?.resolvedPath, resolved(moved.path))
        XCTAssertEqual(catalog.rescanNotice, "已重新定位 1 个项目路径")
    }

    private func makeGitConfig(at checkout: URL, origin: String) throws {
        let gitDir = checkout.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = \(origin)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    private func makeApp(id: String = "fixture", path: String = "/tmp/missing") -> AppProject {
        AppProject(id: id, name: "Fixture", path: path,
                   repositoryURL: "https://github.com/example/fixture.git",
                   platform: .ios, scheme: "Fixture", bundleId: "example.fixture",
                   versionSource: .projectYml,
                   release: ReleaseConfig(engine: .native, signing: .manual))
    }

    private func makeSite() -> SiteProject {
        SiteProject(id: "fixture-site", name: "Fixture Site", path: "/tmp/missing",
                    repositoryURL: "git@github.com:example/site.git", deploy: .gitPushMain)
    }

    private func encode(_ value: ProjectCatalogData, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url)
    }

    /// Compares paths symlink-blind: macOS temp dirs live under `/var`, a
    /// symlink to `/private/var`, so canonical locator output and the test's
    /// constructed path differ in spelling only. `URL.resolvingSymlinksInPath`
    /// does not resolve `/var`, so use realpath.
    private func resolved(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return path }
        return String(cString: buf)
    }
}

@MainActor
final class GitRemoteServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRemoteServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testOriginMissingAddAndUpdate() async throws {
        try runGit(["init", root.path])
        let service = GitRemoteService()
        let initialState = await service.originState(at: root.path)
        XCTAssertEqual(initialState, .missing)

        let runner = ShellRunner()
        let first = await service.setOrigin("https://github.com/example/one.git", state: .missing,
                                            at: root.path, runner: runner)
        XCTAssertTrue(first.succeeded)
        let addedState = await service.originState(at: root.path)
        XCTAssertEqual(addedState, .configured("https://github.com/example/one.git"))

        let second = await service.setOrigin("git@github.com:example/two.git",
                                             state: .configured("https://github.com/example/one.git"),
                                             at: root.path, runner: runner)
        XCTAssertTrue(second.succeeded)
        let updatedState = await service.originState(at: root.path)
        XCTAssertEqual(updatedState, .configured("git@github.com:example/two.git"))
    }

    func testNonRepositoryAndFailedUpdate() async {
        let service = GitRemoteService()
        let state = await service.originState(at: root.path)
        XCTAssertEqual(state, .notRepository)
        let result = await service.setOrigin("https://github.com/example/repo.git", state: .missing,
                                             at: root.path, runner: ShellRunner())
        XCTAssertFalse(result.succeeded)
    }

    private func runGit(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
