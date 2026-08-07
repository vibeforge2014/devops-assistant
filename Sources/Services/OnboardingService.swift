import Foundation

/// One credential's discovery status during onboarding.
struct CredentialStatus {
    let credential: Credential
    /// Where the value was found, for display ("已从 ~/.appstoreconnect 导入").
    let source: String?
    /// The discovered value (written to keychain on import). Nil if not found.
    let value: String?

    var isFound: Bool { value != nil }
    var wasAlreadyStored: Bool { KeychainStore.exists(credential) }
}

/// Probes the machine for credentials that already exist (on disk, in project
/// config, in the keychain) so first-run onboarding can auto-import them
/// instead of asking the user to re-enter everything.
///
/// Sources probed:
///   - ASC API Key (.p8 files in ~/.appstoreconnect/private_keys/)
///   - Team ID (hardcoded in aptv-ios/fastlane/Appfile)
///   - Match repo URL (Matchfile git_url across projects)
///
/// Issuer ID and match password are NOT on disk in the clear; those stay
/// manual until the user enters them.
struct OnboardingService {

    /// Probe all credentials, returning a status per credential plus the list
    /// of discovered API keys (there can be more than one).
    static func probeAll() -> (statuses: [Credential], apiKeys: [DiscoveredAPIKey]) {
        // Discover API key files first — the first one's id populates the
        // ascAPIKeyID field if nothing is stored yet.
        let keys = discoverAPIKeys()
        let teamID = probeTeamID()
        let matchURL = probeMatchURL()

        var statuses: [Credential] = []
        statuses.append(.ascAPIKeyContent)
        statuses.append(.ascAPIKeyID)
        statuses.append(.ascIssuerID)
        statuses.append(.matchPassword)
        statuses.append(.matchGitURL)
        statuses.append(.appleTeamID)
        return (statuses, keys)
    }

    /// A .p8 file discovered on disk.
    struct DiscoveredAPIKey {
        let keyID: String
        let path: String
        let content: String
    }

    /// Scan ~/.appstoreconnect/private_keys/ for AuthKey_<KEYID>.p8 files.
    static func discoverAPIKeys() -> [DiscoveredAPIKey] {
        let dir = "\(NSHomeDirectory())/.appstoreconnect/private_keys"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return entries.compactMap { name in
            // Match AuthKey_<KEYID>.p8
            guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else { return nil }
            let keyID = String(name.dropFirst("AuthKey_".length).dropLast(".p8".length))
            let path = "\(dir)/\(name)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return DiscoveredAPIKey(keyID: keyID, path: path, content: content)
        }
    }

    /// Probe the Apple Team ID from the aptv Appfile (it's hardcoded there).
    static func probeTeamID() -> String? {
        let appfile = "\(NSHomeDirectory())/Desktop/aptv-ios/fastlane/Appfile"
        guard let text = try? String(contentsOfFile: appfile, encoding: .utf8) else { return nil }
        // Look for team_id("XXXXXX")
        if let r = text.range(of: #"team_id\("([A-Z0-9]{10})"\)"#, options: .regularExpression) {
            let match = String(text[r])
            // Extract the ID between quotes.
            if let open = match.firstIndex(of: "\""),
               let close = match.lastIndex(of: "\""), open < close {
                return String(match[match.index(after: open)..<close])
            }
        }
        return "LPW4Z3BN69" // known default for this account
    }

    /// Probe the match repo URL from project Matchfiles.
    static func probeMatchURL() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/Desktop/aptv-ios/fastlane/Matchfile",
            "\(NSHomeDirectory())/Desktop/atvtool/fastlane/Matchfile",
            "\(NSHomeDirectory())/Desktop/ServerCat-iOS/fastlane/Matchfile",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            // Look for git_url("...") with a real (non-CHANGEME) url.
            if let r = text.range(of: #"git_url\("(git@[^"]+)"\)"#, options: .regularExpression) {
                let match = String(text[r])
                if let open = match.firstIndex(of: "\""),
                   let close = match.lastIndex(of: "\""), open < close {
                    let url = String(match[match.index(after: open)..<close])
                    if !url.contains("CHANGEME") { return url }
                }
            }
        }
        return nil
    }

    /// Auto-import all discoverable credentials into the keychain. Returns a
    /// summary of what was imported. Skips items already stored.
    @discardableResult
    static func autoImport() -> ImportSummary {
        var summary = ImportSummary()

        // Already configured? Skip entirely.
        if isFullyConfigured {
            summary.skipped = "凭据已全部配置"
            return summary
        }

        let keys = discoverAPIKeys()
        if let first = keys.first {
            if KeychainStore.set(first.content, for: .ascAPIKeyContent) {
                summary.imported.append("API Key \(first.keyID)(.p8 内容)")
            }
            if KeychainStore.set(first.keyID, for: .ascAPIKeyID) {
                summary.imported.append("API Key ID: \(first.keyID)")
            }
            summary.discoveredKeyCount = keys.count
        }

        if let teamID = probeTeamID(), KeychainStore.set(teamID, for: .appleTeamID) {
            summary.imported.append("Team ID: \(teamID)")
        }

        if let url = probeMatchURL(), KeychainStore.set(url, for: .matchGitURL) {
            summary.imported.append("Match 仓库: \(url)")
        }

        // Issuer ID and match password can't be auto-discovered.
        summary.missing = missingItems
        return summary
    }

    /// The credentials still not stored after import (need manual entry).
    static var missingItems: [String] {
        var missing: [String] = []
        if !KeychainStore.exists(.ascIssuerID) { missing.append("Issuer ID") }
        if !KeychainStore.exists(.matchPassword) { missing.append("Match 密码") }
        if !KeychainStore.exists(.ascAPIKeyContent) { missing.append("ASC API Key") }
        if !KeychainStore.exists(.appleTeamID) { missing.append("Team ID") }
        return missing
    }

    /// Whether the essential credentials are present. Auth works if EITHER an
    /// ASC API Key (content + id + issuer) OR Apple ID + app-specific password
    /// is configured. Team ID is always required.
    static var isFullyConfigured: Bool {
        guard KeychainStore.exists(.appleTeamID) else { return false }
        let hasAPIKey = KeychainStore.exists(.ascAPIKeyContent)
            && KeychainStore.exists(.ascAPIKeyID)
            && KeychainStore.exists(.ascIssuerID)
        let hasAppleID = KeychainStore.exists(.appleID)
            && KeychainStore.exists(.appSpecificPassword)
        return hasAPIKey || hasAppleID
    }

    struct ImportSummary {
        var imported: [String] = []
        var missing: [String] = []
        var discoveredKeyCount: Int = 0
        var skipped: String?
    }
}

private extension String {
    var length: Int { count }
}
