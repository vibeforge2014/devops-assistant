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
/// Concurrency: `run` is `@MainActor` but never blocks the main thread — it
/// awaits process completion via `terminationHandler` + a continuation, so the
/// UI stays live while a long command streams. Output arrives via
/// `readabilityHandler` so it's delivered as produced, not batched at exit.
/// Commands are cancellable via `terminate()`.
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

    /// Run a command through the shell, streaming output. `env` is merged onto
    /// the current environment so credentials can be injected per-run. `timeout`
    /// seconds, when > 0, force-terminates the process and returns a cancelled
    /// result (M2).
    @discardableResult
    func run(_ command: String,
             cwd: String? = nil,
             env: [String: String] = [:],
             timeout: TimeInterval = 0) async -> RunResult {
        await runProcess(executableURL: URL(fileURLWithPath: "/bin/zsh"),
                         arguments: ["-l", "-c", command],
                         cwd: cwd, env: env, timeout: timeout)
    }

    /// Run a command with an argv array directly (no shell interpretation).
    /// Prefer this for anything embedding user-provided strings — it has no
    /// shell-injection surface (§ M4).
    @discardableResult
    func run(executable: String,
             args: [String],
             cwd: String? = nil,
             env: [String: String] = [:],
             timeout: TimeInterval = 0) async -> RunResult {
        await runProcess(executableURL: URL(fileURLWithPath: executable),
                         arguments: args,
                         cwd: cwd, env: env, timeout: timeout)
    }

    // MARK: - Core

    private func runProcess(executableURL: URL,
                            arguments: [String],
                            cwd: String?,
                            env: [String: String],
                            timeout: TimeInterval) async -> RunResult {
        clear()
        isRunning = true
        didCancel = false
        defer { isRunning = false }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var mergedEnv = ProcessInfo.processInfo.environment
        mergedEnv.merge(env) { _, new in new }
        proc.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Buffer a partial line per pipe; flush on cursor/end.
        let outBuf = LineBuffer { [weak self] line in
            Task { @MainActor in self?.lines.append(LogLine(text: line, stream: .stdout)) }
        }
        let errBuf = LineBuffer { [weak self] line in
            Task { @MainActor in self?.lines.append(LogLine(text: line, stream: .stderr)) }
        }

        // Stream via readabilityHandler (fires as data lands, not only at EOF).
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outBuf.flush()
            } else {
                outBuf.append(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errBuf.flush()
            } else {
                errBuf.append(data)
            }
        }

        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            lines.append(LogLine(text: "启动失败: \(error.localizedDescription)", stream: .meta))
            return RunResult(exitCode: -1, cancelled: false)
        }

        process = proc

        // Await completion without blocking the main thread. terminationHandler
        // fires on a background queue; we bridge it with a continuation. An
        // optional timeout (M2) terminates the process and resumes the
        // continuation, so a hung command can't freeze the UI forever.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resumeOnce: () -> Void = {
                if !resumed {
                    resumed = true
                    cont.resume()
                }
            }
            proc.terminationHandler = { _ in resumeOnce() }
            if timeout > 0 {
                // Deadline timer; if it fires, kill the process and resume.
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if proc.isRunning {
                        didCancel = true
                        lines.append(LogLine(text: "⏱ 超时 \(Int(timeout))s — 终止进程", stream: .meta))
                        proc.terminate()
                        resumeOnce()
                    }
                }
            }
        }

        // Process exited: close the read handles so readabilityHandler sees EOF
        // even if a descendant kept the fd momentarily alive.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        outBuf.flush()
        errBuf.flush()

        process = nil
        return RunResult(exitCode: proc.terminationStatus, cancelled: didCancel)
    }

    /// Cancel the running process, if any.
    func terminate() {
        didCancel = true
        process?.terminate()
    }
}

/// Accumulates raw pipe data into whole lines, invoking `onLine` per line and
/// `onLine` once more for a trailing partial line on flush.
private final class LineBuffer {
    private var buffer = Data()
    private let callback: (String) -> Void

    init(_ callback: @escaping (String) -> Void) {
        self.callback = callback
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        drain()
    }

    func flush() {
        if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
            callback(text.trimmingCharacters(in: .newlines))
            buffer.removeAll()
        }
    }

    private func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer = buffer.advanced(by: lineData.count + 1)
            if let text = String(data: lineData, encoding: .utf8) {
                callback(text.trimmingCharacters(in: .newlines))
            }
        }
    }
}

@MainActor
private extension ShellRunner {
    static func appendLine(_ text: String, stream: LogLine.Stream) {
        // Helper for readability-handler callbacks (kept for symmetry).
    }
}
