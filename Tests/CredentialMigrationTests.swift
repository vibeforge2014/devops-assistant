import CryptoKit
import XCTest

final class CredentialMigrationTests: XCTestCase {
    private let sample: [Credential: String] = [
        .ascAPIKeyID: "496SRK4K68",
        .ascIssuerID: "a307ff7b-774c-4ef6-98c4-8031876fa556",
        .appleTeamID: "LPW4Z3BN69",
        .matchPassword: "s3cret-passphrase",
    ]

    private func hexString(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: - PBKDF2

    func testPBKDF2MatchesKnownAnswerVector() {
        // PBKDF2-HMAC-SHA256, P="password", S="salt", c=1, dkLen=32.
        let key = CredentialMigrationService.deriveKey(
            passphrase: "password", salt: Data("salt".utf8), iterations: 1)
        XCTAssertEqual(hexString(key),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testPBKDF2IsDeterministicPerSalt() {
        let salt = Data(repeating: 0xAB, count: 16)
        let a = CredentialMigrationService.deriveKey(passphrase: "口令", salt: salt, iterations: 1000)
        let b = CredentialMigrationService.deriveKey(passphrase: "口令", salt: salt, iterations: 1000)
        XCTAssertEqual(hexString(a), hexString(b))
        let c = CredentialMigrationService.deriveKey(passphrase: "口令2", salt: salt, iterations: 1000)
        XCTAssertNotEqual(hexString(a), hexString(c))
    }

    // MARK: - Container roundtrip

    func testExportDecryptRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let data = try CredentialMigrationService.exportContainer(
            credentials: sample, passphrase: "correct-horse", date: date)
        let payload = try CredentialMigrationService.decryptContainer(data, passphrase: "correct-horse")
        XCTAssertEqual(payload.credentialPairs, sample)
        XCTAssertEqual(payload.exportedAt, date)
    }

    func testTwoExportsDifferRandomizedSaltAndNonce() throws {
        let a = try CredentialMigrationService.exportContainer(credentials: sample, passphrase: "correct-horse")
        let b = try CredentialMigrationService.exportContainer(credentials: sample, passphrase: "correct-horse")
        XCTAssertNotEqual(a, b)
        // Both still decrypt to the same contents.
        XCTAssertEqual(
            try CredentialMigrationService.decryptContainer(a, passphrase: "correct-horse").credentialPairs,
            try CredentialMigrationService.decryptContainer(b, passphrase: "correct-horse").credentialPairs)
    }

    // MARK: - Failure modes

    func testWrongPassphraseThrows() throws {
        let data = try CredentialMigrationService.exportContainer(credentials: sample, passphrase: "correct-horse")
        XCTAssertThrowsError(try CredentialMigrationService.decryptContainer(data, passphrase: "wrong-horse")) { error in
            XCTAssertEqual(error as? CredentialMigrationError, .wrongPassphrase)
        }
    }

    func testTamperedCiphertextFailsAuthentication() throws {
        let data = try CredentialMigrationService.exportContainer(credentials: sample, passphrase: "correct-horse")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var cipher = try XCTUnwrap(json["cipher"] as? [String: Any])
        let ciphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(cipher["ciphertext"] as? String)))
        var bytes = [UInt8](ciphertext)
        bytes[bytes.count / 2] ^= 0xFF // flip one bit in the middle
        cipher["ciphertext"] = Data(bytes).base64EncodedString()
        json["cipher"] = cipher
        let tampered = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try CredentialMigrationService.decryptContainer(tampered, passphrase: "correct-horse")) { error in
            XCTAssertEqual(error as? CredentialMigrationError, .wrongPassphrase)
        }
    }

    func testEmptyCredentialsRejected() {
        XCTAssertThrowsError(try CredentialMigrationService.exportContainer(
            credentials: [:], passphrase: "correct-horse")) { error in
            XCTAssertEqual(error as? CredentialMigrationError, .noConfiguredCredentials)
        }
    }

    func testWhitespaceOnlyCredentialsRejected() {
        XCTAssertThrowsError(try CredentialMigrationService.exportContainer(
            credentials: [.appleTeamID: "   "], passphrase: "correct-horse")) { error in
            XCTAssertEqual(error as? CredentialMigrationError, .noConfiguredCredentials)
        }
    }

    func testShortPassphraseRejected() {
        XCTAssertThrowsError(try CredentialMigrationService.exportContainer(
            credentials: sample, passphrase: "short")) { error in
            XCTAssertEqual(error as? CredentialMigrationError, .passphraseTooShort)
        }
    }

    func testFutureVersionRejectedButUnknownCredentialKeysIgnored() throws {
        // Bump the container's version — an export from a newer app must
        // produce a clear upgrade prompt, not a cryptic failure.
        let data = try CredentialMigrationService.exportContainer(credentials: sample, passphrase: "correct-horse")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 99
        let future = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try CredentialMigrationService.decryptContainer(future, passphrase: "correct-horse")) { error in
            XCTAssertEqual(error as? CredentialMigrationError, .unsupportedVersion(99))
        }
    }

    func testGarbageInputReportsBadFormat() {
        XCTAssertThrowsError(try CredentialMigrationService.decryptContainer(
            Data("not json at all".utf8), passphrase: "correct-horse")) { error in
            guard case .badFormat = error as? CredentialMigrationError else {
                return XCTFail("expected badFormat, got \(error)")
            }
        }
    }

    func testPayloadIgnoresUnknownCredentialKeys() throws {
        var payload = CredentialMigrationService.MigrationPayload(credentials: sample)
        payload.credentials["future_credential_kind"] = "ignored"
        XCTAssertEqual(payload.credentialPairs, sample)
    }
}
