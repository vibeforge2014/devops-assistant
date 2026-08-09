import XCTest

@MainActor
final class PortalSyncTests: XCTestCase {
    func testUpdatesExistingProductVersionWithoutDuplicatingField() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortalSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("src/data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let products = """
        export const products = [
          {
            id: "fixture",
            version: "1.0.0 (1)",
            name: "Fixture",
          },
        ]
        """
        let url = dataDir.appendingPathComponent("products.ts")
        try products.write(to: url, atomically: true, encoding: .utf8)
        let site = SiteProject(id: "portal", name: "Portal", path: root.path,
                               repositoryURL: "https://github.com/example/portal.git",
                               deploy: .ghPages)

        let result = await PortalSync(runner: ShellRunner()).updateVersion(
            productID: "fixture",
            version: VersionPair(marketing: "2.0.0", build: "7"),
            portal: site
        )

        XCTAssertTrue(result)
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"version: "2.0.0 (7)""#))
        XCTAssertEqual(updated.components(separatedBy: "version:").count - 1, 1)
    }
}
