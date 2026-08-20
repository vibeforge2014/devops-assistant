import XCTest

@MainActor
final class ShellRunnerTests: XCTestCase {
    func testDeveloperToolPathPrecedesSystemToolsAndRemovesDuplicates() {
        let path = DeveloperToolPath.resolved(
            inheritedPath: "/usr/bin:/bin:/opt/homebrew/bin",
            homeDirectory: "/Users/test",
            pathExists: { _ in true }
        )

        XCTAssertEqual(path, [
            "/Users/test/.local/share/mise/shims",
            "/Users/test/.asdf/shims",
            "/Users/test/.rbenv/shims",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":"))
    }

    func testSequentialCommandsKeepCompleteLog() async {
        let runner = ShellRunner()
        _ = await runner.run(executable: "/bin/echo", args: ["first"])
        _ = await runner.run(executable: "/bin/echo", args: ["second"])

        // Line delivery hops through unstructured Tasks onto the main actor;
        // a single yield isn't guaranteed to drain them under load — poll
        // briefly for the expected content instead.
        let text = await awaitingConsoleText(runner, containing: ["first", "second"])
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
    }

    private func awaitingConsoleText(_ runner: ShellRunner, containing needles: [String],
                                      timeout: TimeInterval = 2) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = runner.lines.map(\.text).joined(separator: "\n")
            if needles.allSatisfy(text.contains) { return text }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return runner.lines.map(\.text).joined(separator: "\n")
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
