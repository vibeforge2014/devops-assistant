import Foundation
import XCTest

/// Update-feed parsing against the live `releases/latest` shape captured
/// 2026-08-20 (tag v1.2.1, one DMG + one checksum asset), plus the
/// numeric-aware version comparison the "newer?" decision relies on.
final class AppUpdateParsingTests: XCTestCase {
    private func parse(_ json: String) throws -> AppUpdateInfo {
        try AppUpdateInfo.parse(Data(json.utf8))
    }

    func testParsesLatestReleaseAndPicksDMGAsset() throws {
        let json = """
        {
          "tag_name": "v1.2.1",
          "name": "DevOps Assistant 1.2.1",
          "body": "### 修复\\n- 凭据校验 PATH\\n- 发布工具链",
          "html_url": "https://github.com/vibeforge2014/devops-assistant/releases/tag/v1.2.1",
          "published_at": "2026-08-13T13:37:42Z",
          "prerelease": false,
          "assets": [
            {"name": "DevOps-Assistant-1.2.1.dmg", "size": 1525672,
             "browser_download_url": "https://github.com/vibeforge2014/devops-assistant/releases/download/v1.2.1/DevOps-Assistant-1.2.1.dmg"},
            {"name": "SHA256.txt", "size": 200,
             "browser_download_url": "https://github.com/vibeforge2014/devops-assistant/releases/download/v1.2.1/SHA256.txt"}
          ]
        }
        """
        let info = try parse(json)
        XCTAssertEqual(info.tagName, "v1.2.1")
        XCTAssertEqual(info.version, "1.2.1")
        XCTAssertEqual(info.title, "DevOps Assistant 1.2.1")
        XCTAssertEqual(info.notes, "### 修复\n- 凭据校验 PATH\n- 发布工具链")
        XCTAssertEqual(info.assetName, "DevOps-Assistant-1.2.1.dmg")
        XCTAssertEqual(info.assetSize, 1_525_672)
        XCTAssertEqual(info.downloadURL.absoluteString,
                       "https://github.com/vibeforge2014/devops-assistant/releases/download/v1.2.1/DevOps-Assistant-1.2.1.dmg")
        XCTAssertEqual(info.htmlURL?.absoluteString,
                       "https://github.com/vibeforge2014/devops-assistant/releases/tag/v1.2.1")

        let date = try XCTUnwrap(info.publishedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: date),
                       DateComponents(year: 2026, month: 8, day: 13))

        XCTAssertTrue(info.isNewer(than: "1.2.0"))
        XCTAssertFalse(info.isNewer(than: "1.4.0"))
    }

    func testPrefersDMGWhoseNameCarriesReleaseVersion() throws {
        let json = """
        {
          "tag_name": "v1.2.1",
          "assets": [
            {"name": "DevOps-Assistant-1.0.9.dmg", "size": 10,
             "browser_download_url": "https://example.com/old.dmg"},
            {"name": "DevOps-Assistant-1.2.1.dmg", "size": 20,
             "browser_download_url": "https://example.com/new.dmg"}
          ]
        }
        """
        let info = try parse(json)
        XCTAssertEqual(info.assetName, "DevOps-Assistant-1.2.1.dmg")
        XCTAssertEqual(info.assetSize, 20)
    }

    func testThrowsWhenReleaseHasNoDMGAsset() {
        let json = """
        {"tag_name": "v3.0.0", "assets": [{"name": "notes.txt", "size": 1,
          "browser_download_url": "https://example.com/n.txt"}]}
        """
        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual(error as? AppUpdateError, .noDMGAsset("v3.0.0"))
        }
    }

    func testTagWithoutVPrefixStillYieldsVersion() throws {
        let info = try parse(#"{"tag_name": "2.0.0", "assets": [{"name": "x.dmg", "size": 1, "browser_download_url": "https://e.com/x.dmg"}]}"#)
        XCTAssertEqual(info.version, "2.0.0")
    }

    func testGarbageJSONThrowsMalformedResponse() {
        XCTAssertThrowsError(try parse("not json")) { error in
            XCTAssertEqual(error as? AppUpdateError, .malformedResponse)
        }
    }
}

final class AppVersionComparisonTests: XCTestCase {
    func testNumericNotLexical() {
        // String comparison would call "1.10.0" < "1.9.2".
        XCTAssertTrue(AppVersion.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertFalse(AppVersion.isNewer("1.9.2", than: "1.10.0"))
    }

    func testEqualAndOlder() {
        XCTAssertEqual(AppVersion.compare("1.2.1", "1.2.1"), .orderedSame)
        XCTAssertFalse(AppVersion.isNewer("1.2.0", than: "1.2.1"))
        XCTAssertFalse(AppVersion.isNewer("1.2.1", than: "1.2.1"))
    }

    func testMissingComponentReadsAsZero() {
        XCTAssertEqual(AppVersion.compare("1.2.0", "1.2"), .orderedSame)
        XCTAssertTrue(AppVersion.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(AppVersion.isNewer("1.2", than: "1.2.0"))
    }

    func testPreReleaseSuffixSortsBelowItsRelease() {
        XCTAssertFalse(AppVersion.isNewer("1.3.0-beta", than: "1.3.0"))
        XCTAssertTrue(AppVersion.isNewer("1.3.0", than: "1.3.0-beta"))
        XCTAssertTrue(AppVersion.isNewer("1.3.1", than: "1.3.0-beta"))
    }

    func testMajorBumpBeatsMinorComponentwise() {
        XCTAssertTrue(AppVersion.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(AppVersion.isNewer("0.9.9", than: "1.0.0"))
    }
}
