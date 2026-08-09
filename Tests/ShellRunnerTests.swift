import XCTest

@MainActor
final class ShellRunnerTests: XCTestCase {
    func testSequentialCommandsKeepCompleteLog() async {
        let runner = ShellRunner()
        _ = await runner.run(executable: "/bin/echo", args: ["first"])
        _ = await runner.run(executable: "/bin/echo", args: ["second"])
        await Task.yield()

        let text = runner.lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
    }

    func testTerminateCancelsCurrentProcess() async {
        let runner = ShellRunner()
        let started = Date()
        let task = Task { await runner.run(executable: "/bin/sleep", args: ["10"]) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        runner.terminate()
        let result = await task.value

        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
