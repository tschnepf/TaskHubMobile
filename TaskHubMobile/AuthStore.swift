//
//  AuthStore.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import AuthenticationServices
import Combine
import UIKit

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let error_description: String?
}

private enum AuthFlowError: LocalizedError {
    case noActivePresentationAnchor
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .noActivePresentationAnchor:
            return "Unable to start sign-in because no active presentation window is available."
        case .unsupportedPlatform:
            return "Web authentication is not supported on this platform."
        }
    }
}

@MainActor
final class AuthStore: NSObject, ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var expiryDate: Date?

    // Discovery and client context retained for refresh/logout
    private var lastDiscovery: OIDCDiscovery?
    private var lastClientID: String?
    private var lastBaseURL: URL?

    private let keychain = KeychainStore(service: "com.ie.taskhub.tokens", accessGroup: AppIdentifiers.keychainAccessGroup)
    private let defaults = UserDefaults(suiteName: AppConfig.appGroupIdentifier) ?? .standard

    private let accessKey = "access_token"
    private let refreshKey = "refresh_token"
    private let expiryKey = "expiry"
    private let metaCacheKeyPrefix = "auth.meta.cache."

    @Published var prefersEphemeralWebAuthSession: Bool = true
    private var lastState: String?
    private var lastVerifier: String?
    #if canImport(UIKit)
    private var webAuthPresentationAnchor: ASPresentationAnchor?
    #endif

    override init() {
        super.init()
        // Load from Keychain if present
        if let data = try? keychain.data(for: accessKey), let s = String(data: data, encoding: .utf8) { accessToken = s }
        if let data = try? keychain.data(for: refreshKey), let s = String(data: data, encoding: .utf8) { refreshToken = s }
        if let data = try? keychain.data(for: expiryKey), let s = String(data: data, encoding: .utf8), let t = TimeInterval(s) {
            expiryDate = Date(timeIntervalSince1970: t)
        }
    }

    func storeTokens(access: String, refresh: String?, expiresIn: Int) {
        accessToken = access
        refreshToken = refresh
        expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        try? keychain.set(Data(access.utf8), for: accessKey)
        if let refresh { try? keychain.set(Data(refresh.utf8), for: refreshKey) }
        if let expiryDate { try? keychain.set(Data(String(expiryDate.timeIntervalSince1970).utf8), for: expiryKey) }
    }

    func clear() {
        accessToken = nil
        refreshToken = nil
        expiryDate = nil
        keychain.remove(for: accessKey)
        keychain.remove(for: refreshKey)
        keychain.remove(for: expiryKey)
    }

    #if DEBUG
    func setTestingTokens(access: String = "test-access", refresh: String = "test-refresh", expiresIn: Int = 3600) {
        storeTokens(access: access, refresh: refresh, expiresIn: expiresIn)
    }
    #endif

    // MARK: - OIDC Sign-In
    func signIn(baseURL: URL) async throws {
        // 1) Fetch /meta to get discovery and client info
        let canonicalBaseURL = ServerBootstrap.canonicalBaseURL(baseURL) ?? baseURL
        let meta: ServerMeta
        do {
            let fetched = try await MobileAPI.fetchMeta(baseURL: canonicalBaseURL)
            cacheMeta(fetched, for: canonicalBaseURL)
            meta = fetched
        } catch {
            if shouldFallbackToCachedMeta(after: error), let cached = loadCachedMeta(for: canonicalBaseURL) {
                meta = cached
            } else {
                throw error
            }
        }
        // API version gating
        let apiVersionString = meta.api_version
        guard let apiVersion = Int(apiVersionString) else {
            throw NSError(domain: "Auth", code: -11, userInfo: [NSLocalizedDescriptionKey: "Invalid api_version ('\(apiVersionString)') returned by server."])
        }
        guard apiVersion >= AppConstants.minAPIVersion && apiVersion < AppConstants.maxExclusiveAPIVersion else {
            throw NSError(domain: "Auth", code: -10, userInfo: [NSLocalizedDescriptionKey: "Incompatible server API version (\(apiVersion)). Please update the app or contact your administrator."])
        }
        let discovery = try await fetchDiscovery(from: meta.oidc_discovery_url)
        self.lastDiscovery = discovery
        self.lastClientID = meta.oidc_client_id
        self.lastBaseURL = canonicalBaseURL

        // 2) Build authorization URL with PKCE, state, nonce
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challengeS256(for: verifier)
        let state = UUID().uuidString
        let nonce = UUID().uuidString
        self.lastState = state
        self.lastVerifier = verifier

        var components = URLComponents(url: discovery.authorization_endpoint, resolvingAgainstBaseURL: false)!
        var scopes = ["openid", "offline_access"]
        scopes.append(contentsOf: meta.required_scopes)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: meta.oidc_client_id),
            URLQueryItem(name: "redirect_uri", value: AppConstants.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce)
        ]
        if let aud = meta.required_audience { queryItems.append(URLQueryItem(name: "audience", value: aud)) }
        components.queryItems = queryItems
        let authURL = components.url!

        // 3) Start ASWebAuthenticationSession
        let callbackScheme = AppConstants.redirectScheme
        let callbackURL = try await startWebAuthSession(authURL: authURL, callbackScheme: callbackScheme)

        // 4) Parse callback and verify state
        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            throw NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Auth error: \(err)"])
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "Auth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Missing authorization code"])
        }
        if let returnedState = items.first(where: { $0.name == "state" })?.value, let expected = lastState, returnedState != expected {
            throw NSError(domain: "Auth", code: -4, userInfo: [NSLocalizedDescriptionKey: "State mismatch"])
        }

        // 5) Exchange code for tokens
        let token = try await exchangeCodeForToken(discovery: discovery, clientID: meta.oidc_client_id, code: code, verifier: verifier)
        storeTokens(access: token.access_token, refresh: token.refresh_token, expiresIn: token.expires_in)
    }

    private func fetchDiscovery(from url: URL) async throws -> OIDCDiscovery {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw badServerResponseError(
                context: "OIDC discovery request failed",
                url: url,
                statusCode: http.statusCode,
                body: data
            )
        }
        let decoder = JSONDecoder()
        return try decoder.decode(OIDCDiscovery.self, from: data)
    }

    private func exchangeCodeForToken(discovery: OIDCDiscovery, clientID: String, code: String, verifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: discovery.token_endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: AppConstants.redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        req.httpBody = Self.formURLEncoded(bodyItems).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                let detail = oauthError.error_description ?? oauthError.error ?? "Unknown OAuth token error."
                let userInfo: [String: Any] = [
                    NSLocalizedDescriptionKey: "Token exchange failed (HTTP \(http.statusCode)): \(detail)",
                    "http.status": http.statusCode,
                    "url": discovery.token_endpoint.absoluteString
                ]
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: userInfo)
            }
            throw badServerResponseError(
                context: "Token exchange failed",
                url: discovery.token_endpoint,
                statusCode: http.statusCode,
                body: data
            )
        }
        let decoder = JSONDecoder()
        return try decoder.decode(TokenResponse.self, from: data)
    }

    func refreshIfNeeded(skew: TimeInterval = 60) async {
        guard let expiry = expiryDate else { return }
        let threshold = expiry.addingTimeInterval(-skew)
        if Date() < threshold { return }
        await refresh()
    }

    func refresh() async {
        guard let refreshToken else { return }
        do {
            // Ensure we have discovery/clientID; if not, fetch from /meta
            var discovery = self.lastDiscovery
            var clientID = self.lastClientID
            if discovery == nil || clientID == nil {
                if let base = lastBaseURL {
                    let meta = try await MobileAPI.fetchMeta(baseURL: base)
                    discovery = try await fetchDiscovery(from: meta.oidc_discovery_url)
                    clientID = meta.oidc_client_id
                    self.lastDiscovery = discovery
                    self.lastClientID = clientID
                }
            }
            guard let discovery, let clientID else { return }

            var req = URLRequest(url: discovery.token_endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let bodyItems: [URLQueryItem] = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "client_id", value: clientID)
            ]
            req.httpBody = Self.formURLEncoded(bodyItems).data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if (200...299).contains(http.statusCode) {
                let decoder = JSONDecoder()
                let token = try decoder.decode(TokenResponse.self, from: data)
                storeTokens(access: token.access_token, refresh: token.refresh_token ?? refreshToken, expiresIn: token.expires_in)
            } else {
                // Treat as invalid_grant or server error; clear tokens to force re-auth
                clear()
            }
        } catch {
            // On network or decoding errors, do not clear immediately; leave current token and allow retry later
        }
    }

    func logout(revocationEndpoint: URL?) async {
        if let revocationEndpoint, let token = refreshToken ?? accessToken, let clientID = lastClientID {
            var req = URLRequest(url: revocationEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let bodyItems: [URLQueryItem] = [
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "client_id", value: clientID)
            ]
            req.httpBody = Self.formURLEncoded(bodyItems).data(using: .utf8)
            _ = try? await URLSession.shared.data(for: req)
        }
        clear()
    }

    // MARK: - Helpers
    private func startWebAuthSession(authURL: URL, callbackScheme: String) async throws -> URL {
        #if canImport(UIKit)
        guard let presentationAnchor = resolvePresentationAnchor() else {
            throw AuthFlowError.noActivePresentationAnchor
        }
        webAuthPresentationAnchor = presentationAnchor
        #else
        throw AuthFlowError.unsupportedPlatform
        #endif
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                #if canImport(UIKit)
                self.webAuthPresentationAnchor = nil
                #endif
                if let error { continuation.resume(throwing: error) }
                else if let callbackURL { continuation.resume(returning: callbackURL) }
                else { continuation.resume(throwing: URLError(.badURL)) }
            }
            session.prefersEphemeralWebBrowserSession = self.prefersEphemeralWebAuthSession
            session.presentationContextProvider = self
            if !session.start() {
                continuation.resume(throwing: URLError(.cannotFindHost))
            }
        }
    }

    private static func formURLEncoded(_ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }

    private func shouldFallbackToCachedMeta(after error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.userInfo["http.status"] != nil {
            return false
        }
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func badServerResponseError(context: String, url: URL, statusCode: Int, body: Data) -> NSError {
        let preview = String(data: body, encoding: .utf8).map { String($0.prefix(300)) } ?? "<non-utf8>"
        let userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: "\(context): HTTP \(statusCode). Body prefix: \(preview)",
            "http.status": statusCode,
            "body.preview": preview,
            "url": url.absoluteString
        ]
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: userInfo)
    }

    private func metaCacheKey(for baseURL: URL) -> String {
        let canonical = ServerBootstrap.canonicalBaseURL(baseURL) ?? baseURL
        return metaCacheKeyPrefix + canonical.absoluteString
    }

    private func cacheMeta(_ meta: ServerMeta, for baseURL: URL) {
        let key = metaCacheKey(for: baseURL)
        if let data = try? JSONEncoder().encode(meta) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadCachedMeta(for baseURL: URL) -> ServerMeta? {
        let key = metaCacheKey(for: baseURL)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ServerMeta.self, from: data)
    }
}
extension AuthStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        if let anchor = webAuthPresentationAnchor {
            return anchor
        }
        if let window = resolvePresentationAnchor() {
            return window
        }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return ASPresentationAnchor(windowScene: scene)
        }
        preconditionFailure("ASWebAuthenticationSession requires an active UIWindowScene for presentation.")
        #else
        return ASPresentationAnchor()
        #endif
    }

    #if canImport(UIKit)
    private func resolvePresentationAnchor() -> ASPresentationAnchor? {
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        return UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first
    }
    #endif
}
