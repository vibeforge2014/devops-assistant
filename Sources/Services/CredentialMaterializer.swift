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
            try Data(Self.normalizedPEM(content).utf8).write(to: url, options: .atomic)
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

    /// The keychain value is normally the PEM text itself, but some import
    /// paths have stored it hex-encoded (observed on this machine: the raw
    /// item is "2d2d2d2d…" decoding to "-----BEGIN PRIVATE KEY-----").
    /// Writing that verbatim produces a .p8 no tool can load — normalize to
    /// a PEM block either way.
    static func normalizedPEM(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN") { return trimmed + "\n" }
        guard !trimmed.isEmpty, trimmed.count % 2 == 0,
              trimmed.allSatisfy({ $0.isHexDigit }) else { return trimmed }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var iterator = trimmed.makeIterator()
        while let hi = iterator.next(), let lo = iterator.next() {
            guard let hiVal = UInt8(String(hi), radix: 16),
                  let loVal = UInt8(String(lo), radix: 16) else { return trimmed }
            bytes.append(hiVal << 4 | loVal)
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8),
              decoded.hasPrefix("-----BEGIN") else { return trimmed }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
