import Foundation
import XCTest

/// ReleaseRecord must keep decoding history.json files written before the
/// `logPath` field existed (v1.2.1 and earlier) — a failed decode would wipe
/// the whole list on upgrade.
final class ReleaseRecordTests: XCTestCase {
    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testDecodesLegacyJSONWithoutLogPath() throws {
        // Shape written by HistoryStore v1.1/v1.2 (no logPath key).
        let legacy = """
        [{
          "appID": "tivon",
          "appName": "Tivon",
          "build": "8",
          "failureStep": "签名",
          "id": "\(UUID().uuidString)",
          "marketing": "1.2.3",
          "platform": "ios",
          "success": false,
          "target": "testFlight",
          "timestamp": "2026-08-10T10:00:00Z"
        }]
        """
        let records = try makeDecoder().decode([ReleaseRecord].self,
                                               from: Data(legacy.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].logPath)
        XCTAssertEqual(records[0].failureStep, "签名")
        XCTAssertFalse(records[0].logFileExists)
    }

    func testRoundTripsWithLogPath() throws {
        // Whole-second timestamp: ISO8601 drops sub-second precision, which
        // would make the roundtrip Date != original and the == check fail
        // for reasons unrelated to what's under test.
        let record = ReleaseRecord(
            appName: "Tivon", appID: "tivon", platform: .ios, target: .testFlight,
            version: VersionPair(marketing: "2.0.0", build: "12"),
            success: true, failureStep: nil,
            logPath: "/tmp/logs/tivon/20260815-100000-testFlight.log",
            timestamp: Date(timeIntervalSince1970: 1_770_000_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record])

        let decoded = try makeDecoder().decode([ReleaseRecord].self, from: data)
        XCTAssertEqual(decoded, [record])
        XCTAssertEqual(decoded[0].logPath, record.logPath)
    }

    func testLogPathDecodeDefaultsNilWhenNull() throws {
        let json = """
        [{
          "appID": "a", "appName": "A", "build": "1", "failureStep": null,
          "id": "\(UUID().uuidString)", "marketing": "1.0.0", "platform": "macos",
          "success": true, "target": "macDistribution",
          "timestamp": "2026-08-10T10:00:00Z", "logPath": null
        }]
        """
        let records = try makeDecoder().decode([ReleaseRecord].self, from: Data(json.utf8))
        XCTAssertNil(records[0].logPath)
    }
}
