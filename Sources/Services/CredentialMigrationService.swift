import CommonCrypto
import CryptoKit
import Foundation

enum CredentialMigrationError: LocalizedError, Equatable {
    case noConfiguredCredentials
    case passphraseTooShort
    case passphraseMismatch
    case wrongPassphrase
    case badFormat(String)
    case unsupportedVersion(Int)
    case keychainWriteFailed([Credential])

    var errorDescription: String? {
        switch self {
        case .noConfiguredCredentials:
            "本机没有已配置的凭据,无可导出"
        case .passphraseTooShort:
            "口令至少需要 8 个字符"
        case .passphraseMismatch:
            "两次输入的口令不一致"
        case .wrongPassphrase:
            "口令错误或文件已损坏 — 请核对迁移文件口令"
        case .badFormat(let detail):
            "不是有效的迁移文件: \(detail)"
        case .unsupportedVersion(let version):
            "迁移文件版本 (v\(version)) 高于本应用支持,请先升级应用"
        case .keychainWriteFailed(let failed):
            "部分凭据写入钥匙串失败: \(failed.map(\.label).joined(separator: "、"))"
        }
    }
}

/// Exports the keychain credentials into a passphrase-encrypted file and
/// imports it back — the migration path for a new Mac or a clean reinstall,
/// where `.p8` files and Match passwords would otherwise need manual re-entry.
///
/// File shape: a plaintext header (format/version/KDF parameters) plus an
/// AES-256-GCM sealed payload. The key comes from PBKDF2-HMAC-SHA256 over
/// the user passphrase with a per-export random salt — slow by design, so a
/// stolen file can't be brute-forced cheaply.
enum CredentialMigrationService {
    static let formatIdentifier = "vibeforge.credential-export"
    static let currentVersion = 1
    static let defaultIterations: UInt32 = 600_000
    static let minimumPassphraseLength = 8

    /// The decrypted contents of a migration file.
    struct MigrationPayload: Codable, Equatable {
        var exportedAt: Date
        var appVersion: String
        /// Keyed by `Credential.rawValue` for JSON stability across enum
        /// renames; unknown keys are ignored on import.
        var credentials: [String: String]

        init(credentials: [Credential: String], exportedAt: Date = Date()) {
            self.exportedAt = exportedAt
            self.appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                               as? String) ?? ""
            self.credentials = credentials.reduce(into: [:]) { result, pair in
                result[pair.key.rawValue] = pair.value
            }
        }

        var credentialPairs: [Credential: String] {
            credentials.reduce(into: [:]) { result, pair in
                if let credential = Credential(rawValue: pair.key) {
                    result[credential] = pair.value
                }
            }
        }
    }

    // MARK: - Container format

    private struct Container: Codable {
        var format: String
        var version: Int
        var kdf: KDF
        var cipher: Cipher

        struct KDF: Codable {
            var algorithm: String
            var iterations: UInt32
            var salt: String       // base64
        }

        struct Cipher: Codable {
            var algorithm: String
            var nonce: String      // base64
            var ciphertext: String // base64, GCM combined (tag appended)
        }
    }

    static func exportContainer(credentials: [Credential: String],
                                passphrase: String,
                                date: Date = Date()) throws -> Data {
        let nonEmpty = credentials.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { throw CredentialMigrationError.noConfiguredCredentials }
        guard passphrase.count >= minimumPassphraseLength else { throw CredentialMigrationError.passphraseTooShort }

        let salt = randomBytes(16)
        let nonce = randomBytes(12)
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: defaultIterations)

        let payload = try JSONEncoder().encode(MigrationPayload(credentials: nonEmpty, exportedAt: date))
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(payload, using: key, nonce: gcmNonce)
        guard let combined = sealed.combined else {
            throw CredentialMigrationError.badFormat("加密失败")
        }

        let container = Container(
            format: formatIdentifier,
            version: currentVersion,
            kdf: .init(algorithm: "PBKDF2-HMAC-SHA256",
                       iterations: defaultIterations,
                       salt: salt.base64EncodedString()),
            cipher: .init(algorithm: "AES-256-GCM",
                          nonce: nonce.base64EncodedString(),
                          ciphertext: combined.base64EncodedString()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(container)
    }

    static func decryptContainer(_ data: Data, passphrase: String) throws -> MigrationPayload {
        let container: Container
        do {
            container = try JSONDecoder().decode(Container.self, from: data)
        } catch {
            throw CredentialMigrationError.badFormat("结构无法解析")
        }
        guard container.format == formatIdentifier else {
            throw CredentialMigrationError.badFormat("缺少格式标识")
        }
        guard container.version <= currentVersion else {
            throw CredentialMigrationError.unsupportedVersion(container.version)
        }
        guard container.kdf.algorithm == "PBKDF2-HMAC-SHA256",
              let salt = Data(base64Encoded: container.kdf.salt),
              Data(base64Encoded: container.cipher.nonce) != nil,
              let ciphertext = Data(base64Encoded: container.cipher.ciphertext) else {
            throw CredentialMigrationError.badFormat("加密参数缺失或非法")
        }

        // Iterations come from the file so older exports stay readable after
        // the default rises — but bound it so a hostile file can't request a
        // denial-of-service derivation.
        let iterations = min(max(container.kdf.iterations, 1), 10_000_000)
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            // combined = nonce || ciphertext || tag, so open() needs no
            // explicit nonce — it's carried inside the sealed box.
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let payload = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(MigrationPayload.self, from: payload)
        } catch {
            // A failed GCM authentication is the wrong passphrase in the
            // overwhelmingly common case; corrupted files land here too.
            throw CredentialMigrationError.wrongPassphrase
        }
    }

    // MARK: - Crypto

    /// PBKDF2-HMAC-SHA256 → 256-bit key. Exposed for the RFC test vector.
    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var derived = Data(repeating: 0, count: 32)
        let passphraseBytes = Array(Data(passphrase.utf8))
        derived.withUnsafeMutableBytes { derivedRaw in
            salt.withUnsafeBytes { saltRaw in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphraseBytes.map { CChar(bitPattern: $0) }, passphraseBytes.count,
                    saltRaw.bindMemory(to: UInt8.self).baseAddress, saltRaw.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    derivedRaw.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Keychain bridge

    /// Snapshot of everything currently stored (empty values skipped).
    static func readConfiguredCredentials() -> [Credential: String] {
        Credential.allCases.reduce(into: [:]) { result, credential in
            guard let value = KeychainStore.get(credential),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result[credential] = value
        }
    }

    /// Write imported credentials into the keychain. With `skipExisting`,
    /// fields that already have a local value are left untouched. Returns
    /// the credentials actually written; a failed write aborts the error
    /// path with whatever couldn't be stored.
    static func apply(_ credentials: [Credential: String], skipExisting: Bool) throws -> [Credential] {
        var written: [Credential] = []
        var failed: [Credential] = []
        for (credential, value) in credentials {
            if skipExisting && KeychainStore.exists(credential) { continue }
            if KeychainStore.set(value, for: credential) {
                written.append(credential)
            } else {
                failed.append(credential)
            }
        }
        if !failed.isEmpty { throw CredentialMigrationError.keychainWriteFailed(failed) }
        return written
    }

    /// Suggested export filename, e.g. `vibeforge-credentials-20260816-1030.json`.
    static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "vibeforge-credentials-\(formatter.string(from: date)).json"
    }
}
