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
/// We intentionally edit these as text (regex) rather than parsing the full
/// project format — it's robust to layout changes and matches how `agvtool`
/// and Xcode itself rewrite these values.
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
            return readFromXcconfig(app.resolvedPath)
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
            return writeToXcconfig(app.resolvedPath, version: version)
        }
    }

    /// Bump the build number by 1, returning the new pair (or nil on failure).
    @discardableResult
    static func bumpBuild(_ app: AppProject) -> VersionPair? {
        guard var current = read(app) else { return nil }
        guard let n = Int(current.build) else {
            current.build = "1"
            write(current, to: app)
            return current
        }
        current.build = String(n + 1)
        return write(current, to: app) ? current : nil
    }

    // MARK: - project.yml (XcodeGen)

    private static func readFromProjectYml(_ dir: String) -> VersionPair? {
        guard let text = try? String(contentsOfFile: "\(dir)/project.yml", encoding: .utf8) else {
            return nil
        }
        let marketing = match(#"MARKETING_VERSION:\s*"?([^"\s]+)"?"#, in: text)
        let build = match(#"CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?"#, in: text)
        guard let marketing, let build else { return nil }
        return VersionPair(marketing: marketing, build: build)
    }

    private static func writeToProjectYml(_ dir: String, version: VersionPair) -> Bool {
        let url = URL(fileURLWithPath: "\(dir)/project.yml")
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        text = replace(#"(MARKETING_VERSION:\s*)"?[^"\s]+"?"#, in: text, with: #"\1\#(version.marketing)"#)
        text = replace(#"(CURRENT_PROJECT_VERSION:\s*)"?[^"\s]+"?"#, in: text, with: #"\1\#(version.build)"#)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - pbxproj

    private static func pbxprojURL(_ dir: String) -> URL? {
        // Find the first .xcodeproj under the project root.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        guard let projName = entries.first(where: { $0.hasSuffix(".xcodeproj") }) else { return nil }
        let path = "\(dir)/\(projName)/project.pbxproj"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func readFromPbxproj(_ dir: String) -> VersionPair? {
        guard let url = pbxprojURL(dir),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // pbxproj quotes values: MARKETING_VERSION = 0.2.5;
        let marketing = match(#"MARKETING_VERSION\s*=\s*([^;]+);"#, in: text)
        let build = match(#"CURRENT_PROJECT_VERSION\s*=\s*([^;]+);"#, in: text)
        guard let marketing, let build else { return nil }
        return VersionPair(marketing: marketing.trimmingCharacters(in: .whitespacesAndNewlines),
                           build: build.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writeToPbxproj(_ dir: String, version: VersionPair) -> Bool {
        guard let url = pbxprojURL(dir),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        text = replace(#"(MARKETING_VERSION\s*=\s*)[^;]+;"#, in: text, with: #"\1\#(version.marketing);"#)
        text = replace(#"(CURRENT_PROJECT_VERSION\s*=\s*)[^;]+;"#, in: text, with: #"\1\#(version.build);"#)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - xcconfig (placeholder; not used by current projects)

    private static func readFromXcconfig(_ dir: String) -> VersionPair? {
        nil
    }
    private static func writeToXcconfig(_ dir: String, version: VersionPair) -> Bool {
        false
    }

    // MARK: - Regex helpers

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
