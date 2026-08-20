import Foundation

/// Persists release history as JSON under the app's Application Support dir.
/// This is the assistant's first piece of mutable on-disk state (everything
/// else writes into the user's project repos), so it mirrors `ProjectCatalog`'s
/// defensive style: a missing/corrupt file degrades to an empty list rather
/// than crashing, and writes are atomic.
///
/// Capacity is capped (`maxRecords`) so an active matrix can't grow the file
/// without bound; the oldest entries are trimmed first.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [ReleaseRecord] = []

    /// Keep at most this many records (most recent first after sort).
    static let maxRecords = 200

    private let fileURL: URL

    convenience init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("com.vibeforge.devops-assistant", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("history.json", isDirectory: false))
    }

    /// Injectable path keeps persistence tests isolated from the user's real
    /// history file.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Load / save

    /// Load history from disk. A missing file (first launch) or a decode
    /// failure leaves an empty list — the app never blocks launch on history.
    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([ReleaseRecord].self, from: data)
        } catch {
            #if DEBUG
            print("[HistoryStore] failed to decode history.json: \(error)")
            #endif
        }
    }

    /// Append a record, trim to the cap, and persist. Newest entries sort first.
    func append(_ record: ReleaseRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    /// Filter to records for one app (empty id = all). Newest first.
    func records(forAppID id: String) -> [ReleaseRecord] {
        id.isEmpty ? records : records.filter { $0.appID == id }
    }

    /// Remove all history (used by a "clear" affordance).
    func clear() {
        records.removeAll()
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
