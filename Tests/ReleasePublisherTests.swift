import XCTest
import CryptoKit

@MainActor
final class ReleasePublisherTests: XCTestCase {

    // MARK: - GitHub slug parsing (drives whether the publish step runs at all)

    func testGithubSlugParsesSSHAndHTTPS() {
        XCTAssertEqual(AppProject.githubSlug(from: "git@github.com:vibeforge2014/devops-assistant.git"),
                       "vibeforge2014/devops-assistant")
        XCTAssertEqual(AppProject.githubSlug(from: "https://github.com/vibeforge2014/devops-assistant.git"),
                       "vibeforge2014/devops-assistant")
        XCTAssertEqual(AppProject.githubSlug(from: "https://github.com/vibeforge2014/devops-assistant"),
                       "vibeforge2014/devops-assistant")
    }

    func testGithubSlugRejectsNonGitHub() {
        // Self-hosted GitLab / Bitbucket must never be mis-published as GitHub.
        XCTAssertNil(AppProject.githubSlug(from: "https://zqian24.synology.me:8010/root/devops-assistant.git"))
        XCTAssertNil(AppProject.githubSlug(from: "git@gitlab.com:foo/bar.git"))
        XCTAssertNil(AppProject.githubSlug(from: ""))
    }

    func testReleaseRepoSlugOnAppProject() {
        let app = makeApp(repo: "git@github.com:vibeforge2014/devops-assistant.git")
        XCTAssertEqual(app.releaseRepoSlug, "vibeforge2014/devops-assistant")

        let nonGithub = makeApp(repo: "https://zqian24.synology.me:8010/root/devops-assistant.git")
        XCTAssertNil(nonGithub.releaseRepoSlug)
    }

    // MARK: - ES256 JWT (replaces deprecated `xcrun altool --generate-jwt`)

    func testES256JWTFromValidP256KeyHasThreeSegments() throws {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let jwt = CredentialValidationService.makeES256JWT(
            keyContent: pem, keyID: "ABCDEFGHIJ", issuerID: UUID().uuidString)
        XCTAssertNotNil(jwt)
        let segments = jwt?.split(separator: ".").map(String.init)
        XCTAssertEqual(segments?.count, 3)
        // Header decodes to alg=ES256, typ=JWT.
        if let header = segments?.first,
           let data = Data(base64URLEncoded: header),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            XCTAssertEqual(json["alg"], "ES256")
            XCTAssertEqual(json["typ"], "JWT")
        } else {
            XCTFail("header segment did not decode")
        }
    }

    func testES256JWTRejectsGarbageKey() {
        XCTAssertNil(CredentialValidationService.makeES256JWT(
            keyContent: "not a key", keyID: "ABCDEFGHIJ", issuerID: "issuer"))
        XCTAssertNil(CredentialValidationService.makeES256JWT(
            keyContent: "", keyID: "ABCDEFGHIJ", issuerID: "issuer"))
    }

    // MARK: - Release notes

    func testNotesEmbedVersionAndSHA() throws {
        let dmg = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeforge-notes-\(UUID().uuidString).dmg")
        try Data(count: 1_500_000).write(to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }

        let app = makeApp(name: "DevOps Assistant", repo: "git@github.com:vibeforge2014/devops-assistant.git")
        let notes = ReleasePublisher.notes(app: app,
                                            version: VersionPair(marketing: "1.3.0", build: "5"),
                                            dmgPath: dmg.path,
                                            sha: "deadbeef")
        XCTAssertTrue(notes.contains("1.3.0"))
        XCTAssertTrue(notes.contains("build 5"))
        XCTAssertTrue(notes.contains("deadbeef"))
        XCTAssertTrue(notes.contains("DevOps Assistant"))
    }

    // MARK: - Helpers

    private func makeApp(id: String = "devops-assistant",
                         name: String = "DevOps Assistant",
                         repo: String = "git@github.com:vibeforge2014/devops-assistant.git") -> AppProject {
        AppProject(id: id, name: name, path: "/tmp/missing", repositoryURL: repo,
                   platform: .macos, scheme: "DevOpsAssistant", bundleId: "com.vibeforge.test",
                   versionSource: .projectYml,
                   release: ReleaseConfig(engine: .native, signing: .developerID, notarize: true))
    }
}

/// Minimal Base64URL decoding for header assertions.
private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
