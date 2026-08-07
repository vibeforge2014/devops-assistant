import Foundation

/// Syncs version/feature data into the portal's `src/data/products.ts` so the
/// public product matrix reflects a new release. The portal is the single
/// aggregation point; this service edits its data file in place.
///
/// We edit products.ts as text (regex) rather than parsing TypeScript, which is
/// fragile-but-pragmatic for a known file shape and avoids a TS parser dep.
@MainActor
final class PortalSync {
    let runner: ShellRunner

    init(runner: ShellRunner) {
        self.runner = runner
    }

    /// The path to the portal's data file.
    static func productsPath(for portal: SiteProject) -> String {
        "\(portal.resolvedPath)/src/data/products.ts"
    }

    /// Update the version shown for a product by injecting a `version` field
    /// (or updating it if present) on that product's object literal.
    @discardableResult
    func updateVersion(productID: String, version: VersionPair, portal: SiteProject) async -> Bool {
        let path = Self.productsPath(for: portal)
        guard FileManager.default.fileExists(atPath: path) else {
            runner.log("✗ 找不到 portal 数据文件: \(path)")
            return false
        }
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }

        let versionString = "\(version.marketing) (\(version.build))"
        // Replace an existing `version: "..."` line scoped to this id block.
        // If absent, inject one after the id line for robustness.
        let idPattern = #"id: "\#(productID)","#
        if let r = text.range(of: idPattern) {
            // Remove existing version line within a window after the id.
            let window = text[r.upperBound...]
            if let vRange = window.range(of: #"\s*version: "[^"]*",\n"#, options: .regularExpression) {
                let absolute = r.upperBound..<text.index(r.upperBound, offsetBy: window.distance(from: window.startIndex, to: vRange.upperBound))
                text.removeSubrange(absolute)
            }
            text.insert(contentsOf: "\n    version: \"\(versionString)\",", at: r.upperBound)
        } else {
            runner.log("✗ products.ts 中未找到产品 \(productID)")
            return false
        }

        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            runner.log("✓ 已更新 portal 中 \(productID) 的版本为 \(versionString)")
            return true
        } catch {
            runner.log("✗ 写入失败: \(error.localizedDescription)")
            return false
        }
    }
}
