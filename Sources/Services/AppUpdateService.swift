import Darwin
import Foundation

/// Self-update over the GitHub Releases feed this app already publishes to
/// (public repo, unauthenticated API — one request per launch is far inside
/// the 60/hour limit):
///
///   check → download the DMG asset → Gatekeeper-verify it (`spctl`, must
///   read `source=Notarized Developer ID` — the same bar `release-sign.sh`
///   enforces) → swap the bundle in place → relaunch.
///
/// The swap only runs when the app lives in (~/)/Applications; any other
/// location (debug DerivedData builds, translocated copies) falls back to
/// opening the DMG in Finder for a manual drag. Nothing here mutates remote
/// state.
struct AppUpdateService {
    /// owner/repo whose releases are the update feed.
    var repo = "vibeforge2014/devops-assistant"

    // MARK: - Check

    func latestRelease() async throws -> AppUpdateInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw AppUpdateError.malformedResponse
        }
        var request = URLRequest(url: url)
        // This machine reaches GitHub through a slow proxy — don't give up early.
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppUpdateError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.http(http.statusCode)
        }
        return try AppUpdateInfo.parse(data)
    }

    // MARK: - Download

    /// Fetch the DMG into a temp file, sanity-check its size against the
    /// release manifest, and return the local URL.
    func download(_ info: AppUpdateInfo) async throws -> URL {
        var request = URLRequest(url: info.downloadURL)
        request.timeoutInterval = 300

        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AppUpdateError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.http(http.statusCode)
        }

        if let actual = (try? FileManager.default.attributesOfItem(atPath: tempURL.path))?[.size] as? NSNumber,
           actual.int64Value != info.assetSize {
            throw AppUpdateError.transport("下载不完整(实际 \(actual.int64Value)/清单 \(info.assetSize) 字节)")
        }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(info.assetName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            throw AppUpdateError.transport("无法保存下载文件: \(error.localizedDescription)")
        }
        return destination
    }

    // MARK: - Verify

    /// Gatekeeper assessment of the DMG. Exit 0 alone isn't enough — the
    /// output must name Notarized Developer ID, otherwise an unsigned-but-
    /// cached verdict could slip through.
    func verifyNotarization(dmgURL: URL) async throws {
        let result = await Self.runProcess(
            "/usr/sbin/spctl",
            ["--assess", "--type", "install", "-vvv", dmgURL.path],
            timeout: 120)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, output.contains("Notarized Developer ID") else {
            throw AppUpdateError.verificationFailed(String(output.prefix(200)))
        }
    }

    // MARK: - Install

    /// Mount the DMG, replace the running bundle, relaunch. Never returns
    /// on success — the process exits after `open`.
    func installAndRelaunch(dmgURL: URL) async throws {
        let fm = FileManager.default

        // 1) Attach quietly; the mount point comes from the plist output.
        let attach = await Self.runProcess(
            "/usr/bin/hdiutil",
            ["attach", "-plist", "-nobrowse", "-readonly", dmgURL.path],
            timeout: 60)
        guard attach.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(attach.output.utf8), options: [], format: nil) as? [String: Any],
              let mountPoint = ((plist["system-entities"] as? [[String: Any]]) ?? [])
                  .compactMap({ $0["mount-point"] as? String }).first else {
            throw AppUpdateError.mountFailed(String(attach.output.prefix(160)))
        }

        // 2) The app bundle is whatever .app sits at the volume root.
        let entries = (try? fm.contentsOfDirectory(atPath: mountPoint)) ?? []
        guard let appBundleName = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw AppUpdateError.installFailed("DMG 根目录没有 .app")
        }
        let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appBundleName).path

        // 3) Auto-swap only for drag-install locations; everything else
        //    gets the manual path so we never clobber a dev build.
        let currentPath = Bundle.main.bundleURL.path
        let managed = currentPath.hasPrefix("/Applications/")
            || currentPath.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard managed else {
            _ = await Self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"], timeout: 30)
            throw AppUpdateError.needsManualInstall(dmgPath: dmgURL.path)
        }

        // 4) Swap: move the running copy aside (the process keeps its open
        //    file references), ditto the new one in, restore on failure,
        //    then relaunch the new build.
        let destURL = Bundle.main.bundleURL
        let asideURL = destURL.appendingPathExtension("replaced-\(getpid())")
        do {
            try fm.moveItem(at: destURL, to: asideURL)
        } catch {
            throw AppUpdateError.installFailed("无法移开当前应用: \(error.localizedDescription)")
        }
        let copy = await Self.runProcess("/usr/bin/ditto", [sourceApp, destURL.path], timeout: 300)
        guard copy.exitCode == 0 else {
            try? fm.moveItem(at: asideURL, to: destURL)
            throw AppUpdateError.installFailed("写入新版本失败: \(String(copy.output.prefix(160)))")
        }
        try? fm.removeItem(at: asideURL)

        _ = await Self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"], timeout: 30)
        // -n: the old instance is still alive for a moment, a plain `open`
        // would just re-activate it instead of starting the new bundle.
        _ = await Self.runProcess("/usr/bin/open", ["-n", destURL.path], timeout: 15)
        exit(0)
    }

    // MARK: - Process helper

    /// Runs a short-lived system tool and captures merged stdout/stderr.
    /// Polls with a deadline (the ASCAPIClient pattern) so a wedged helper
    /// can't hang an update forever.
    private static func runProcess(_ path: String,
                                   _ arguments: [String],
                                   timeout: TimeInterval) async -> (exitCode: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (Int32(-1), "无法启动 \(path): \(error.localizedDescription)")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return (process.terminationStatus, "执行超时(\(Int(timeout))s)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}
