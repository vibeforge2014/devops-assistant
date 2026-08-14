import Foundation

struct ArtifactResult {
    let result: RunResult
    let path: String?
    var succeeded: Bool { result.succeeded && path != nil }
}

/// Native local packaging for projects that do not provide their own script.
/// Outputs live under <project>/build/artifacts.
@MainActor
final class ArtifactPackagingService {
    let runner: ShellRunner
    private var build: BuildService { BuildService(runner: runner) }

    init(runner: ShellRunner) { self.runner = runner }

    func packageIPA(app: AppProject) async -> ArtifactResult {
        guard app.platform == .ios else { return failure("只有 iOS 项目可以打包 IPA") }
        guard let teamID = KeychainStore.get(.appleTeamID), let key = TemporaryAPIKey() else {
            return failure("打包 IPA 需要有效的 Team ID 与 ASC API Key")
        }
        let generated = await build.generateXcodeProject(at: app.resolvedPath)
        guard generated.succeeded else { return .init(result: generated, path: nil) }

        let archivePath = build.archivePath(for: app)
        let archive = await build.archive(app: app, to: archivePath, signingAllowed: true, apiKey: key)
        guard archive.succeeded else { return .init(result: archive, path: nil) }

        let artifacts = "\(app.resolvedPath)/build/artifacts"
        let exportDir = "\(app.resolvedPath)/build/ipa-export"
        try? FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: exportDir)
        guard let plistURL = writeExportOptions(method: "app-store-connect",
                                                teamID: teamID,
                                                extras: ["destination": "export",
                                                         "manageAppVersionAndBuildNumber": false,
                                                         "uploadSymbols": true]) else {
            return failure("无法生成 ExportOptions.plist")
        }
        defer { try? FileManager.default.removeItem(at: plistURL) }

