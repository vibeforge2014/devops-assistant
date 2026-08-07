import Foundation
import SwiftUI

/// One line of captured process output, tagged by stream so the console can
/// render stderr distinctly.
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let stream: Stream

    enum Stream { case stdout, stderr, meta }

    var isMeta: Bool { stream == .meta }
}

/// The result of a finished process.
struct RunResult {
    let exitCode: Int32
    let cancelled: Bool

    var succeeded: Bool { exitCode == 0 && !cancelled }
}

/// Runs a shell command as a child `Process`, streaming stdout/stderr line by
/// line to an observable log. Designed to wrap fastlane / xcodebuild / git —
/// long-running, output-heavy commands the user wants to watch live.
///
/// Output is captured asynchronously via `Pipe` + a dedicated read source per
/// stream, decoded UTF-8, split on newlines, and appended on the main actor so
/// SwiftUI can render it incrementally. Commands are cancellable via
/// `terminate()`.
@MainActor
final class ShellRunner: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var isRunning = false

    private var process: Process?
    private var didCancel = false

    /// Append a meta line (not from the process) — e.g. a step header.
    func log(_ text: String) {
        lines.append(LogLine(text: text, stream: .meta))
    }

    func clear() {
        lines.removeAll()
    }

    /// Run a command, streaming output. Returns the exit code. `env` is merged
    /// onto the current environment so credentials can be injected per-run.
    @discardableResult
    func run(_ command: String,
             cwd: String? = nil,
             env: [String: String] = [:]) async -> RunResult {
        clear()
        isRunning = true
        didCancel = false
        defer { isRunning = false }

        let proc = Process()
        proc.launchPath = "/bin/zsh"
        // -c so we get shell features (PATH resolution, && chains, globs).
        proc.arguments = ["-l", "-c", command]

        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var mergedEnv = ProcessInfo.processInfo.environment
        mergedEnv.merge(env) { _, new in new }
        proc.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Stream stdout/stderr concurrently, buffering partial lines.
        let stdoutTask = streamTask(pipe: outPipe, stream: .stdout)
        let stderrTask = streamTask(pipe: errPipe, stream: .stderr)

        do {
            try proc.run()
        } catch {
            lines.append(LogLine(text: "启动失败: \(error.localizedDescription)", stream: .meta))
            return RunResult(exitCode: -1, cancelled: false)
        }

        process = proc

        // Wait in the background so the main actor stays responsive; the pipe
        // read sources keep appending lines until EOF.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await stdoutTask.value }
            group.addTask { await stderrTask.value }
            group.addTask {
                proc.waitUntilExit()
            }
            // All three complete; waitUntilExit returns after EOFs drain.
        }

        let code = proc.terminationStatus
        return RunResult(exitCode: code, cancelled: didCancel)
    }

    /// Cancel the running process, if any.
    func terminate() {
        didCancel = true
        process?.terminate()
    }

    /// Read a pipe to EOF on a background thread, forwarding complete lines to
    /// the main actor. Lines are split manually because `Pipe` delivers chunks
    /// that don't respect newlines.
    private func streamTask(pipe: Pipe, stream: LogLine.Stream) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            var buffer = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break } // EOF
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: nl)
                    buffer = buffer.advanced(by: lineData.count + 1)
                    if let text = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .carriageReturns) {
                        await self?.appendLine(text, stream: stream)
                    }
                }
            }
            // Flush any trailing partial line.
            if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
                await self?.appendLine(text, stream: stream)
            }
        }
    }

    @MainActor
    private func appendLine(_ text: String, stream: LogLine.Stream) {
        lines.append(LogLine(text: text, stream: stream))
    }
}

private extension Data {
    func index(after i: Data.Index) -> Data.Index { Swift.min(i + 1, count) }
}

private extension CharacterSet {
    static var carriageReturns: CharacterSet { CharacterSet(charactersIn: "\r") }
}
