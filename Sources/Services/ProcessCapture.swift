import Foundation

/// One-shot argv process capture for plumbing calls whose OUTPUT matters
/// (`git rev-parse`, `gh run list`) rather than whose streaming the user
/// wants to watch — that's `ShellRunner`'s job. Nothing lands in the console;
/// the blocking `readDataToEndOfFile` runs on a detached task so a slow call
/// never stalls the main actor.
enum ProcessCapture {
    /// nil when the process couldn't launch at all (missing directory,
    /// unloaded executable); a non-zero `exitCode` is still a result.
    static func capture(executable: String,
                        args: [String],
                        cwd: String? = nil,
                        env: [String: String] = [:]) async -> (exitCode: Int32, output: String)? {
        let work: () -> (Int32, String)? = {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var merged = ProcessInfo.processInfo.environment
            if env["PATH"] == nil {
                merged["PATH"] = DeveloperToolPath.resolved(inheritedPath: merged["PATH"])
            }
            merged.merge(env) { _, new in new }
            process.environment = merged
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }
}
