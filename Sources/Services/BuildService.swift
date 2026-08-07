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
        return await runner.run("xcodegen generate", cwd: path)
    }

    /// Build an archive (xcarchive) for an app's scheme, generic destination.
    @discardableResult
    func archive(app: AppProject, to archivePath: String) async -> RunResult {
        let destination = app.platform == .macos
            ? "generic/platform=macOS"
            : "generic/platform=iOS"
        let cmd = """
        xcodebuild archive \
          -scheme \(app.scheme) \
          -destination '\(destination)' \
          -archivePath '\(archivePath)' \
          -derivedDataPath '\(app.resolvedPath)/build/DerivedData' \
          CODE_SIGNING_ALLOWED=NO
        """
        runner.log("▶ xcodebuild archive — \(app.scheme)")
        return await runner.run(cmd, cwd: app.resolvedPath)
    }

    /// Clean the build folder.
    @discardableResult
    func clean(app: AppProject) async -> RunResult {
        runner.log("▶ xcodebuild clean — \(app.scheme)")
        let cmd = "xcodebuild clean -scheme \(app.scheme)"
        return await runner.run(cmd, cwd: app.resolvedPath)
    }

    /// A conventional archive path for an app under its build/ dir.
    func archivePath(for app: AppProject) -> String {
        "\(app.resolvedPath)/build/\(app.scheme).xcarchive"
    }
}
