import Foundation

// MARK: - Errors

enum AppUpdateError: LocalizedError, Equatable {
    case malformedResponse
    case noDMGAsset(String)
    case http(Int)
    case transport(String)
    case verificationFailed(String)
    case mountFailed(String)
    case installFailed(String)
    /// The running copy isn't in an /Applications drag-install location
    /// (debug build, translocated copy…) — hand the DMG to Finder instead.
    case needsManualInstall(dmgPath: String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "GitHub 返回的 release 数据无法解析"
        case .noDMGAsset(let tag):
            return "release \(tag) 没有附带 .dmg 安装包,无法在线更新"
        case .http(403):
            return "GitHub API 限流(403),请稍后再试"
        case .http(let code):
            return "GitHub 请求失败(HTTP \(code))"
        case .transport(let detail):
            return "网络请求失败(代理/断网/超时): \(detail)"
        case .verificationFailed(let detail):
            return "新版本未通过 Apple 公证校验,已中止安装: \(detail)"
        case .mountFailed(let detail):
            return "无法挂载下载的 DMG: \(detail)"
        case .installFailed(let detail):
            return "安装失败: \(detail)"
        case .needsManualInstall:
            return "当前应用不在 /Applications 下,已打开下载好的 DMG — 拖拽安装后重启应用即可"
        }
    }
}

// MARK: - Feed model

/// One published release of this app, as served by the GitHub Releases API
/// (`/repos/<owner>/<repo>/releases/latest` — the same feed the landing
/// page's download button points at). Only the `.dmg` asset matters: its
/// `browser_download_url` is what the updater fetches, so every release
/// must keep shipping a DMG for in-app update to work.
struct AppUpdateInfo: Equatable {
    let tagName: String          // "v1.2.1"
    let title: String?           // release title, e.g. "DevOps Assistant 1.2.1"
    /// Release notes — the `gh release` body, shown as plain text.
    let notes: String?
    let htmlURL: URL?            // human-facing release page
    let publishedAt: Date?
    let assetName: String        // "DevOps-Assistant-1.2.1.dmg"
    let assetSize: Int64         // bytes, per the release manifest
    let downloadURL: URL

    /// "1.2.1" — the tag with a leading "v" stripped.
    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    func isNewer(than currentVersion: String) -> Bool {
        AppVersion.isNewer(version, than: currentVersion)
    }
}

// MARK: - Parsing

extension AppUpdateInfo {
    /// Decode the `releases/latest` JSON and select the DMG asset
    /// (preferring one whose name carries this release's version when
    /// several DMGs exist).
    static func parse(_ data: Data) throws -> AppUpdateInfo {
        struct DTO: Codable {
            struct Asset: Codable {
                let name: String
                let size: Int64
                let browserDownloadURL: String
                enum CodingKeys: String, CodingKey {
                    case name, size
                    case browserDownloadURL = "browser_download_url"
                }
            }
            let tagName: String
            let name: String?
            let body: String?
            let htmlURL: String?
            let publishedAt: String?
            let assets: [Asset]?
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name", name, body, assets
                case htmlURL = "html_url"
                case publishedAt = "published_at"
            }
        }

        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            throw AppUpdateError.malformedResponse
        }

        let version = dto.tagName.hasPrefix("v") ? String(dto.tagName.dropFirst()) : dto.tagName
        let dmgs = (dto.assets ?? []).filter { $0.name.lowercased().hasSuffix(".dmg") }
        let asset = dmgs.first { $0.name.contains(version) } ?? dmgs.first
        guard let asset, let url = URL(string: asset.browserDownloadURL) else {
            throw AppUpdateError.noDMGAsset(dto.tagName)
        }

        return AppUpdateInfo(
            tagName: dto.tagName,
            title: dto.name,
            notes: dto.body,
            htmlURL: dto.htmlURL.flatMap(URL.init(string:)),
            publishedAt: dto.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            assetName: asset.name,
            assetSize: asset.size,
            downloadURL: url)
    }
}

// MARK: - Version comparison

/// Numeric-aware dot-version compare. Plain string comparison would rank
/// "1.10" below "1.9", so components compare as integers; a missing
/// trailing component reads as zero ("1.2" == "1.2.0"), and a component
/// with a suffix ("1.3.0-beta") sorts below its bare release — matching
/// how this app's tags actually look.
enum AppVersion {
    static func isNewer(_ candidate: String, than baseline: String) -> Bool {
        compare(candidate, baseline) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map(parse)
        let b = rhs.split(separator: ".").map(parse)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : Component(number: 0, suffix: "")
            let y = index < b.count ? b[index] : Component(number: 0, suffix: "")
            if let order = compareComponents(x, y) { return order }
        }
        return .orderedSame
    }

    private struct Component {
        let number: Int?
        let suffix: String
    }

    /// ("10", "") from "10"; ("2", "-rc1") from "2-rc1"; (nil, "beta") from "beta".
    private static func parse(_ raw: Substring) -> Component {
        let digits = raw.prefix { $0.isNumber }
        return Component(number: Int(digits), suffix: String(raw.dropFirst(digits.count)))
    }

    private static func compareComponents(_ x: Component, _ y: Component) -> ComparisonResult? {
        if let xn = x.number, let yn = y.number {
            if xn != yn { return xn < yn ? .orderedAscending : .orderedDescending }
            // Same number: the bare release outranks its suffixed pre-release.
            if x.suffix.isEmpty != y.suffix.isEmpty {
                return x.suffix.isEmpty ? .orderedDescending : .orderedAscending
            }
            return x.suffix == y.suffix ? nil
                : (x.suffix < y.suffix ? .orderedAscending : .orderedDescending)
        }
        // Non-numeric components (never shipped by this app) fall back to text.
        let xs = x.number.map(String.init) ?? x.suffix
        let ys = y.number.map(String.init) ?? y.suffix
        return xs == ys ? nil : (xs < ys ? .orderedAscending : .orderedDescending)
    }
}
