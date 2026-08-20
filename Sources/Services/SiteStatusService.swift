import Foundation

/// Read-only snapshot of a site clone's git state — what the detail page's
/// status card shows and what the publish flow uses to decide whether there
/// is anything to ship.
struct SiteStatus: Equatable {
    struct Commit: Equatable {
        let shortHash: String
        let subject: String
        let date: Date
    }

    /// nil when detached or the branch has no commits yet.
    let branch: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    /// Staged + unstaged + untracked file count (`git status --porcelain`).
    let changedFiles: Int
    let lastCommit: Commit?

    var hasUpstream: Bool { upstream != nil }
    var isClean: Bool { changedFiles == 0 }
    /// Whether a publish would have local work to commit or push.
    var hasPendingWork: Bool { changedFiles > 0 || ahead > 0 }
    /// Clean AND nothing ahead of a known upstream → nothing to publish.
    /// Without an upstream there may still be unpushed commits, so that case
    /// always counts as publishable.
    var hasNothingToPublish: Bool { changedFiles == 0 && hasUpstream && ahead == 0 }
}

/// Collects `SiteStatus` snapshots. Read-only git plumbing via direct
/// `Process` captures (no console streaming), run detached so status refreshes
/// never touch the main thread. Parsing lives in a pure function so the
/// porcelain-format handling is unit-testable without a real repository.
enum SiteStatusService {
    private static let git = "/usr/bin/git"

    /// nil when the path isn't a git repository (or git is unusable).
    static func status(at path: String) async -> SiteStatus? {
        let root = NSString(string: path).expandingTildeInPath
        return await Task.detached(priority: .userInitiated) {
            guard let statusOutput = capture(git: git, root: root,
                                             args: ["status", "--porcelain=v1", "-b"]) else {
                return nil
            }
            let logOutput = capture(git: git, root: root,
                                    args: ["log", "-1", "--pretty=format:%h%x1f%s%x1f%ct"])
            return parse(statusLines: statusOutput.split(separator: "\n").map(String.init),
                         logLine: logOutput)
        }.value
    }

    /// The current HEAD's short hash, or nil outside a repository / with no
    /// commits. Used to stamp history records for site deployments.
    static func currentCommitShortHash(at path: String) async -> String? {
        let root = NSString(string: path).expandingTildeInPath
        return await Task.detached(priority: .utility) {
            guard let output = capture(git: git, root: root,
                                       args: ["log", "-1", "--pretty=format:%h"]) else { return nil }
            let hash = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return hash.isEmpty ? nil : hash
        }.value
    }

    // MARK: - Parsing

    /// `git status --porcelain=v1 -b` lines (+ an optional
    /// `%h%x1f%s%x1f%ct` log line). Split out from `status(at:)` for tests.
    static func parse(statusLines: [String], logLine: String?) -> SiteStatus {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changed = 0

        for line in statusLines {
            guard !line.isEmpty else { continue }
            if line.hasPrefix("## ") {
                let header = line.dropFirst(3)
                // Forms: `main...origin/main [ahead 1, behind 2]`,
                // `main...origin/main`, `HEAD (no branch)`,
                // `No commits yet on main`.
                if header.hasPrefix("No commits yet on ") {
                    branch = String(header.dropFirst("No commits yet on ".count))
                    continue
                }
                let tracking = header.split(separator: " ", maxSplits: 1)
                let head = tracking[0]
                if let sep = head.range(of: "...") {
                    let name = String(head[head.startIndex..<sep.lowerBound])
                    branch = name == "HEAD" ? nil : name
                    upstream = String(head[sep.upperBound...])
                } else {
                    branch = head == "HEAD" ? nil : String(head)
                }
                if tracking.count > 1, let bracket = tracking[1].firstIndex(of: "[") {
                    let flags = header[bracket...]
                    ahead = Self.firstInt(after: "ahead", in: flags) ?? 0
                    behind = Self.firstInt(after: "behind", in: flags) ?? 0
                }
            } else {
                changed += 1
            }
        }

        var commit: SiteStatus.Commit?
        if let logLine {
            let fields = logLine.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                .map(String.init)
            if fields.count == 3, let unix = Double(fields[2]) {
                commit = SiteStatus.Commit(shortHash: fields[0], subject: fields[1],
                                           date: Date(timeIntervalSince1970: unix))
            }
        }

        return SiteStatus(branch: branch, upstream: upstream, ahead: ahead, behind: behind,
                          changedFiles: changed, lastCommit: commit)
    }

    private static func firstInt(after key: String, in flags: Substring) -> Int? {
        guard let range = flags.range(of: "\(key) \\d+", options: .regularExpression) else { return nil }
        let digits = flags[range].dropFirst(key.count + 1)
        return Int(digits)
    }

    // MARK: - Process capture

    /// nil when the process couldn't run at all (e.g. missing directory);
    /// otherwise the captured stdout, exit status notwithstanding.
    private static func capture(git: String, root: String, args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", root] + args
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
