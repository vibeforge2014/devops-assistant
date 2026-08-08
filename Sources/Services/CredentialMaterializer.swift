import Foundation

/// A short-lived on-disk representation of the ASC private key. Some Apple
/// tools only accept a file path; the directory is removed on deinit.
final class TemporaryAPIKey {
    let keyID: String
    let issuerID: String
    let url: URL
    private let directory: URL

    init?() {
        guard let content = KeychainStore.get(.ascAPIKeyContent),
              let keyID = KeychainStore.get(.ascAPIKeyID),
              let issuerID = KeychainStore.get(.ascIssuerID),
              !content.isEmpty, !keyID.isEmpty, !issuerID.isEmpty else { return nil }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("vibeforge-asc-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("AuthKey_\(keyID).p8")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            try Data(content.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: directory)
            return nil
        }
        self.keyID = keyID
        self.issuerID = issuerID
        self.url = url
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
