import XCTest

final class VersionManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevOpsAssistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsAndWritesQuotedProjectYml() throws {
        let yml = """
        settings:
          base:
            MARKETING_VERSION: "1.2.3" # release
            CURRENT_PROJECT_VERSION: "41"
        """
        try yml.write(to: root.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)
        let app = makeApp(source: .projectYml)

        XCTAssertEqual(VersionManager.read(app), VersionPair(marketing: "1.2.3", build: "41"))
        XCTAssertTrue(VersionManager.write(VersionPair(marketing: "2.0.0", build: "42"), to: app))
        XCTAssertEqual(VersionManager.read(app), VersionPair(marketing: "2.0.0", build: "42"))

        let updated = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(updated.contains(#"MARKETING_VERSION: "2.0.0" # release"#))
        XCTAssertTrue(updated.contains(#"CURRENT_PROJECT_VERSION: "42""#))
    }

    func testReadsAndBumpsUnquotedProjectYml() throws {
        let yml = """
        MARKETING_VERSION: 0.9.0
        CURRENT_PROJECT_VERSION: 9
        """
        try yml.write(to: root.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)
        let app = makeApp(source: .projectYml)

        XCTAssertEqual(VersionManager.bumpBuild(app), VersionPair(marketing: "0.9.0", build: "10"))
        XCTAssertEqual(VersionManager.read(app)?.build, "10")
    }

    func testReadsAndWritesPbxproj() throws {
        let project = root.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pbx = """
        buildSettings = {
            MARKETING_VERSION = "3.4.5";
            CURRENT_PROJECT_VERSION = 17;
        };
        """
        try pbx.write(to: project.appendingPathComponent("project.pbxproj"),
                      atomically: true, encoding: .utf8)
        let app = makeApp(source: .pbxproj)

        XCTAssertEqual(VersionManager.read(app), VersionPair(marketing: "3.4.5", build: "17"))
        XCTAssertTrue(VersionManager.write(VersionPair(marketing: "3.5.0", build: "18"), to: app))
        XCTAssertEqual(VersionManager.read(app), VersionPair(marketing: "3.5.0", build: "18"))
    }

    func testInvalidBuildDoesNotWrite() throws {
        let yml = "MARKETING_VERSION: 1.0.0\nCURRENT_PROJECT_VERSION: abc\n"
        let url = root.appendingPathComponent("project.yml")
        try yml.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(VersionManager.bumpBuild(makeApp(source: .projectYml)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yml)
    }

    // MARK: - Write verification

    func testWriteFailsWhenProjectYmlHasNoVersionKeys() throws {
        // The release pipeline's setVersion step treats write() == true as
        // "version on disk is now X" — a no-op regex pass must return false,
        // or the app ships with the OLD version believing it was bumped.
        let yml = "name: Fixture\noptions:\n  bundleIdPrefix: com.example\n"
        let url = root.appendingPathComponent("project.yml")
        try yml.write(to: url, atomically: true, encoding: .utf8)
        let app = makeApp(source: .projectYml)

        XCTAssertFalse(VersionManager.write(VersionPair(marketing: "2.0.0", build: "5"), to: app))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yml)
    }

    func testWriteFailsWhenProjectYmlHasOnlyOneVersionKey() throws {
        let yml = "MARKETING_VERSION: 1.0.0\n"
        let url = root.appendingPathComponent("project.yml")
        try yml.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertFalse(VersionManager.write(VersionPair(marketing: "2.0.0", build: "5"),
                                            to: makeApp(source: .projectYml)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yml)
    }

    func testWriteFailsWhenPbxprojHasNoVersionKeys() throws {
        let project = root.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pbx = "buildSettings = {\n    SWIFT_VERSION = 5.0;\n};\n"
        let url = project.appendingPathComponent("project.pbxproj")
        try pbx.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertFalse(VersionManager.write(VersionPair(marketing: "2.0.0", build: "5"),
                                            to: makeApp(source: .pbxproj)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), pbx)
    }

    private func makeApp(source: VersionSource) -> AppProject {
        AppProject(id: "fixture", name: "Fixture", path: root.path,
                   repositoryURL: "https://github.com/example/fixture.git",
                   platform: .ios, scheme: "Fixture", bundleId: "test.fixture",
                   versionSource: source,
                   release: ReleaseConfig(engine: .native, signing: .manual))
    }
}