        runner.log("▶ 内置 IPA 导出 — \(app.name)")
        let exported = await runner.run(executable: "/usr/bin/xcodebuild", args: [
            "-exportArchive", "-archivePath", archivePath, "-exportPath", exportDir,
            "-exportOptionsPlist", plistURL.path, "-allowProvisioningUpdates",
            "-authenticationKeyPath", key.url.path,
            "-authenticationKeyID", key.keyID,
            "-authenticationKeyIssuerID", key.issuerID,
        ], cwd: app.resolvedPath, timeout: 3600)
        guard exported.succeeded else { return .init(result: exported, path: nil) }
        guard let source = firstFile(withExtension: "ipa", under: exportDir) else {
            return failure("xcodebuild 已完成，但导出目录中没有 IPA")
        }
        let version = VersionManager.read(app)
        let suffix = version.map { "-\($0.marketing)-\($0.build)" } ?? ""
        let destination = "\(artifacts)/\(app.name)\(suffix).ipa"
        do {
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            runner.log("✓ IPA: \(destination)")
            return .init(result: exported, path: destination)
        } catch { return failure("无法保存 IPA: \(error.localizedDescription)") }
    }

    /// Export the project's archive re-signed with a Developer ID Application
    /// identity (direct-distribution, outside the App Store). Reuses the
    /// xcarchive produced by the build step.
    func exportDeveloperID(app: AppProject) async -> ArtifactResult {
        let archivePath = build.archivePath(for: app)
        guard FileManager.default.fileExists(atPath: archivePath) else {
            return failure("找不到归档 \(archivePath)，请先构建")
        }
        guard let teamID = KeychainStore.get(.appleTeamID) else {
            return failure("导出 Developer ID 需要 Apple Team ID")
        }
        let exportDir = "\(app.resolvedPath)/build/dev-id-export"
        try? FileManager.default.removeItem(atPath: exportDir)
        try? FileManager.default.createDirectory(atPath: "\(app.resolvedPath)/build",
                                                 withIntermediateDirectories: true)
        guard let plistURL = writeExportOptions(method: "developer-id",
                                                teamID: teamID,
                                                extras: ["signingStyle": "automatic"]) else {
            return failure("无法生成 ExportOptions.plist")
        }
        defer { try? FileManager.default.removeItem(at: plistURL) }

        runner.log("▶ 导出 Developer ID 应用 — \(app.name)")
        let exported = await runner.run(executable: "/usr/bin/xcodebuild", args: [
            "-exportArchive", "-archivePath", archivePath,
            "-exportPath", exportDir, "-exportOptionsPlist", plistURL.path,
        ], cwd: app.resolvedPath, timeout: 3600)
        guard exported.succeeded else { return .init(result: exported, path: nil) }
        guard let appBundle = firstAppBundle(under: exportDir) else {
            return failure("导出完成，但目录中没有 .app: \(exportDir)")
        }
        runner.log("✓ Developer ID app: \(appBundle)")
        return .init(result: exported, path: appBundle)
    }

    /// Build a distributable DMG from an already-exported Developer ID .app,
    /// then sign the DMG itself with Developer ID + timestamp so it can be
    /// notarized and stapled. The DMG carries the hyphenated release name
    /// (e.g. `DevOps-Assistant-1.3.0.dmg`) so its GitHub download URL is stable.
    func buildSignedDMG(app: AppProject, appBundle: String) async -> ArtifactResult {
        let artifacts = "\(app.resolvedPath)/build/artifacts"
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeforge-dmg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let bundledName = "\(app.name).app"
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: appBundle,
                                             toPath: staging.appendingPathComponent(bundledName).path)
            try FileManager.default.createSymbolicLink(
                atPath: staging.appendingPathComponent("Applications").path,
                withDestinationPath: "/Applications")
            try FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
        } catch { return failure("准备 DMG 内容失败: \(error.localizedDescription)") }

        let version = VersionManager.read(app)?.marketing ?? "0"
        let releaseName = app.name.replacingOccurrences(of: " ", with: "-")
        let destination = "\(artifacts)/\(releaseName)-\(version).dmg"
        try? FileManager.default.removeItem(atPath: destination)
        runner.log("▶ 打包 DMG — \(releaseName)-\(version)")
        let dmg = await runner.run(executable: "/usr/bin/hdiutil", args: [
            "create", "-volname", app.name, "-srcfolder", staging.path,
            "-ov", "-format", "UDZO", destination
        ], timeout: 1800)
        guard dmg.succeeded else { return .init(result: dmg, path: nil) }

        // The DMG image itself must be signed before notarization, or
        // `spctl --type install` later reports "no usable signature". codesign
        // accepts an identity-name prefix and resolves the full certificate.
        runner.log("▶ 签名 DMG — Developer ID Application")
        let signed = await runner.run(executable: "/usr/bin/codesign", args: [
            "--force", "--sign", "Developer ID Application", "--timestamp", destination
        ], timeout: 300)
        guard signed.succeeded else { return .init(result: signed, path: nil) }
        runner.log("✓ DMG: \(destination)")
        return .init(result: signed, path: destination)
    }

    func packageDMG(app: AppProject) async -> ArtifactResult {
        guard app.platform == .macos else { return failure("只有 macOS 项目可以打包 DMG") }
        let generated = await build.generateXcodeProject(at: app.resolvedPath)
        guard generated.succeeded else { return .init(result: generated, path: nil) }
        let archivePath = build.archivePath(for: app)
        let archive = await build.archive(app: app, to: archivePath)
        guard archive.succeeded else { return .init(result: archive, path: nil) }
        let appBundle = "\(archivePath)/Products/Applications/\(app.scheme).app"
        guard FileManager.default.fileExists(atPath: appBundle) else { return failure("Archive 中找不到 \(app.scheme).app") }

        let signed: RunResult
        if app.release.signing == .developerID {
            signed = await NotaryService(runner: runner).signAppBundle(at: appBundle)
            guard signed.succeeded else { return .init(result: signed, path: nil) }
        } else {
            signed = RunResult(exitCode: 0, cancelled: false)
        }
        let artifacts = "\(app.resolvedPath)/build/artifacts"
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeforge-dmg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: appBundle, toPath: staging.appendingPathComponent("\(app.name).app").path)
            try FileManager.default.createSymbolicLink(atPath: staging.appendingPathComponent("Applications").path,
                                                       withDestinationPath: "/Applications")
            try FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
        } catch { return failure("准备 DMG 内容失败: \(error.localizedDescription)") }
        let version = VersionManager.read(app)?.marketing ?? "local"
        let destination = "\(artifacts)/\(app.name)-\(version).dmg"
        try? FileManager.default.removeItem(atPath: destination)
        runner.log("▶ 内置 DMG 打包 — \(app.name)")
        let result = await runner.run(executable: "/usr/bin/hdiutil", args: [
            "create", "-volname", app.name, "-srcfolder", staging.path,
            "-ov", "-format", "UDZO", destination
        ], timeout: 1800)
        if result.succeeded { runner.log("✓ DMG: \(destination)") }
        return .init(result: result, path: result.succeeded ? destination : nil)
    }

    /// Write an ExportOptions.plist for `xcodebuild -exportArchive`. Centralizes
    /// plist generation so IPA (app-store-connect) and macOS (developer-id) paths
    /// share one audited writer instead of each inlining its own dictionary.
    private func writeExportOptions(method: String,
                                    teamID: String,
                                    extras: [String: Any] = [:]) -> URL? {
        var options: [String: Any] = ["method": method, "teamID": teamID]
        options.merge(extras) { _, new in new }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportOptions-\(UUID().uuidString).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: options,
                                                          format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            runner.log("✗ 无法生成 ExportOptions.plist: \(error.localizedDescription)")
            return nil
        }
    }

    /// First `.app` bundle directory directly under a path (export root).
    private func firstAppBundle(under path: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.first(where: { $0.hasSuffix(".app") }).map { "\(path)/\($0)" }
    }

    private func firstFile(withExtension ext: String, under path: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
        while let item = enumerator.nextObject() as? String {
            if item.lowercased().hasSuffix(".\(ext.lowercased())") { return "\(path)/\(item)" }
        }
        return nil
    }

    private func failure(_ message: String) -> ArtifactResult {
        runner.log("✗ \(message)")
        return .init(result: RunResult(exitCode: -1, cancelled: false), path: nil)
    }
}
