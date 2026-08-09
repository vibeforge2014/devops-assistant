import Foundation

/// Drives native Xcode builds (xcodegen + xcodebuild) for projects that don't
/// route through fastlane, and as the archive step for any project that needs
/// a raw xcarchive. Used by ChargePilot (macOS), TailTalk & MinuteFlow (iOS,
/// no fastlane), and as a fallback for the build step in a release flow.
@MainActor
final class BuildService {
    let runner: ShellRunner

    init(runner: ShellRunner) {
        self.runner = runner
    }

    /// Generate the Xcode project via XcodeGen if a project.yml is present.
    @discardableResult
    func generateXcodeProject(at path: String) async -> RunResult {
        let yml = "\(path)/project.yml"
        guard FileManager.default.fileExists(atPath: yml) else {
            runner.log("ℹ 无 project.yml,跳过 xcodegen")
            return RunResult(exitCode: 0, cancelled: false)
        }
        runner.log("▶ xcodegen generate")
        return await runner.run(executable: "/usr/bin/env", args: ["xcodegen", "generate"],
                                cwd: path, timeout: 120)
    }

    /// Build an archive (xcarchive) for an app's scheme, generic destination.
    @discardableResult
    func archive(app: AppProject,
                 to archivePath: String,
                 signingAllowed: Bool = false,
                 apiKey: TemporaryAPIKey? = nil) async -> RunResult {
        let destination = app.platform == .macos
            ? "generic/platform=macOS"
            : "generic/platform=iOS"
        runner.log("▶ xcodebuild archive — \(app.scheme)")
        var args = [
            "archive",
            "-scheme", app.scheme,
            "-destination", destination,
            "-archivePath", archivePath,
            "-derivedDataPath", "\(app.resolvedPath)/build/DerivedData",
        ]
        if signingAllowed {
            args.append("-allowProvisioningUpdates")
            if let apiKey {
                args += ["-authenticationKeyPath", apiKey.url.path,
                         "-authenticationKeyID", apiKey.keyID,
                         "-authenticationKeyIssuerID", apiKey.issuerID]
            }
        } else {
            args.append("CODE_SIGNING_ALLOWED=NO")
        }
        return await runner.run(executable: "/usr/bin/xcodebuild", args: args,
                                cwd: app.resolvedPath, timeout: 3600)
    }

    /// Clean the build folder.
    @discardableResult
    func clean(app: AppProject) async -> RunResult {
        runner.log("▶ xcodebuild clean — \(app.scheme)")
        return await runner.run(executable: "/usr/bin/xcodebuild",
                                args: ["clean", "-scheme", app.scheme],
                                cwd: app.resolvedPath, timeout: 900)
    }

    /// A conventional archive path for an app under its build/ dir.
    func archivePath(for app: AppProject) -> String {
        "\(app.resolvedPath)/build/\(app.scheme).xcarchive"
    }
}
