import Foundation
import Security

/// Thin wrapper over macOS Keychain Services for storing the scattered Apple
/// release credentials (ASC API key, issuer id, match password, …) in one
/// trusted location. All items live under a shared service prefix so they're
/// easy to audit and clear.
struct KeychainStore {
    /// All items share this service prefix.
    static let service = "com.vibeforge.devops-assistant"

    // MARK: - CRUD

    /// Save a credential value, overwriting any existing one.
    @discardableResult
    static func set(_ value: String, for credential: Credential) -> Bool {
        let data = Data(value.utf8)
        // Delete first to avoid errSecDuplicateItem.
        delete(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read a credential value, or nil if absent.
    static func get(_ credential: Credential) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a credential value if present.
    @discardableResult
    static func delete(_ credential: Credential) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether a credential is currently stored with a non-empty value.
    /// An empty string written earlier (a bug) no longer counts as configured.
    static func exists(_ credential: Credential) -> Bool {
        guard let value = get(credential) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
