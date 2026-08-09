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
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportOptions-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plistURL) }
        let options: [String: Any] = [
            "method": "app-store-connect", "destination": "export",
            "signingStyle": "automatic", "teamID": teamID,
            "manageAppVersionAndBuildNumber": false, "uploadSymbols": true
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch { return failure("无法生成 ExportOptions.plist: \(error.localizedDescription)") }

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
