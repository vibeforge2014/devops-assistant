import Foundation

/// Receives every line appended to a runner's console, so a run can be
/// mirrored somewhere else (e.g. to disk) without the console caring where.
protocol LogSink: AnyObject {
    func append(_ text: String)
}

/// Appends lines to a log file. Console lines arrive on the main actor; the
/// file I/O runs on a private serial queue so streaming build output never
/// blocks the UI.
final class FileLogSink: LogSink {
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.vibeforge.devops-assistant.logsink")

    /// Opens `url` for writing, creating it when `create` (a fresh run) or
    /// seeking to the end when appending (a retry continuing the same run).
    init?(url: URL, append: Bool) {
        if !append, !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600]) {
            return nil
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        if append { handle.seekToEndOfFile() }
        self.handle = handle
        self.url = url
    }

    func append(_ text: String) {
        let data = Data((text + "\n").utf8)
        queue.async { [handle] in
            try? handle.write(contentsOf: data)
        }
    }

    deinit {
        // Flush any queued writes before the handle goes away.
        queue.sync {}
        try? handle.close()
    }
}

/// Release-run logs on disk, so "why did yesterday's release fail?" has an
/// answer even after the in-memory console is gone (app quit, next run).
/// Layout: `<appSupport>/com.vibeforge.devops-assistant/logs/<appID>/<run>.log`
enum RunLogStore {
    /// Delete oldest logs once the folder grows past this (xcodebuild logs
    /// are big; retention keeps the app support dir bounded).
    static let retentionLimitBytes: Int64 = 100 * 1024 * 1024

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func defaultBaseDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("com.vibeforge.devops-assistant", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// A fresh log file for a new release run, e.g.
    /// `logs/tivon/20260815-103000-testFlight.log`.
    static func makeSink(appID: String, target: String,
                         date: Date = Date(),
                         baseDirectory: URL? = nil) -> FileLogSink? {
        let dir = (baseDirectory ?? defaultBaseDirectory())
            .appendingPathComponent(appID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let stem = "\(stampFormatter.string(from: date))-\(target)"
        var url = dir.appendingPathComponent("\(stem).log")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(suffix).log")
            suffix += 1
        }
        return FileLogSink(url: url, append: false)
    }

    /// Delete oldest log files (by modification date) until the total size
    /// is under `limit`. Best-effort: unreadable files are ignored.
    static func enforceRetention(limit: Int64 = retentionLimitBytes,
                                 in baseDirectory: URL? = nil) {
        let fm = FileManager.default
        let base = baseDirectory ?? defaultBaseDirectory()
        guard let appDirs = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles) else { return }

        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for dir in appDirs {
            guard let logs = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: .skipsHiddenFiles) else { continue }
            for log in logs {
                guard let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      let modified = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                files.append((log, Int64(size), modified))
                total += Int64(size)
            }
        }
        guard total > limit else { return }

        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
