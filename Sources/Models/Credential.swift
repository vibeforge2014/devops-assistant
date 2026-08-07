import Foundation

/// Credential kinds the assistant stores in the macOS Keychain, centralizing
/// what is otherwise scattered across env files and disk.
enum Credential: String, CaseIterable {
    case ascAPIKeyContent = "asc_api_key_content"   // .p8 body (PEM) for a key id
    case ascAPIKeyID = "asc_api_key_id"             // e.g. D42XZ6D6LX
    case ascIssuerID = "asc_issuer_id"
    case matchPassword = "match_password"
    case matchGitURL = "match_git_url"
    case appleTeamID = "apple_team_id"
    case appleID = "apple_id"                       // Apple ID account
    case appSpecificPassword = "app_specific_password" // app-specific password

    /// The keychain account string (prefixed to avoid collisions).
    var account: String { "vibeforge.devops.\(rawValue)" }

    var label: String {
        switch self {
        case .ascAPIKeyContent: "App Store Connect API Key (.p8 内容)"
        case .ascAPIKeyID: "API Key ID"
        case .ascIssuerID: "Issuer ID"
        case .matchPassword: "Match 仓库密码"
        case .matchGitURL: "Match 仓库地址"
        case .appleTeamID: "Apple Team ID"
        case .appleID: "Apple ID"
        case .appSpecificPassword: "App 专用密码"
        }
    }
}

/// A discrete step in a release flow, used by ReleaseFlow to render a wizard
/// and by the runner to sequence commands.
enum ReleaseStep: String, CaseIterable, Identifiable {
    case setVersion    // set/bump MARKETING_VERSION + CURRENT_PROJECT_VERSION
    case build         // xcodegen + xcodebuild archive
    case sign          // match / sigh / Developer ID signing
    case notarize      // macOS only: notarytool submit + staple
    case uploadBeta    // TestFlight (fastlane beta / pilot)
    case uploadRelease // App Store (fastlane release / deliver)
    case updatePages   // sync version info to GitHub Pages site + portal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setVersion: "设置版本号"
        case .build: "构建打包"
        case .sign: "签名"
        case .notarize: "Apple 公证"
        case .uploadBeta: "上传 TestFlight"
        case .uploadRelease: "上传 App Store"
        case .updatePages: "更新发布页"
        }
    }

    var systemImage: String {
        switch self {
        case .setVersion: "number.circle"
        case .build: "hammer"
        case .sign: "checkmark.seal"
        case .notarize: "shield.lefthalf.filled"
        case .uploadBeta: "paperplane"
        case .uploadRelease: "shippingbox"
        case .updatePages: "globe"
        }
    }
}
