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
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL)
        XCTAssertEqual(catalog.apps.map(\.id), ["fixture"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: userURL.path))

        try catalog.addSite(SiteProject(id: "new-site", name: "New", path: "/missing",
                                        repositoryURL: "https://github.com/example/new-site.git",
                                        deploy: .gitPushMain))
        let reloaded = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL)
        XCTAssertEqual(reloaded.sites.map(\.id), ["fixture-site", "new-site"])
    }

    func testCRUDPersistsAndDeleteDoesNotTouchProjectDirectory() throws {
        let projectDirectory = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL)
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
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL)

        XCTAssertEqual(catalog.apps.map(\.id), ["fixture"])
        XCTAssertNotNil(catalog.errorMessage)
        XCTAssertEqual(try Data(contentsOf: userURL), corrupt)
    }

    func testPersistenceFailureDoesNotPublishMutation() throws {
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockingFile)
        let impossibleURL = blockingFile.appendingPathComponent("projects.json")
        let catalog = ProjectCatalog(fileURL: impossibleURL, bundledURL: bundledURL)
        let before = catalog.apps

        XCTAssertThrowsError(try catalog.addApp(makeApp(id: "second")))
        XCTAssertEqual(catalog.apps, before)
    }

    func testValidationRejectsInvalidAndDuplicateIDsAndURLs() throws {
        let catalog = ProjectCatalog(fileURL: userURL, bundledURL: bundledURL)
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
