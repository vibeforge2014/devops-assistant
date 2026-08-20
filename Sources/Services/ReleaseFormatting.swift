import Foundation

/// Pure derivation/formatting helpers behind the release wizard's "将发布"
/// preview and duration labels. No UI, no side effects — unit-testable.
enum ReleaseFormatting {

    /// Compact duration for step rows and the header timer:
    /// <60s → "12.3s"; <60m → "2m 05s"; else "1h 03m".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            return String(format: "%.1fs", max(0, seconds))
        }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        if minutes < 60 {
            return String(format: "%dm %02ds", minutes, total % 60)
        }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// The pair a default run (no explicit version) ships: same marketing,
    /// build +1. A non-integer build is returned unchanged — bumpBuild will
    /// fail the step in that case, so the preview shows reality.
    static func bumped(_ version: VersionPair) -> VersionPair {
        guard let build = Int(version.build) else { return version }
        return VersionPair(marketing: version.marketing, build: String(build + 1))
    }

    /// Translate the wizard's version fields into the exact `VersionPair` the
    /// run will write (mirrors ReleaseCoordinator's setVersion semantics):
    ///   - both fields empty → nil ("no explicit version": the coordinator
    ///     only bumps the build);
    ///   - empty marketing keeps the current one, empty build keeps the
    ///     current one (a new marketing with the same build is a valid ASC
    ///     upload);
    ///   - with no readable current version, blanks fall back to "" / "1"
    ///     the same way the pipeline does.
    static func resolvedVersion(current: VersionPair?,
                                marketing: String,
                                build: String) -> VersionPair? {
        let mkt = marketing.trimmingCharacters(in: .whitespaces)
        let bld = build.trimmingCharacters(in: .whitespaces)
        guard !mkt.isEmpty || !bld.isEmpty else { return nil }
        guard let current else {
            return VersionPair(marketing: mkt, build: bld.isEmpty ? "1" : bld)
        }
        return VersionPair(marketing: mkt.isEmpty ? current.marketing : mkt,
                           build: bld.isEmpty ? current.build : bld)
    }

    /// The version the wizard should PREVIEW for the current field state —
    /// same as `resolvedVersion`, except the both-empty default bumps the
    /// build so the "仅 build 号 +1" caption can show the actual number.
    static func previewVersion(current: VersionPair?,
                               marketing: String,
                               build: String) -> VersionPair? {
        if let resolved = resolvedVersion(current: current,
                                          marketing: marketing, build: build) {
            return resolved
        }
        return current.map(bumped)
    }
}
