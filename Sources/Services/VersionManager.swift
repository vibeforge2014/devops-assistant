import Foundation

/// A parsed (marketing, build) version pair read from a project.
struct VersionPair: Equatable {
    var marketing: String   // MARKETING_VERSION, e.g. "0.2.5"
    var build: String       // CURRENT_PROJECT_VERSION, e.g. "8"
}

/// Reads and writes MARKETING_VERSION / CURRENT_PROJECT_VERSION, adapting to
/// where each project stores them:
///   - `project.yml` (XcodeGen): lines under `settings.base`
///   - `pbxproj`: `MARKETING_VERSION = x;` build-setting lines
///
/// We edit these as text (regex) rather than parsing the whole project format.
/// Reads strip surrounding quotes; writes preserve the original quoting style
/// and never touch lines inside comments.
struct VersionManager {

    // MARK: - Read

    /// Read the version pair for an app project.
    static func read(_ app: AppProject) -> VersionPair? {
        switch app.versionSource {
        case .projectYml:
            return readFromProjectYml(app.resolvedPath)
        case .pbxproj:
            return readFromPbxproj(app.resolvedPath)
        case .xcconfig:
            return nil
        }
    }

    /// Write a version pair to an app project.
    @discardableResult
    static func write(_ version: VersionPair, to app: AppProject) -> Bool {
        switch app.versionSource {
        case .projectYml:
            return writeToProjectYml(app.resolvedPath, version: version)
        case .pbxproj:
            return writeToPbxproj(app.resolvedPath, version: version)
        case .xcconfig:
            return false
        }
    }

    /// Bump the build number by 1, returning the new pair.
    /// Returns nil — without writing — if the current build isn't a pure
    /// integer (so we never silently clobber an unexpected value).
    @discardableResult
    static func bumpBuild(_ app: AppProject) -> VersionPair? {
        guard var current = read(app) else { return nil }
        guard let n = Int(current.build) else {
            #if DEBUG
            print("[VersionManager] build '\(current.build)' is not an integer — refusing to bump")
            #endif
            return nil
        }
        current.build = String(n + 1)
        return write(current, to: app) ? current : nil
    }

    // MARK: - project.yml (XcodeGen)

    // Matches `MARKETING_VERSION: 0.2.5` or `MARKETING_VERSION: "0.2.5"`.
    // Groups: [1] prefix+key (incl. `:`), [2] whole `: <value>` segment.
    // Kept separate from the pbx patterns because the value segment structure
    // differs (no trailing `;`). `capture` reads group [2]; replace uses it too.
    private static let ymlKeyPattern = "^(\\s*(?:-\\s+)?MARKETING_VERSION)(\\s*:\\s*(?:\"|'?)[^\"'\\s]+)"
    private static let ymlBuildPattern = "^(\\s*(?:-\\s+)?CURRENT_PROJECT_VERSION)(\\s*:\\s*(?:\"|'?)[^\"'\\s]+)"

    private static func readFromProjectYml(_ dir: String) -> VersionPair? {
        guard let text = try? String(contentsOfFile: "\(dir)/project.yml", encoding: .utf8) else {
            return nil
        }
        guard let marketing = capture(from: text, pattern: ymlKeyPattern),
              let build = capture(from: text, pattern: ymlBuildPattern) else {
            return nil
        }
        return VersionPair(marketing: unquote(marketing), build: unquote(build))
    }

    private static func writeToProjectYml(_ dir: String, version: VersionPair) -> Bool {
        let url = URL(fileURLWithPath: "\(dir)/project.yml")
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        text = replaceYmlCaptured(text, pattern: ymlBuildPattern, newValue: version.build)
        text = replaceYmlCaptured(text, pattern: ymlKeyPattern, newValue: version.marketing)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Rewrite the value of every matching `key:<value>` line, keeping the
    /// prefix (indent + key) and any quotes on the value. Groups: [1] prefix,
    /// [2] `:` + value segment.
    private static func replaceYmlCaptured(_ text: String, pattern: String, newValue: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: ns)
        var out = text
        for m in matches.reversed() {
            guard m.numberOfRanges > 2,
                  let segRange = Range(m.range(at: 2), in: out) else { continue }
            let seg = String(out[segRange])
            let quoted = seg.contains(": \"") || seg.contains(": '")
            let newSeg = quoted ? ": \"\(newValue)\"" : ": \(newValue)"
            out.replaceSubrange(segRange, with: newSeg)
        }
        return out
    }

    // MARK: - pbxproj

    // pbxproj stores `MARKETING_VERSION = 0.2.5;` (possibly quoted). Matching
    // requires the line to START with the key, so `/ * MARKETING_VERSION … * /`
    // comments (which begin with `/*`) never match. Group [1] prefix, [2] key,
    // [3] `= … ;` segment.
    private static let pbxKeyPattern = "^([\\t ]*)(MARKETING_VERSION)([ \\t]*=[^;]*;)"
    private static let pbxBuildPattern = "^([\\t ]*)(CURRENT_PROJECT_VERSION)([ \\t]*=[^;]*;)"

    private static func pbxprojURL(_ dir: String) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        guard let projName = entries.first(where: { $0.hasSuffix(".xcodeproj") }) else { return nil }
        let path = "\(dir)/\(projName)/project.pbxproj"
        return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func readFromPbxproj(_ dir: String) -> VersionPair? {
        guard let url = pbxprojURL(dir),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Simpler read regex: find any (non-comment) assignment. We match the
        // key followed by = …; on its own line, which comments never satisfy.
        guard let marketing = capture(from: text, pattern: pbxKeyPattern),
              let build = capture(from: text, pattern: pbxBuildPattern) else {
            return nil
        }
        return VersionPair(marketing: unquote(marketing), build: unquote(build))
    }

    private static func writeToPbxproj(_ dir: String, version: VersionPair) -> Bool {
        guard let url = pbxprojURL(dir),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        text = replaceCaptured(text, pattern: pbxBuildPattern, newValue: version.build)
        text = replaceCaptured(text, pattern: pbxKeyPattern, newValue: version.marketing)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Regex helpers

    /// Capture the value of the first match (the last capture group).
    private static func capture(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 0,
              let r = Range(m.range(at: m.numberOfRanges - 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Rewrite the value (preserving quote style) of every matching line.
    /// Groups: [1] prefix, [2] key, [3] `= … ;` segment. We rebuild the segment
    /// keeping any surrounding quotes carried in group [3].
    private static func replaceCaptured(_ text: String, pattern: String, newValue: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: ns)

        // Apply replacements from the end so indices stay valid.
        var out = text
        for m in matches.reversed() {
            guard m.numberOfRanges > 3,
                  let segRange = Range(m.range(at: 3), in: out) else { continue }
            let oldSegment = String(out[segRange])
            let newSegment = rebuild(oldSegment, newValue: newValue)
            out.replaceSubrange(segRange, with: newSegment)
        }
        return out
    }

    /// Given the old `= <value>;` segment, produce `= <new>;` keeping any
    /// surrounding quotes that `oldSegment` carries.
    private static func rebuild(_ oldSegment: String, newValue: String) -> String {
        let trimmed = oldSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = trimmed.contains("= \"") || trimmed.contains("= '")
        let value = quoted ? "\"\(newValue)\"" : newValue

        // Reconstruct as ` = <value>;`, preserving the old trailing style.
        if quoted {
            return " = \"\(newValue)\";"
        }
        _ = value
        return " = \(newValue);"
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") { return String(t.dropFirst().dropLast()) }
        if t.hasPrefix("'") && t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
        return t
    }
}
