import Foundation

/// Relocates a project whose on-disk path is empty or has gone stale (the
/// checkout was moved/renamed) by scanning a prioritized list of root folders.
///
/// The locator is synchronous, side-effect free, and never shells out: it reads
/// `.git/config` directly and does bounded `FileManager` enumeration, so it is
/// cheap to run on launch and trivially testable. It only ever *suggests* a new
/// path — `ProjectCatalog` decides whether to adopt and persist it.
struct ProjectLocator {
    /// Roots scanned in priority order. The first root that contains a match
    /// wins, so the most specific (e.g. a `vibeforge` workspace) should come
    /// first to avoid touching a sprawling `~/Desktop`.
    static let defaultRoots: [String] = [
        "~/Desktop/vibeforge",
        "~/Desktop",
        "~/Documents",
        "~/Developer"
    ]

    /// Directory names never descended into during the recursive scheme search.
    /// They are either huge dependency trees or pure build/output artifacts.
    private static let prunedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".wrangler", ".zcode", ".codex",
        ".claude", ".opencode", ".next", "node_modules", "Pods",
        "build", "DerivedData", "output", "out", "dist", "artifacts"
    ]

    private let roots: [String]
    private let fileManager: FileManager
    private let schemeSearchDepth: Int
    private let originScanDepth: Int
    private let maxVisitedDirs: Int

    /// - Parameters:
    ///   - roots: Tilde-expanded, existence-filtered search roots. Roots that
    ///     do not exist on disk are silently dropped.
    init(roots: [String] = defaultRoots,
         fileManager: FileManager = .default,
         schemeSearchDepth: Int = 4,
         originScanDepth: Int = 3,
         maxVisitedDirs: Int = 6000) {
        self.roots = roots.compactMap(Self.expand).filter { fileManager.fileExists(atPath: $0) }
        self.fileManager = fileManager
        self.schemeSearchDepth = schemeSearchDepth
        self.originScanDepth = originScanDepth
        self.maxVisitedDirs = maxVisitedDirs
    }

    // MARK: - Public entry points

    /// Returns a copy of `app` with its `path` repointed at the directory that
    /// owns `<scheme>.xcodeproj`, or `nil` if the current path is still valid or
    /// no candidate could be found.
    func relocate(_ app: AppProject) -> AppProject? {
        // Never clobber a path that still resolves on disk.
        if !app.resolvedPath.isEmpty, fileManager.fileExists(atPath: app.resolvedPath) { return nil }

        guard let dir = locateAppDir(scheme: app.scheme, repositoryURL: app.repositoryURL) else { return nil }
        return AppProject(id: app.id, name: app.name, path: dir,
                          repositoryURL: app.repositoryURL, platform: app.platform,
                          scheme: app.scheme, bundleId: app.bundleId,
                          versionSource: app.versionSource, release: app.release)
    }

    /// Returns a copy of `site` with its `path` repointed at its checkout, or
    /// `nil` if the current path is valid or no git-origin match was found.
    /// Sites have no scheme to fall back on, so only an origin match is trusted.
    func relocate(_ site: SiteProject) -> SiteProject? {
        if !site.resolvedPath.isEmpty, fileManager.fileExists(atPath: site.resolvedPath) { return nil }

        guard let dir = locateSiteDir(repositoryURL: site.repositoryURL) else { return nil }
        return SiteProject(id: site.id, name: site.name, path: dir,
                           repositoryURL: site.repositoryURL, deploy: site.deploy)
    }

    // MARK: - App location

    private func locateAppDir(scheme: String, repositoryURL: String) -> String? {
        // Phase A — a checkout whose origin matches the configured repo is the
        // strongest signal. If found, the buildable dir lives somewhere inside
        // it; locate <scheme>.xcodeproj there and return its parent.
        if let originDir = firstOriginMatch(repositoryURL: repositoryURL, maxDepth: originScanDepth) {
            if scheme.isEmpty { return originDir }
            if let parent = findXcodeprojParent(startingAt: originDir, scheme: scheme,
                                                maxDepth: schemeSearchDepth) {
                return parent
            }
        }

        // Phase B — no origin match (e.g. the remote was renamed/forked). Fall
        // back to a bounded recursive search for <scheme>.xcodeproj across all
        // roots. Scheme names are unique enough to trust as a last resort.
        guard !scheme.isEmpty else { return nil }
        for root in roots {
            if let parent = findXcodeprojParent(startingAt: root, scheme: scheme,
                                                maxDepth: schemeSearchDepth) {
                return parent
            }
        }
        return nil
    }

    // MARK: - Site location

    private func locateSiteDir(repositoryURL: String) -> String? {
        firstOriginMatch(repositoryURL: repositoryURL, maxDepth: originScanDepth)
    }

    // MARK: - Origin matching

    /// Walks each root up to `maxDepth` levels and returns the first directory
    /// whose `[remote "origin"]` normalizes to the same `owner/repo` as
    /// `repositoryURL`. Depth is kept shallow so a broad root stays cheap.
    private func firstOriginMatch(repositoryURL: String, maxDepth: Int) -> String? {
        let target = Self.normalize(repositoryURL)
        guard !target.isEmpty else { return nil }

        for root in roots {
            if matchesOrigin(at: root, target: target) { return root }
            if let found = scanForOrigin(startingAt: root, target: target, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func scanForOrigin(startingAt root: String, target: String, maxDepth: Int) -> String? {
        var visited = 0
        var stack: [(URL, Int)] = [(URL(fileURLWithPath: root), 0)]
        while let (dir, depth) = stack.popLast() {
            visited += 1
            if visited > maxVisitedDirs { return nil }
            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { continue }
            for child in children where isDirectory(child) {
                if matchesOrigin(at: child.path, target: target) { return child.path }
                stack.append((child, depth + 1))
            }
        }
        return nil
    }

    private func matchesOrigin(at path: String, target: String) -> Bool {
        guard let origin = Self.originRemote(at: path, fileManager: fileManager) else { return false }
        return Self.normalize(origin) == target
    }

    // MARK: - .git/config parsing

    /// Reads `[remote "origin"]` `url` directly from `.git/config`. Handles a
    /// `.git` file (gitdir pointer used by worktrees/submodules). Returns nil
    /// when the path is not a git checkout or has no origin.
    static func originRemote(at path: String, fileManager: FileManager = .default) -> String? {
        let gitEntry = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: gitEntry, isDirectory: &isDir) else { return nil }

        let configURL: URL
        if isDir.boolValue {
            configURL = URL(fileURLWithPath: gitEntry).appendingPathComponent("config")
        } else if let pointer = try? String(contentsOf: URL(fileURLWithPath: gitEntry), encoding: .utf8) {
            // `gitdir: /path/to/real` (and the bare `gitdir:` form). Resolve it
            // relative to the checkout so submodule pointers work too.
            let raw = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "gitdir:"
            guard raw.hasPrefix(prefix) else { return nil }
            var resolved = raw.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if (resolved as NSString).isAbsolutePath == false {
                resolved = ((path as NSString).appendingPathComponent(String(resolved)))
            }
            configURL = URL(fileURLWithPath: String(resolved)).appendingPathComponent("config")
        } else {
            return nil
        }

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return parseOriginURL(from: content)
    }

    /// Extracts the `url` under the `[remote "origin"]` section of a git config.
    private static func parseOriginURL(from config: String) -> String? {
        var inOrigin = false
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOrigin = trimmed == #"[remote "origin"]"#
                continue
            }
            guard inOrigin else { continue }
            if trimmed.hasPrefix("url") {
                // `url = value` or `url=value`
                if let eq = trimmed.firstIndex(of: "=") {
                    let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return String(value) }
                }
            }
        }
        return nil
    }

    /// Normalizes any GitHub clone URL form to a lowercase `owner/repo`.
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ssh://git@", "git@", "https://", "http://", "ssh://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        for prefix in ["github.com:", "github.com/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - xcodeproj search

    /// Bounded DFS for the directory that directly contains
    /// `<scheme>.xcodeproj`. Returns that directory's path (the buildable root),
    /// or nil if not found within `maxDepth` levels.
    private func findXcodeprojParent(startingAt root: String, scheme: String, maxDepth: Int) -> String? {
        let target = "\(scheme).xcodeproj"
        var visited = 0
        var stack: [(URL, Int)] = [(URL(fileURLWithPath: root), 0)]

        while let (dir, depth) = stack.popLast() {
            visited += 1
            if visited > maxVisitedDirs { return nil }

            // Does this directory directly own the xcodeproj?
            let candidate = dir.appendingPathComponent(target)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return dir.path
            }

            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { continue }
            for child in children where isDirectory(child) {
                let name = child.lastPathComponent
                if Self.prunedDirectories.contains(name) { continue }
                stack.append((child, depth + 1))
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Expands `~` and resolves symlinks so returned (and stored) paths are
    /// canonical — this also dodges macOS `/var` ↔ `/private/var` mismatches.
    private static func expand(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let tildeExpanded = trimmed.hasPrefix("~")
            ? NSString(string: trimmed).expandingTildeInPath
            : trimmed
        return URL(fileURLWithPath: tildeExpanded).resolvingSymlinksInPath().path
    }
}
