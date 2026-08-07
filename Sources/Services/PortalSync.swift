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

    /// Update the version shown for a product by setting a `version` field on
    /// that product's object literal. Works on the whole object block, so an
    /// existing `version:` key anywhere between the id line and the closing
    /// `},` is replaced (never duplicated), and the field is inserted as one of
    /// the first keys if absent.
    @discardableResult
    func updateVersion(productID: String, version: VersionPair, portal: SiteProject) async -> Bool {
        let path = Self.productsPath(for: portal)
        guard FileManager.default.fileExists(atPath: path) else {
            runner.log("✗ 找不到 portal 数据文件: \(path)")
            return false
        }
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }

        let versionString = "\(version.marketing) (\(version.build))"

        // Locate the object block for this product: from its `id: "<id>",`
        // line up to the matching `},` (end of object) that is NOT followed by
        // more fields. We scan forward for the next `},` that appears to close
        // this object — in products.ts objects are `{ ... },` one per product.
        guard let idRange = text.range(of: #"id: "\#(productID)","#, options: .regularExpression) else {
            runner.log("✗ products.ts 中未找到产品 \(productID)")
            return false
        }

        // Find the end of this product's object: the next newline + `},` at
        // the same indentation (4 spaces → object close).
        let rest = text[idRange.upperBound...]
        guard let closeRange = rest.range(of: #"\n\s*\},\n"#, options: .regularExpression,
                                          range: rest.startIndex..<rest.endIndex) else {
            runner.log("✗ products.ts 中无法定位 \(productID) 对象块的结尾")
            return false
        }
        let objectEnd = text.index(idRange.upperBound, offsetBy: rest.distance(from: rest.startIndex, to: closeRange.lowerBound))
        let block = text[idRange.upperBound..<objectEnd]

        // Replace an existing `version: "..."` anywhere inside the block …
        if let existing = block.range(of: #"\s*version: "[^"]*","#, options: .regularExpression) {
            let start = block.index(block.startIndex, offsetBy: 0,
                                    limitedBy: block.startIndex)!
            let _ = start
            // Build the replacement, preserving indentation of the found line.
            let lineStart = block.range(of: #"[\s]*"#, options: .regularExpression,
                                        range: existing).map { block[$0] } ?? "    "
            _ = lineStart
            let updated = block.replacingCharacters(in: existing, with: "version: \"\(versionString)\",")
            text.replaceSubrange(idRange.upperBound..<objectEnd, with: updated)
        } else {
            // … otherwise inject right after the id line.
            let insertion = "\n    version: \"\(versionString)\","
            text.insert(contentsOf: insertion, at: idRange.upperBound)
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
