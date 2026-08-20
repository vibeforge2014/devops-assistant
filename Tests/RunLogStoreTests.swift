import Foundation
import XCTest

final class RunLogStoreTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunLogStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testMakeSinkCreatesFileUnderAppDirectoryWithTargetInName() throws {
        var sink: FileLogSink? = RunLogStore.makeSink(
            appID: "tivon", target: "testFlight", baseDirectory: base)
        XCTAssertNotNil(sink)
        let url = try XCTUnwrap(sink).url
        XCTAssertTrue(url.path.hasPrefix(base.appendingPathComponent("tivon").path + "/"))
        XCTAssertTrue(url.lastPathComponent.contains("testFlight"))
        XCTAssertTrue(url.pathExtension == "log")

        sink?.append("first line")
        sink?.append("second line")
        sink = nil // deinit flushes
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "first line\nsecond line\n")
    }

    func testConsecutiveSinksDoNotCollide() throws {
        let sink1 = RunLogStore.makeSink(appID: "tivon", target: "appStore",
                                         date: Date(), baseDirectory: base)
        let sink2 = RunLogStore.makeSink(appID: "tivon", target: "appStore",
                                         date: Date(), baseDirectory: base)
        XCTAssertNotEqual(try XCTUnwrap(sink1).url, try XCTUnwrap(sink2).url)
    }

    func testAppendModeContinuesExistingFile() throws {
        // Simulate a retry: first attempt writes, second appends.
        var first: FileLogSink? = RunLogStore.makeSink(
            appID: "tivon", target: "appStore", baseDirectory: base)
        let url = try XCTUnwrap(first).url
        first?.append("attempt-1: boom")
        first = nil

        var retry: FileLogSink? = FileLogSink(url: url, append: true)
        XCTAssertNotNil(retry)
        retry?.append("attempt-2: ok")
        retry = nil

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "attempt-1: boom\nattempt-2: ok\n")
    }

    func testRetentionDeletesOldestFilesFirst() throws {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("tivon", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let names = ["old.log", "mid.log", "new.log"]
        let dates = [Date(timeIntervalSinceNow: -3000),
                     Date(timeIntervalSinceNow: -2000),
                     Date(timeIntervalSinceNow: -1000)]
        for (name, date) in zip(names, dates) {
            let url = dir.appendingPathComponent(name)
            try Data(repeating: 0x41, count: 10).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        // 30 bytes total, limit 15 → old.log and mid.log are removed.
        RunLogStore.enforceRetention(limit: 15, in: base)

        let remaining = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining, ["new.log"])
    }

    func testRetentionKeepsEverythingUnderLimit() throws {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("tivon", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: dir.appendingPathComponent("a.log"))

        RunLogStore.enforceRetention(limit: 100, in: base)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).count, 1)
    }
}
