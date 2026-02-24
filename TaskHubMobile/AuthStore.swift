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

@MainActor
final class AuthStore: NSObject, ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var expiryDate: Date?

    // Discovery and client context retained for refresh/logout
    private var lastDiscovery: OIDCDiscovery?
    private var lastClientID: String?
    private var lastBaseURL: URL?

    private let keychain = KeychainStore(service: "com.yourorg.taskhub.tokens", accessGroup: AppIdentifiers.keychainAccessGroup)

    private let accessKey = "access_token"
    private let refreshKey = "refresh_token"
    private let expiryKey = "expiry"

    @Published var prefersEphemeralWebAuthSession: Bool = true
    private var lastState: String?
    private var lastVerifier: String?

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

    // MARK: - OIDC Sign-In
    func signIn(baseURL: URL) async throws {
        // 1) Fetch /meta to get discovery and client info
        let meta = try await MobileAPI.fetchMeta(baseURL: baseURL)
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
        self.lastBaseURL = baseURL

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
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        return try decoder.decode(OIDCDiscovery.self, from: data)
    }

    private func exchangeCodeForToken(discovery: OIDCDiscovery, clientID: String, code: String, verifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: discovery.token_endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: AppConstants.redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        req.httpBody = Self.formURLEncoded(bodyItems).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
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
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { callbackURL, error in
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
}
extension AuthStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return window
            }
            // Fallback: attach to a new window for this scene (non-deprecated initializer)
            let temp = UIWindow(windowScene: scene)
            return temp
        }
        return ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

