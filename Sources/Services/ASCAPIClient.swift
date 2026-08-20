import Foundation

enum ASCAPIError: LocalizedError, Equatable {
    case credentialsMissing
    case tokenGenerationFailed
    case transport(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "App Store Connect API 凭据未配置 — 请到「凭据设置」导入 .p8 并填写 Key ID / Issuer ID"
        case .tokenGenerationFailed:
            return "无法生成 App Store Connect 认证令牌 — 确认 Key ID 与 .p8 匹配"
        case .transport(let detail):
            return "网络请求失败(代理/断网/超时): \(detail)"
        case .http(let code, let body):
            let snippet = String(body.prefix(160)).replacingOccurrences(of: "\n", with: " ")
            return "App Store Connect 请求失败 (HTTP \(code)) \(snippet)"
        }
    }
}

/// Minimal App Store Connect API reader: JWT via the proven
/// `xcrun altool --generate-jwt` subprocess (the same flow
/// `CredentialValidationService` validates against), then plain GETs via
/// URLSession — the app's first direct HTTP client. Tokens are cached for
/// 15 of their 20 valid minutes.
///
/// Reads only. Nothing in this client can change App Store Connect state.
final class ASCAPIClient: @unchecked Sendable {
    static let shared = ASCAPIClient()

    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!
    /// This machine reaches Apple through a slow proxy — observed latencies
    /// well past 30s — so be generous before declaring failure.
    private let timeout: TimeInterval = 60
    private let tokenTTL: TimeInterval = 15 * 60

    private var cachedToken: String?
    private var tokenFetchedAt: Date?
    /// Single-flight token generation: concurrent cold requests share one
    /// altool subprocess instead of spawning N of them through the proxy.
    private var inFlightToken: Task<String, Error>?
    private let lock = NSLock()

    /// GET `pathAndQuery` (e.g. "v1/apps?filter%5BbundleId%5D=x&limit=1" —
    /// query already percent-encoded by the caller), return the body. A 401
    /// refreshes the token once and retries.
    func get(_ pathAndQuery: String) async throws -> Data {
        // appendingPathComponent would escape "?" to %3F — assemble with
        // URLComponents so path and pre-encoded query stay intact.
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1).map(String.init)
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(parts[0]),
                                        resolvingAgainstBaseURL: false) else {
            throw ASCAPIError.http(-1, "无效请求路径")
        }
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        guard let url = comps.url else {
            throw ASCAPIError.http(-1, "无效请求路径")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await token())",
                         forHTTPHeaderField: "Authorization")
        do {
            return try await execute(request)
        } catch ASCAPIError.http(401, _) {
            clearToken()
            request.setValue("Bearer \(try await token())",
                             forHTTPHeaderField: "Authorization")
            return try await execute(request)
        }
    }

    // MARK: - Token

    private func token() async throws -> String {
        lock.lock()
        let existing = cachedToken
        let age = tokenFetchedAt.map { Date().timeIntervalSince($0) }
        let shared = inFlightToken
        lock.unlock()
        if let existing, let age, age < tokenTTL { return existing }
        // Another request is already generating a token — ride along.
        if let shared { return try await shared.value }

        let generation = Task<String, Error> {
            // Keychain reads and the token subprocess stay off the main thread.
            let key = await Task.detached(priority: .userInitiated) {
                TemporaryAPIKey()
            }.value
            guard let key else { throw ASCAPIError.credentialsMissing }

            let generated = await Task.detached(priority: .userInitiated) {
                Self.generateJWT(keyFile: key.url.path, keyID: key.keyID, issuerID: key.issuerID)
            }.value
            guard let token = generated else { throw ASCAPIError.tokenGenerationFailed }
            return token
        }
        lock.lock()
        inFlightToken = generation
        lock.unlock()
        do {
            let token = try await generation.value
            lock.lock()
            cachedToken = token
            tokenFetchedAt = Date()
            inFlightToken = nil
            lock.unlock()
            return token
        } catch {
            lock.lock()
            inFlightToken = nil
            lock.unlock()
            throw error
        }
    }

    private func clearToken() {
        lock.lock()
        cachedToken = nil
        tokenFetchedAt = nil
        lock.unlock()
    }

    /// Runs `xcrun altool --generate-jwt` and extracts the token from its
    /// mixed explanatory/JWT output. Same extraction rule as
    /// `CredentialValidationService`: a JWT is exactly three non-empty
    /// Base64URL segments.
    private static func generateJWT(keyFile: String, keyID: String, issuerID: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["altool", "--generate-jwt",
                             "--apiKey", keyID, "--apiIssuer", issuerID,
                             "--p8-file-path", keyFile]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        // Poll for completion with a timeout: JWT generation is fast, but a
        // wedged xcrun must not hang the caller forever.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first { candidate in
                let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
                guard segments.count == 3 else { return false }
                return segments.allSatisfy { segment in
                    !segment.isEmpty && segment.allSatisfy { character in
                        character.isLetter || character.isNumber || character == "-" || character == "_"
                    }
                }
            }
    }

    // MARK: - HTTP

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transport failures (offline, proxy down, timeouts) get their own
            // case — callers retry or report them differently from HTTP 4xx/5xx.
            throw ASCAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ASCAPIError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ASCAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
