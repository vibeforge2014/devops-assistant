import Darwin
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

/// GUI apps inherit a very small PATH from launchd, which normally omits
/// Homebrew and Ruby version-manager shims. Keep command resolution consistent
/// with a developer terminal without running user shell startup scripts.
enum DeveloperToolPath {
    static func resolved(inheritedPath: String?,
                         homeDirectory: String = NSHomeDirectory(),
                         pathExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String {
        let preferred = [
            "\(homeDirectory)/.local/share/mise/shims",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.rbenv/shims",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
        ].filter(pathExists)

        let inherited = (inheritedPath ?? "")
            .split(separator: ":")
            .map(String.init)

        var seen = Set<String>()
        return (preferred + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
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
    /// Cancellable deadline for the current command; cancelled the moment
    /// the process exits so a 3600s timeout can't pin the runner (and its
    /// log sink) in memory long after a quick successful run.
    private var timeoutTask: Task<Void, Never>?
    /// One-shot SIGKILL escalation for a process that ignores SIGTERM.
    private var killEscalationTask: Task<Void, Never>?

    /// Optional mirror for every captured line (release runs tee their
    /// output to a file on disk). Owned by whoever cares about persistence —
    /// the runner itself only forwards.
    var logSink: LogSink?

    /// Append a meta line (not from the process) — e.g. a step header.
    func log(_ text: String) {
        record(LogLine(text: text, stream: .meta))
    }

    func clear() {
        lines.removeAll()
    }

    /// Single funnel for every line entering the console, so the sink always
    /// sees exactly what the on-screen console sees.
    private func record(_ line: LogLine) {
        lines.append(line)
        logSink?.append(line.text)
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
        isRunning = true
        didCancel = false
        defer { isRunning = false }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var mergedEnv = ProcessInfo.processInfo.environment
        // Commands launched with an argv array do not pass through a login
        // shell, so a GUI-launched app would otherwise resolve /usr/bin/bundle
        // (system Ruby 2.6) instead of the project's installed Bundler.
        if env["PATH"] == nil {
            mergedEnv["PATH"] = DeveloperToolPath.resolved(inheritedPath: mergedEnv["PATH"])
        }
        mergedEnv.merge(env) { _, new in new }
        proc.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Buffer a partial line per pipe; flush on cursor/end.
        let outBuf = LineBuffer { [weak self] line in
            Task { @MainActor in self?.record(LogLine(text: line, stream: .stdout)) }
        }
        let errBuf = LineBuffer { [weak self] line in
            Task { @MainActor in self?.record(LogLine(text: line, stream: .stderr)) }
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
            record(LogLine(text: "启动失败: \(error.localizedDescription)", stream: .meta))
            return RunResult(exitCode: -1, cancelled: false)
        }

        process = proc

        // Await completion without blocking the main thread. terminationHandler
        // fires on a background queue; we bridge it with a continuation. An
        // optional timeout terminates the process and resumes the
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
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled, proc.isRunning else { return }
                    self?.didCancel = true
                    self?.record(LogLine(text: "⏱ 超时 \(Int(timeout))s — 终止进程", stream: .meta))
                    self?.terminateProcess(proc)
                }
            }
        }

        // Process exited: stand down the deadline and the kill escalation,
        // and close the read handles so readabilityHandler sees EOF even if a
        // descendant kept the fd momentarily alive.
        timeoutTask?.cancel()
        timeoutTask = nil
        killEscalationTask?.cancel()
        killEscalationTask = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        outBuf.flush()
        errBuf.flush()

        process = nil
        return RunResult(exitCode: proc.terminationStatus, cancelled: didCancel)
    }

    /// Cancel the running process, if any. SIGTERM first; a process that
    /// traps or ignores it gets a SIGKILL escalation — without that, the
    /// await would hang forever with isRunning stuck true.
    func terminate() {
        didCancel = true
        if let proc = process {
            terminateProcess(proc)
        }
    }

    private func terminateProcess(_ proc: Process) {
        proc.terminate()
        guard killEscalationTask == nil else { return }
        killEscalationTask = Task { [weak proc, weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let proc, proc.isRunning else { return }
            self?.record(LogLine(text: "⚠ 进程未响应终止信号,已强制结束", stream: .meta))
            kill(proc.processIdentifier, SIGKILL)
        }
    }
}

/// Accumulates raw pipe data into whole lines, invoking `onLine` per line and
/// `onLine` once more for a trailing partial line on flush. Locked because
/// the readabilityHandler (a background thread) and the post-exit flush on
/// the main actor can briefly overlap.
private final class LineBuffer {
    private var buffer = Data()
    private let lock = NSLock()
    private let callback: (String) -> Void

    init(_ callback: @escaping (String) -> Void) {
        self.callback = callback
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        drain()
        lock.unlock()
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else { return }
        callback(text.trimmingCharacters(in: .newlines))
        buffer.removeAll()
    }

    /// Caller must hold the lock.
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
