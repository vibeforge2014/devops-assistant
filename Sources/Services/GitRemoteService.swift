import Foundation

enum GitOriginState: Equatable {
    case notRepository
    case missing
    case configured(String)
}

/// Reads and updates a local checkout's origin without shell interpolation.
struct GitRemoteService {
    private let git = "/usr/bin/git"

    func originState(at path: String) async -> GitOriginState {
        await Task.detached {
            let root = NSString(string: path).expandingTildeInPath
            guard Self.capture(git: git, args: ["-C", root, "rev-parse", "--is-inside-work-tree"])?.output
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return .notRepository
            }
            guard let result = Self.capture(git: git,
                                            args: ["-C", root, "remote", "get-url", "origin"]),
                  result.status == 0 else { return .missing }
            let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? .missing : .configured(url)
        }.value
    }

    @MainActor
    func setOrigin(_ url: String, state: GitOriginState, at path: String,
                   runner: ShellRunner) async -> RunResult {
        let action = state == .missing ? "add" : "set-url"
        runner.log("▶ git remote \(action) origin")
        return await runner.run(executable: git,
                                args: ["-C", NSString(string: path).expandingTildeInPath,
                                       "remote", action, "origin", url])
    }

    private static func capture(git: String, args: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
