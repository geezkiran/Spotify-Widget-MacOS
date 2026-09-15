import AppKit
import AuthenticationServices
import CryptoKit
import os

/// The user's Spotify account via the Web API: sign-in (PKCE) and Liked Songs.
/// Playback stays on AppleScript, whose dictionary can't save tracks.
@MainActor
final class SpotifyAccount: ObservableObject {
    private static let clientID = "c73a5b6bf7df480bb07d1ad126de7ae9"
    private static let callbackScheme = "spotifywidget"
    private static let redirectURI = "\(callbackScheme)://callback"
    // The consolidated /me/library endpoints list the follow scopes as required too.
    private static let scopes = ["user-library-read", "user-library-modify", "user-follow-read", "user-follow-modify"]
    private static let log = Logger(subsystem: "com.kiran.spotifywidget", category: "account")

    @Published private(set) var isConnected: Bool
    @Published private(set) var lastError: String?

    /// Called when the connection changes, so the widget can show or hide the heart.
    var onChange: (() -> Void)?

    private var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?
    private var authSession: ASWebAuthenticationSession?
    private let presenter = AuthPresenter()

    init() {
        tokens = Keychain.load()
        isConnected = tokens != nil
    }

    // MARK: Sign-in

    func connect() {
        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]

        let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: Self.callbackScheme) { url, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authSession = nil
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.fail("Sign-in failed: \(error.localizedDescription)")
                    }
                    return
                }
                guard let url,
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value
                else {
                    self.fail("Spotify didn't approve the sign-in.")
                    return
                }
                await self.finishSignIn(code: code, verifier: verifier)
            }
        }
        session.presentationContextProvider = presenter
        authSession = session
        NSApp.activate(ignoringOtherApps: true)
        session.start()
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        Keychain.delete()
        isConnected = false
        lastError = nil
        onChange?()
    }

    private func finishSignIn(code: String, verifier: String) async {
        do {
            let fresh = try await Self.requestTokens([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": Self.clientID,
                "code_verifier": verifier,
            ], previous: nil)
            store(fresh)
            lastError = nil
        } catch {
            fail("Couldn't finish signing in: \(error.localizedDescription)")
        }
    }

    // MARK: Library

    /// Nil when the state couldn't be fetched.
    func isLiked(_ uri: String) async -> Bool? {
        guard let data = await send("GET", "/me/library/contains", uris: [uri]),
              let flags = try? JSONDecoder().decode([Bool].self, from: data)
        else { return nil }
        return flags.first
    }

    /// Returns whether the change went through.
    func setLiked(_ uri: String, _ liked: Bool) async -> Bool {
        await send(liked ? "PUT" : "DELETE", "/me/library", uris: [uri]) != nil
    }

    // MARK: Requests

    /// Returns the response body, or nil after recording the error.
    private func send(_ method: String, _ path: String, uris: [String]) async -> Data? {
        var components = URLComponents(string: "https://api.spotify.com/v1\(path)")!
        components.queryItems = [URLQueryItem(name: "uris", value: uris.joined(separator: ","))]
        guard let url = components.url else { return nil }

        for attempt in 0..<2 {
            do {
                let token = try await accessToken(forceRefresh: attempt > 0)
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401, attempt == 0 { continue }
                guard (200..<300).contains(status) else {
                    fail(Self.message(status: status, data: data))
                    return nil
                }
                if lastError != nil { lastError = nil }
                return data
            } catch SpotifyAccountError.signedOut {
                return nil
            } catch {
                fail("Spotify request failed: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        guard let current = tokens else { throw SpotifyAccountError.signedOut }
        if !forceRefresh, current.expiresAt > .now.addingTimeInterval(60) { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }

        let task = Task {
            try await Self.requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": Self.clientID,
            ], previous: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh.accessToken
        } catch SpotifyAccountError.rejected {
            // Refresh token revoked or expired: the user has to sign in again.
            disconnect()
            fail("Spotify signed you out. Connect again from the menu.")
            throw SpotifyAccountError.signedOut
        }
    }

    private func store(_ fresh: Tokens) {
        tokens = fresh
        Keychain.save(fresh)
        if !isConnected {
            isConnected = true
            onChange?()
        }
    }

    private func fail(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        lastError = message
    }

    private nonisolated static func requestTokens(_ params: [String: String], previous: Tokens?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw SpotifyAccountError.rejected }
        guard status == 200 else { throw SpotifyAccountError.http(status) }

        let body = try JSONDecoder().decode(TokenResponse.self, from: data)
        // Refreshes may omit a new refresh token; keep using the old one.
        guard let refresh = body.refresh_token ?? previous?.refreshToken else { throw SpotifyAccountError.rejected }
        return Tokens(
            accessToken: body.access_token,
            refreshToken: refresh,
            expiresAt: .now.addingTimeInterval(TimeInterval(body.expires_in))
        )
    }

    private static func message(status: Int, data: Data) -> String {
        let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message ?? "HTTP \(status)"
        switch status {
        case 403: return "Spotify refused: \(detail). The app owner needs Premium, and your account must be listed under User Management."
        case 429: return "Spotify is rate limiting requests. Try again in a minute."
        default: return "Spotify error: \(detail)"
        }
    }

    private static func randomString(length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum SpotifyAccountError: LocalizedError {
    case signedOut, rejected, http(Int)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Not connected to Spotify."
        case .rejected: "Spotify rejected the sign-in."
        case .http(let status): "Spotify returned HTTP \(status)."
        }
    }
}

private struct Tokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

private struct ErrorResponse: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}

private enum Keychain {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.kiran.spotifywidget.spotify",
        kSecAttrAccount: "tokens",
    ]

    static func load() -> Tokens? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    static func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSWindow() }
    }
}
