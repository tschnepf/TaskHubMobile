//
//  TaskHubMobileApp.swift
//  TaskHubMobile
//
//  Created by Developer on 2026-02-20.
//

import Foundation
import Security
import CryptoKit
import UIKit
import UserNotifications
import WidgetKit
import SwiftUI
import SwiftData
import AuthenticationServices
import Combine
import OSLog

// MARK: - Notifications

extension Notification.Name {
    static let deviceTokenReceived = Notification.Name("DeviceTokenReceived")
}

// MARK: - API Error

enum APIError: Error {
    case invalidResponse(String)
    case missingBaseURL
    case discoveryUnavailable
    case tokenExchangeFailed(String)
}

// MARK: - Endpoints

enum Endpoint {
    static let healthLive = "/health/live"
    static let meta = "/api/mobile/v1/meta"
    static let tasks = "/api/mobile/v1/tasks"
    static let deviceRegister = "/api/mobile/v1/devices/register"
    static let deviceUnregister = "/api/mobile/v1/devices/unregister"
    static let notificationPreferences = "/api/mobile/v1/notifications/preferences"
}

// MARK: - Task Filters

enum TaskFilterOption: String, Codable, CaseIterable, Identifiable {
    case all
    case dueToday
    case completed

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .dueToday: return "Due Today"
        case .completed: return "Completed"
        }
    }
}

// MARK: - TaskArea, TaskPriority, RepeatRule

enum TaskArea: String, Codable, CaseIterable, Identifiable {
    case personal
    case work

    var id: String { rawValue }
}

enum TaskPriority: Int, Codable, CaseIterable, Identifiable {
    case one = 1, two, three, four, five

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .one: return "1 (Highest)"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5 (Lowest)"
        }
    }
}

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }
}

// MARK: - Protocols

protocol AppEnvironment: ObservableObject {
    var apiClient: APIClient { get }
    var authStore: AuthStore { get }
    var syncEngine: SyncEngine { get }
    var deviceRegistry: DeviceRegistry { get }
    var widgetCache: WidgetCache { get }
    var preferencesStore: PreferencesStore { get }
    var notificationPreferencesStore: NotificationPreferencesStore { get }
    var projectCache: ProjectCache { get }
}

// MARK: - Default Implementation of AppEnvironment

final class DefaultAppEnvironment: ObservableObject, AppEnvironment {
    let apiClient: APIClient
    let authStore: AuthStore
    let syncEngine: SyncEngine
    let deviceRegistry: DeviceRegistry
    let widgetCache: WidgetCache
    let preferencesStore: PreferencesStore
    let notificationPreferencesStore: NotificationPreferencesStore
    let projectCache: ProjectCache

    init() {
        let keychainService = KeychainService(accessGroup: "com.yourorg.taskhub.sharedkeychain")
        let appGroupCache = AppGroupCache(appGroupId: "group.com.yourorg.taskhub")
        self.authStore = AuthStore(keychain: keychainService)
        self.apiClient = APIClient(authStore: authStore, baseURLStorage: appGroupCache)
        self.widgetCache = WidgetCache(appGroupCache: appGroupCache)
        self.preferencesStore = PreferencesStore(appGroupCache: appGroupCache)
        self.projectCache = ProjectCache(appGroupCache: appGroupCache)
        self.syncEngine = SyncEngine(apiClient: apiClient, persistence: PersistenceController.shared, widgetCache: widgetCache, preferences: preferencesStore, projectCache: projectCache)
        self.deviceRegistry = DeviceRegistry(apiClient: apiClient, authStore: authStore, keychain: keychainService)
        self.notificationPreferencesStore = NotificationPreferencesStore(apiClient: apiClient)
    }
}

// MARK: - ProjectCache

final class ProjectCache {
    private let appGroupCache: AppGroupCache
    private let fileName = "projects.json"
    private let logger = Logger(subsystem: "com.yourorg.taskhub", category: "ProjectCache")

    init(appGroupCache: AppGroupCache) {
        self.appGroupCache = appGroupCache
    }

    func setProjects(_ projects: [String]) async {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(projects)
            appGroupCache.writeShared(fileName: fileName, data: data)
        } catch {
            logger.error("Failed to encode projects: \(error.localizedDescription)")
        }
    }

    func getProjects() async -> [String] {
        guard let data = appGroupCache.readShared(fileName: fileName) else { return [] }
        let decoder = JSONDecoder()
        if let projects = try? decoder.decode([String].self, from: data) {
            return projects
        }
        return []
    }

    func suggestions(prefix: String) async -> [String] {
        guard !prefix.isEmpty else { return [] }
        let all = await getProjects()
        return all.filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @EnvironmentObject private var authStore: AuthStore
    @State private var showBootstrap = false

    var body: some View {
        Group {
            if authStore.isSignedIn {
                MainTaskListView()
                    .environmentObject(env)
            } else {
                if showBootstrap {
                    ServerBootstrapView()
                        .environmentObject(env)
                } else {
                    LoginView()
                        .environmentObject(env)
                }
            }
        }
        .onAppear {
            Task {
                await checkBootstrap()
            }
        }
        .onOpenURL { url in
            Task { await handleIncomingURL(url) }
        }
        .onChange(of: authStore.isSignedIn) { signedIn in
            Task {
                if signedIn {
                    await env.deviceRegistry.prepareForNotifications()
                    await env.deviceRegistry.ensureRegisteredIfPossible()
                } else {
                    await env.deviceRegistry.resetRegistration()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceTokenReceived)) { notif in
            if let data = notif.object as? Data {
                Task { await env.deviceRegistry.updateAPNSToken(data) }
            }
        }
    }

    func checkBootstrap() async {
        let hasBaseURL = await env.apiClient.hasBaseURL()
        DispatchQueue.main.async {
            showBootstrap = !hasBaseURL
        }
    }

    func handleIncomingURL(_ url: URL) async {
        // Ensure the URL scheme matches our app scheme
        guard url.scheme?.lowercased() == OAuthRedirectScheme.lowercased() else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = comps?.host?.lowercased()
        let path = comps?.path
        // Handle widget deep link: taskhubmobile://open/tasks
        if host == "open", path == "/tasks" {
            if authStore.isSignedIn {
                await env.syncEngine.syncNow()
            }
        }
    }
}

// MARK: - Step I0: Server URL Bootstrap

struct ServerBootstrapView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @State private var serverURLText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Enter Task Hub Server URL")) {
                    TextField("https://example.com", text: $serverURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: {
                        Task {
                            await validateAndSave()
                        }
                    }) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Continue")
                        }
                    }
                    .disabled(isLoading || !isValidURL(serverURLText))
                }
            }
            .navigationTitle("Setup Server")
            .onAppear {
                if let savedURL = env.apiClient.loadBaseURL() {
                    serverURLText = savedURL.absoluteString
                }
                os_log("ServerBootstrapView appeared with prefilled URL: %{public@} [BOOTSTRAP]", type: .info, serverURLText)
            }
        }
    }

    func isValidURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              !trimmed.isEmpty else {
            return false
        }
        return true
    }

    func normalizeURL(_ inputURL: URL) -> URL {
        var comps = URLComponents(url: inputURL, resolvingAgainstBaseURL: false)
        if let path = comps?.path, path != "/" {
            comps?.path = path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return comps?.url ?? inputURL
    }

    func validateAndSave() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let trimmedInput = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmedInput) else {
            errorMessage = "Invalid URL format."
            return
        }
        url = normalizeURL(url)

        // Validate /health/live
        do {
            // Temporarily set baseURL to validate
            self.env.apiClient.baseURL = url
            try await env.apiClient.validateHealthLive(baseURL: url)
        } catch {
            errorMessage = "Failed to reach /health/live: \(error.localizedDescription) [HEALTH][MARK] Check logs for details."
            return
        }

        // Validate /api/mobile/v1/meta
        do {
            try await env.apiClient.validateMeta(baseURL: url)
        } catch {
            // Surface error and suggest checking logs for raw response
            errorMessage = "Failed to fetch /api/mobile/v1/meta: \(error.localizedDescription) [META][MARK] Check logs for details."
            return
        }

        // Persist base URL and trigger environment reset
        await env.apiClient.saveBaseURL(url)
        await env.authStore.signOut()
        await env.syncEngine.reset()
        await env.deviceRegistry.resetRegistration()
        await env.widgetCache.invalidateCache()
        // Restart flow: show login now
        // This will be handled by RootView observing authStore.isSignedIn
    }
}

// MARK: - APIClient

actor APIClient {
    private(set) var baseURL: URL?
    private let authStore: AuthStore
    private let baseURLStorage: AppGroupCache
    private let logger = Logger(subsystem: "com.yourorg.taskhub", category: "APIClient")
    private let jsonDecoder: JSONDecoder
    private let session: URLSession
    private var metaCache: MetaResponse?
    private var discoveryCache: OIDCDiscoveryDocument?
    private var ongoingRefresh: Task<Void, Error>?

    init(authStore: AuthStore, baseURLStorage: AppGroupCache) {
        self.authStore = authStore
        self.baseURLStorage = baseURLStorage

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = decoder

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)

        if let saved = baseURLStorage.getBaseURL() {
            self.baseURL = saved
        }
    }

    func hasBaseURL() -> Bool {
        return baseURL != nil
    }

    func loadBaseURL() -> URL? {
        baseURLStorage.getBaseURL()
    }

    func saveBaseURL(_ url: URL) async {
        baseURL = url
        baseURLStorage.saveBaseURL(url)
        metaCache = nil
        discoveryCache = nil
    }

    func validateHealthLive(baseURL: URL) async throws {
        // Temporarily set baseURL to validate
        self.baseURL = baseURL
        do {
            let (data, response) = try await data(path: Endpoint.healthLive, authorized: false)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                logger.error("Health check failed status=\(http.statusCode) body=\(raw)")
                throw APIError.invalidResponse("Health returned status \(http.statusCode)")
            }
        } catch {
            logger.error("Health check request failed: \(error.localizedDescription)")
            throw error
        }
    }

    func validateMeta(baseURL: URL) async throws {
        // Temporarily set baseURL to validate
        self.baseURL = baseURL
        let (data, _) = try await data(path: Endpoint.meta, authorized: false)
        let meta = try jsonDecoder.decode(MetaResponse.self, from: data)

        // Trim potential whitespace/newlines in discovery URL
        let trimmedDiscovery = meta.oidcDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDiscoveryURLValid = URL(string: trimmedDiscovery) != nil

        // Cache meta (with trimmed discovery URL) for subsequent calls
        self.metaCache = MetaResponse(
            apiVersion: meta.apiVersion,
            oidcDiscoveryURL: trimmedDiscovery,
            oidcClientID: meta.oidcClientID,
            requiredScopes: meta.requiredScopes,
            requiredAudience: meta.requiredAudience
        )

        // Validate presence of required fields
        guard !meta.apiVersion.isEmpty,
              isDiscoveryURLValid,
              !meta.oidcClientID.isEmpty else {
            logger.error("Meta validation failed. api_version_len=\(meta.apiVersion.count), client_id_len=\(meta.oidcClientID.count), discovery_parse=\(isDiscoveryURLValid)")
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("Raw meta body: \(raw)")
            } else {
                logger.error("Raw meta body: <non-utf8>")
            }
            throw APIError.invalidResponse("Missing required meta fields")
        }
    }

    private func requireBaseURL() throws -> URL {
        guard let baseURL else { throw APIError.missingBaseURL }
        return baseURL
    }

    func getMeta() async throws -> MetaResponse {
        if let metaCache { return metaCache }
        let (data, _) = try await data(path: Endpoint.meta, authorized: false)
        let meta = try jsonDecoder.decode(MetaResponse.self, from: data)
        self.metaCache = meta
        return meta
    }

    func getDiscovery() async throws -> OIDCDiscoveryDocument {
        if let discoveryCache { return discoveryCache }
        let meta = try await getMeta()
        guard let discoveryURL = URL(string: meta.oidcDiscoveryURL) else {
            throw APIError.discoveryUnavailable
        }
        let (data, _) = try await session.data(from: discoveryURL)
        let doc = try jsonDecoder.decode(OIDCDiscoveryDocument.self, from: data)
        self.discoveryCache = doc
        return doc
    }

    private func formURLEncodedData(_ params: [String: String]) -> Data {
        let encoded = params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    func exchangeCodeForTokens(code: String, codeVerifier: String, redirectURI: String) async throws -> TokenResponse {
        let discovery = try await getDiscovery()
        let meta = try await getMeta()

        var request = URLRequest(url: discovery.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": meta.oidcClientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ]

        request.httpBody = formURLEncodedData(body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<no body>"
            throw APIError.tokenExchangeFailed("HTTP \(http.statusCode): \(raw)")
        }

        let token = try jsonDecoder.decode(TokenResponse.self, from: data)
        return token
    }

    private func buildURL(path: String, query: [URLQueryItem]?) throws -> URL {
        let base = try requireBaseURL()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!

        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let addPath = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + addPath
        components.queryItems = query

        guard let url = components.url else {
            throw APIError.invalidResponse("Invalid URL components")
        }
        return url
    }

    func data(path: String, method: String = "GET", query: [URLQueryItem]? = nil, body: Data? = nil, authorized: Bool = true, headers: [String: String] = [:]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: try buildURL(path: path, query: query))
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await data(for: request, authorized: authorized)
    }

    func data(for request: URLRequest, authorized: Bool = true, retryOn401: Bool = true) async throws -> (Data, URLResponse) {
        var req = request
        if authorized {
            if let token = await authStore.getAccessToken() {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await session.data(for: req)

        if authorized, let http = response as? HTTPURLResponse, http.statusCode == 401, retryOn401 {
            do {
                try await refreshAccessTokenIfNeeded()
                return try await data(for: request, authorized: authorized, retryOn401: false)
            } catch {
                throw error
            }
        }

        return (data, response)
    }

    private func refreshAccessTokenIfNeeded() async throws {
        if let ongoingRefresh {
            return try await ongoingRefresh.value
        }
        let task = Task { try await refreshAccessToken() }
        ongoingRefresh = task
        defer { ongoingRefresh = nil }
        try await task.value
    }

    private func refreshAccessToken() async throws {
        let meta = try await getMeta()
        let discovery = try await getDiscovery()
        guard let refresh = await authStore.getRefreshToken(), !refresh.isEmpty else {
            throw APIError.tokenExchangeFailed("Missing refresh token")
        }

        var request = URLRequest(url: discovery.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": meta.oidcClientID,
            "refresh_token": refresh
        ]

        request.httpBody = formURLEncodedData(body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<no body>"
            throw APIError.tokenExchangeFailed("HTTP \(http.statusCode): \(raw)")
        }

        let token = try jsonDecoder.decode(TokenResponse.self, from: data)
        if let newRefresh = token.refreshToken {
            try await authStore.saveTokens(accessToken: token.accessToken, refreshToken: newRefresh)
        } else {
            try await authStore.updateAccessToken(token.accessToken)
        }
    }

    func fetchTasks() async throws -> [TaskDTO] {
        let (data, _) = try await data(path: Endpoint.tasks)
        return try jsonDecoder.decode([TaskDTO].self, from: data)
    }

    // MARK: - Tasks Mutations
    func createTask(title: String, dueAt: Date?, projectName: String?) async throws -> TaskDTO {
        var payload: [String: Any] = ["title": title]
        if let dueAt { payload["due_at"] = ISO8601DateFormatter().string(from: dueAt) }
        if let projectName { payload["project"] = projectName }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let headers = ["Content-Type": "application/json"]
        let (data, _) = try await data(path: Endpoint.tasks, method: "POST", body: body, authorized: true, headers: headers)
        return try jsonDecoder.decode(TaskDTO.self, from: data)
    }

    func updateTask(id: String, title: String?, completed: Bool?, dueAt: Date?, projectName: String? = nil, area: TaskArea? = nil, priority: TaskPriority? = nil, repeatRule: RepeatRule? = nil) async throws -> TaskDTO {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let completed { payload["is_completed"] = completed }
        if let dueAt { payload["due_at"] = ISO8601DateFormatter().string(from: dueAt) }
        if let projectName { payload["project"] = projectName }
        if let area { payload["area"] = area.rawValue }
        if let priority { payload["priority"] = priority.rawValue }
        if let repeatRule { payload["recurrence"] = repeatRule.rawValue }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let headers = ["Content-Type": "application/json"]
        let path = Endpoint.tasks + "/" + id
        let (data, _) = try await data(path: path, method: "PATCH", body: body, authorized: true, headers: headers)
        return try jsonDecoder.decode(TaskDTO.self, from: data)
    }

    func deleteTask(id: String) async throws {
        let path = Endpoint.tasks + "/" + id
        _ = try await data(path: path, method: "DELETE", authorized: true)
    }

    // MARK: - Notification Preferences
    func getNotificationPreferences() async throws -> NotificationPreferencesDTO {
        let (data, _) = try await data(path: Endpoint.notificationPreferences)
        return try jsonDecoder.decode(NotificationPreferencesDTO.self, from: data)
    }

    func updateNotificationPreferences(_ prefs: NotificationPreferencesDTO) async throws -> NotificationPreferencesDTO {
        let body = try JSONEncoder().encode(prefs)
        var headers = ["Content-Type": "application/json"]
        let (data, _) = try await data(path: Endpoint.notificationPreferences, method: "PUT", body: body, authorized: true, headers: headers)
        return try jsonDecoder.decode(NotificationPreferencesDTO.self, from: data)
    }

    func registerDevice(token: String, appVersion: String, platform: String = "iOS") async throws {
        let payload: [String: Any] = [
            "token": token,
            "platform": platform,
            "app_version": appVersion
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let headers = ["Content-Type": "application/json"]
        _ = try await data(path: Endpoint.deviceRegister, method: "POST", body: body, authorized: true, headers: headers)
    }

    func unregisterDevice() async throws {
        _ = try await data(path: Endpoint.deviceUnregister, method: "POST", authorized: true)
    }
}

// MARK: - MetaResponse Model

struct MetaResponse: Codable {
    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case oidcDiscoveryURL = "oidc_discovery_url"
        case oidcClientID = "oidc_client_id"
        case requiredScopes = "required_scopes"
        case requiredAudience = "required_audience"
    }

    let apiVersion: String
    let oidcDiscoveryURL: String
    let oidcClientID: String
    let requiredScopes: [String]
    let requiredAudience: String
}

// MARK: - OIDC Models

struct OIDCDiscoveryDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case endSessionEndpoint = "end_session_endpoint"
    }

    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL?
    let endSessionEndpoint: URL?
}

struct TokenResponse: Codable {
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: Int?
}

// MARK: - Task Models

struct TaskDTO: Codable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case completed = "is_completed"
        case dueAt = "due_at"
        case project
    }

    let id: String
    let title: String
    let completed: Bool
    let dueAt: Date?
    let project: String?
}

// MARK: - SwiftData Model

@Model
final class TaskItem {
    @Attribute(.unique) var id: String
    var title: String
    var isCompleted: Bool
    var dueAt: Date?
    var project: String?

    // Client-side metadata
    var updatedAt: Date
    var isDirty: Bool

    init(id: String, title: String, isCompleted: Bool, dueAt: Date?, project: String? = nil, updatedAt: Date = Date(), isDirty: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueAt = dueAt
        self.project = project
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }
}

// MARK: - Notification Preferences Model

struct NotificationPreferencesDTO: Codable {
    enum CodingKeys: String, CodingKey {
        case pushEnabled = "push_enabled"
    }
    var pushEnabled: Bool
}

// MARK: - AuthStore

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var isSignedIn: Bool = false

    private let keychain: KeychainService
    private let logger = Logger(subsystem: "com.yourorg.taskhub", category: "AuthStore")

    // Tokens
    private var accessToken: String? {
        didSet { updateSignedInStatus() }
    }
    private var refreshToken: String?

    init(keychain: KeychainService) {
        self.keychain = keychain
        Task {
            await loadTokens()
        }
    }

    private func updateSignedInStatus() {
        self.isSignedIn = (self.accessToken != nil)
    }

    private func loadTokens() async {
        accessToken = try? await keychain.load(key: "accessToken")
        refreshToken = try? await keychain.load(key: "refreshToken")
        updateSignedInStatus()
    }

    func saveTokens(accessToken: String, refreshToken: String) async throws {
        try await keychain.save(key: "accessToken", value: accessToken)
        try await keychain.save(key: "refreshToken", value: refreshToken)
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        updateSignedInStatus()
    }

    func updateAccessToken(_ newAccessToken: String) async throws {
        try await keychain.save(key: "accessToken", value: newAccessToken)
        self.accessToken = newAccessToken
        updateSignedInStatus()
    }

    func clearTokens() async throws {
        try await keychain.delete(key: "accessToken")
        try await keychain.delete(key: "refreshToken")
        accessToken = nil
        refreshToken = nil
        updateSignedInStatus()
    }

    func signOut() async {
        do {
            try await clearTokens()
        } catch {
            logger.error("Failed to clear tokens on sign out: \(error.localizedDescription)")
        }
    }

    // Provide token to APIClient for requests
    func getAccessToken() async -> String? {
        return accessToken
    }

    func getRefreshToken() async -> String? {
        return refreshToken
    }

    // To be implemented: refresh token logic in Step I2/I3
}

// MARK: - KeychainService (simplified)

actor KeychainService {
    let accessGroup: String
    private let service = "com.yourorg.taskhub"

    init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    func save(key: String, value: String) async throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain save failed with status: \(status)"])
        }
    }

    func load(key: String) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain load failed with status: \(status)"])
        }

        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain delete failed with status: \(status)"])
        }
    }
}

// MARK: - AppGroupCache (for base URL persistence)

final class AppGroupCache {
    private let appGroupId: String
    private let baseURLKey = "baseURL"

    init(appGroupId: String) {
        self.appGroupId = appGroupId
    }

    func getBaseURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let urlFile = containerURL.appendingPathComponent("baseURL.txt")
        if let str = try? String(contentsOf: urlFile),
           let url = URL(string: str) {
            return url
        }
        return nil
    }

    func saveBaseURL(_ url: URL) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return
        }
        let urlFile = containerURL.appendingPathComponent("baseURL.txt")
        try? url.absoluteString.write(to: urlFile, atomically: true, encoding: .utf8)
    }

    func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    func writeShared(fileName: String, data: Data) {
        guard let containerURL = containerURL() else { return }
        let fileURL = containerURL.appendingPathComponent(fileName)
        try? data.write(to: fileURL)
    }

    func readShared(fileName: String) -> Data? {
        guard let containerURL = containerURL() else { return nil }
        let fileURL = containerURL.appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }

    func removeShared(fileName: String) {
        guard let containerURL = containerURL() else { return }
        let fileURL = containerURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - SyncEngine (with syncNow)

actor SyncEngine {
    private let apiClient: APIClient
    private let persistence: PersistenceController
    private let widgetCache: WidgetCache
    private let preferences: PreferencesStore
    private let projectCache: ProjectCache
    private let logger = Logger(subsystem: "com.yourorg.taskhub", category: "SyncEngine")

    init(apiClient: APIClient, persistence: PersistenceController, widgetCache: WidgetCache, preferences: PreferencesStore, projectCache: ProjectCache) {
        self.apiClient = apiClient
        self.persistence = persistence
        self.widgetCache = widgetCache
        self.preferences = preferences
        self.projectCache = projectCache
    }

    func syncNow() async {
        await pushPendingChanges()
        do {
            let tasks = try await apiClient.fetchTasks()
            await persistence.upsertTasks(tasks)
            let filter = await preferences.defaultWidgetFilter
            let snapshotTasks = await persistence.fetchTopTasksForWidget(filter: filter)
            await widgetCache.writeTasksSnapshot(tasks: snapshotTasks)
            await refreshProjects()
        } catch {
            os_log("Sync failed: %{public@}", type: .error, String(describing: error))
        }
    }

    func pushPendingChanges() async {
        let dirty = await persistence.fetchDirtyTasksDTO()
        guard !dirty.isEmpty else { return }
        var cleaned: [String] = []
        for dto in dirty {
            do {
                let updated = try await apiClient.updateTask(id: dto.id, title: dto.title, completed: dto.completed, dueAt: dto.dueAt)
                await persistence.upsertTasks([updated])
                cleaned.append(dto.id)
            } catch {
                os_log("Push failed for task %{public@}: %{public@}", type: .error, dto.id, String(describing: error))
            }
        }
        if !cleaned.isEmpty {
            await persistence.markClean(ids: cleaned)
        }
    }

    func upsertTasks(_ dtos: [TaskDTO]) async {
        await persistence.upsertTasks(dtos)
    }

    func reset() async {
        await persistence.reset()
        await widgetCache.invalidateCache()
    }

    func refreshProjects() async {
        do {
            // Attempt to fetch all projects; if API supports query, pass empty or wildcard
            let (data, _) = try await apiClient.data(path: "/api/mobile/v1/projects", authorized: true)
            let decoder = JSONDecoder()
            struct ProjectDTO: Codable {
                let name: String
            }
            let items = try decoder.decode([ProjectDTO].self, from: data)
            let names = items.map { $0.name }
            await projectCache.setProjects(names)
        } catch {
            logger.error("Project refresh failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - PersistenceController (SwiftData)

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer
    let context: ModelContext

    init() {
        do {
            self.container = try ModelContainer(for: TaskItem.self)
            self.context = ModelContext(container)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    func reset() async {
        do {
            let descriptor = FetchDescriptor<TaskItem>()
            let all = try context.fetch(descriptor)
            for item in all {
                context.delete(item)
            }
            try context.save()
        } catch {
            os_log("Failed to reset persistence: %{public@}", type: .error, String(describing: error))
        }
    }

    func upsertTasks(_ dtos: [TaskDTO]) async {
        do {
            for dto in dtos {
                let existing = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == dto.id })).first
                if let item = existing {
                    item.title = dto.title
                    item.isCompleted = dto.completed
                    item.dueAt = dto.dueAt
                    item.project = dto.project
                    item.updatedAt = Date()
                } else {
                    let _ = TaskItem(id: dto.id, title: dto.title, isCompleted: dto.completed, dueAt: dto.dueAt, project: dto.project)
                }
            }
            try context.save()
        } catch {
            os_log("Failed to upsert tasks: %{public@}", type: .error, String(describing: error))
        }
    }

    func markClean(ids: [String]) async {
        for id in ids {
            do {
                if let item = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first {
                    item.isDirty = false
                }
            } catch { }
        }
        do { try context.save() } catch { }
    }

    func fetchDirtyTasksDTO() async -> [TaskDTO] {
        do {
            let dirty = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isDirty == true }))
            return dirty.map { TaskDTO(id: $0.id, title: $0.title, completed: $0.isCompleted, dueAt: $0.dueAt, project: $0.project) }
        } catch {
            return []
        }
    }

    func deleteTask(id: String) async {
        do {
            if let item = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first {
                context.delete(item)
                try context.save()
            }
        } catch {
            os_log("Failed to delete task: %{public@}", type: .error, String(describing: error))
        }
    }

    func fetchTopTasksForWidget(filter: TaskFilterOption?, limit: Int = 5) async -> [TaskDTO] {
        do {
            let items = try context.fetch(FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.dueAt, order: .forward), SortDescriptor(\.title, order: .forward)]))
            let filtered: [TaskItem]
            if let filter {
                switch filter {
                case .all:
                    filtered = items
                case .dueToday:
                    let cal = Calendar.current
                    filtered = items.filter { !$0.isCompleted && ($0.dueAt.map { cal.isDateInToday($0) } ?? false) }
                case .completed:
                    filtered = items.filter { $0.isCompleted }
                }
            } else {
                filtered = items
            }
            let top = Array(filtered.prefix(limit))
            return top.map { TaskDTO(id: $0.id, title: $0.title, completed: $0.isCompleted, dueAt: $0.dueAt, project: $0.project) }
        } catch {
            return []
        }
    }
}

// MARK: - DeviceRegistry

actor DeviceRegistry {
    private let apiClient: APIClient
    private let authStore: AuthStore
    private let keychain: KeychainService
    private let logger = Logger(subsystem: "com.yourorg.taskhub", category: "DeviceRegistry")

    init(apiClient: APIClient, authStore: AuthStore, keychain: KeychainService) {
        self.apiClient = apiClient
        self.authStore = authStore
        self.keychain = keychain
    }

    func prepareForNotifications() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            logger.error("Failed to request notification authorization: \(error.localizedDescription)")
        }
    }

    func updateAPNSToken(_ tokenData: Data) async {
        let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
        do {
            try await keychain.save(key: "apnsToken", value: tokenString)
            await ensureRegisteredIfPossible()
        } catch {
            logger.error("Failed to persist APNs token: \(error.localizedDescription)")
        }
    }

    func ensureRegisteredIfPossible() async {
        guard let token = try? await keychain.load(key: "apnsToken"), let token, !token.isEmpty else { return }
        let isSignedIn = (await authStore.getAccessToken()) != nil
        guard isSignedIn else { return }

        let registeredToken = try? await keychain.load(key: "apnsTokenRegistered")
        if registeredToken == token {
            return
        }

        do {
            let appVersion = appVersionString()
            try await apiClient.registerDevice(token: token, appVersion: appVersion, platform: "iOS")
            try await keychain.save(key: "apnsTokenRegistered", value: token)
        } catch {
            logger.error("Device registration failed: \(error.localizedDescription)")
        }
    }

    func unregisterIfPossible() async {
        do {
            try await apiClient.unregisterDevice()
        } catch {
            logger.error("Device unregistration failed: \(error.localizedDescription)")
        }
        do { try await keychain.delete(key: "apnsTokenRegistered") } catch { }
    }

    func resetRegistration() async {
        await unregisterIfPossible()
        do { try await keychain.delete(key: "apnsToken") } catch { }
    }

    private func appVersionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

// MARK: - WidgetCache

struct WidgetTaskSnapshotItem: Codable {
    enum CodingKeys: String, CodingKey { case title, isCompleted = "is_completed", dueAt = "due_at" }
    let title: String
    let isCompleted: Bool
    let dueAt: Date?
}

struct WidgetTasksSnapshot: Codable {
    let count: Int
    let tasks: [WidgetTaskSnapshotItem]
}

final class WidgetCache {
    private let appGroupCache: AppGroupCache
    private let fileName = "widget_tasks.json"

    init(appGroupCache: AppGroupCache) {
        self.appGroupCache = appGroupCache
    }

    func invalidateCache() async {
        appGroupCache.removeShared(fileName: fileName)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func writeTasksSnapshot(tasks: [TaskDTO]) async {
        let items = tasks.map { WidgetTaskSnapshotItem(title: $0.title, isCompleted: $0.completed, dueAt: $0.dueAt) }
        let snapshot = WidgetTasksSnapshot(count: items.count, tasks: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            appGroupCache.writeShared(fileName: fileName, data: data)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

// MARK: - PreferencesStore

@MainActor
final class PreferencesStore: ObservableObject {
    private let appGroupCache: AppGroupCache
    private let fileName = "preferences.json"

    @Published var visibleFilters: Set<TaskFilterOption> = [.all, .dueToday, .completed]
    @Published var defaultWidgetFilter: TaskFilterOption = .all

    init(appGroupCache: AppGroupCache) {
        self.appGroupCache = appGroupCache
        Task { await load() }
    }

    struct StoredPrefs: Codable {
        let visibleFilters: [TaskFilterOption]
        let defaultWidgetFilter: TaskFilterOption
    }

    func load() async {
        if let data = appGroupCache.readShared(fileName: fileName) {
            let decoder = JSONDecoder()
            if let stored = try? decoder.decode(StoredPrefs.self, from: data) {
                self.visibleFilters = Set(stored.visibleFilters)
                self.defaultWidgetFilter = stored.defaultWidgetFilter
                return
            }
        }
        await save() // write defaults
    }

    func save() async {
        let stored = StoredPrefs(visibleFilters: Array(visibleFilters), defaultWidgetFilter: defaultWidgetFilter)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(stored) {
            appGroupCache.writeShared(fileName: fileName, data: data)
        }
    }
}

// MARK: - NotificationPreferencesStore

@MainActor
final class NotificationPreferencesStore: ObservableObject {
    private let apiClient: APIClient
    @Published var pushEnabled: Bool = true
    @Published var lastError: String?

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func load() async {
        do {
            let prefs = try await apiClient.getNotificationPreferences()
            self.pushEnabled = prefs.pushEnabled
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func setPushEnabled(_ enabled: Bool) async {
        do {
            let updated = try await apiClient.updateNotificationPreferences(NotificationPreferencesDTO(pushEnabled: enabled))
            self.pushEnabled = updated.pushEnabled
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}

// MARK: - OAuth Helpers

private let OAuthRedirectScheme = "taskhubmobile"
private let OAuthRedirectURI = "taskhubmobile://oauth/callback"

final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - NotificationPreferencesView

struct NotificationPreferencesView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @EnvironmentObject private var prefs: NotificationPreferencesStore

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Push Notifications")) {
                    Toggle("Enable Push Notifications", isOn: Binding(
                        get: { prefs.pushEnabled },
                        set: { newValue in Task { await prefs.setPushEnabled(newValue) } }
                    ))
                }
                if let err = prefs.lastError {
                    Section {
                        Text(err).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Notifications")
            .task { await prefs.load() }
        }
    }
}

// MARK: - AppPreferencesView

struct AppPreferencesView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @EnvironmentObject private var appPrefs: PreferencesStore
    @EnvironmentObject private var notifPrefs: NotificationPreferencesStore

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Task Lists")) {
                    ForEach(TaskFilterOption.allCases) { option in
                        Toggle(option.displayName, isOn: Binding(
                            get: { appPrefs.visibleFilters.contains(option) },
                            set: { newValue in
                                if newValue { appPrefs.visibleFilters.insert(option) } else { appPrefs.visibleFilters.remove(option) }
                                Task { await appPrefs.save() }
                            }
                        ))
                    }
                    Picker("Default for Widget", selection: Binding(
                        get: { appPrefs.defaultWidgetFilter },
                        set: { appPrefs.defaultWidgetFilter = $0; Task { await appPrefs.save() } }
                    )) {
                        ForEach(Array(appPrefs.visibleFilters), id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                Section(header: Text("Push Notifications")) {
                    Toggle("Enable Push Notifications", isOn: Binding(
                        get: { notifPrefs.pushEnabled },
                        set: { newValue in Task { await notifPrefs.setPushEnabled(newValue) } }
                    ))
                    if let err = notifPrefs.lastError {
                        Text(err).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Preferences")
            .task { await notifPrefs.load() }
        }
    }
}

// MARK: - LoginView

struct LoginView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @EnvironmentObject private var authStore: AuthStore
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var authSession: ASWebAuthenticationSession?

    var body: some View {
        VStack(spacing: 16) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
            Button {
                Task { await startSignIn() }
            } label: {
                if isSigningIn {
                    ProgressView()
                } else {
                    Text("Sign in")
                }
            }
            .disabled(isSigningIn)
        }
        .padding()
        .navigationTitle("Sign in")
    }

    private func startSignIn() async {
        await MainActor.run { self.isSigningIn = true; self.errorMessage = nil }
        do {
            let meta = try await env.apiClient.getMeta()
            let discovery = try await env.apiClient.getDiscovery()

            let verifier = generateCodeVerifier()
            let challenge = codeChallenge(from: verifier)
            let state = randomState()

            var scopes = Set(meta.requiredScopes)
            scopes.insert("openid")
            scopes.insert("offline_access")
            let scopeString = scopes.joined(separator: " ")

            var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: meta.oidcClientID),
                URLQueryItem(name: "redirect_uri", value: OAuthRedirectURI),
                URLQueryItem(name: "scope", value: scopeString),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
            if !meta.requiredAudience.isEmpty {
                items.append(URLQueryItem(name: "audience", value: meta.requiredAudience))
            }
            components.queryItems = items

            guard let authURL = components.url else { throw APIError.invalidResponse("Failed to build authorization URL") }

            let provider = WebAuthContextProvider()
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: OAuthRedirectScheme) { callbackURL, error in
                Task {
                    await MainActor.run { self.isSigningIn = false }
                    if let error = error {
                        await MainActor.run { self.errorMessage = error.localizedDescription }
                        return
                    }
                    guard let callbackURL = callbackURL,
                          let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                        await MainActor.run { self.errorMessage = "Missing callback URL" }
                        return
                    }
                    let queryItems = urlComponents.queryItems ?? []
                    if let err = queryItems.first(where: { $0.name == "error" })?.value {
                        let desc = queryItems.first(where: { $0.name == "error_description" })?.value
                        await MainActor.run { self.errorMessage = "\(err): \(desc ?? "")" }
                        return
                    }
                    guard let code = queryItems.first(where: { $0.name == "code" })?.value,
                          let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
                          returnedState == state else {
                        await MainActor.run { self.errorMessage = "Invalid authorization response" }
                        return
                    }
                    do {
                        let token = try await env.apiClient.exchangeCodeForTokens(code: code, codeVerifier: verifier, redirectURI: OAuthRedirectURI)
                        guard let refresh = token.refreshToken else {
                            await MainActor.run { self.errorMessage = "No refresh token received. Ensure offline_access scope is enabled." }
                            return
                        }
                        try await authStore.saveTokens(accessToken: token.accessToken, refreshToken: refresh)
                    } catch {
                        await MainActor.run { self.errorMessage = error.localizedDescription }
                    }
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            await MainActor.run { self.authSession = session }
            _ = session.start()
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription; self.isSigningIn = false }
        }
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private func codeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return base64URLEncode(Data(hash))
    }

    private func base64URLEncode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }
}

// MARK: - MainTaskListView

struct MainTaskListView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @EnvironmentObject private var appPrefs: PreferencesStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\TaskItem.dueAt, order: .forward), SortDescriptor(\TaskItem.title, order: .forward)]) private var tasks: [TaskItem]

    @State private var isSyncing: Bool = false
    @State private var errorMessage: String?
    @State private var pendingRetry: (() async -> Void)?
    @State private var showingCreateSheet = false
    @State private var showingPreferences = false

    @State private var currentFilter: TaskFilterOption = .all

    // Create/edit state
    @State private var newTitle: String = ""
    @State private var newHasDueDate: Bool = false
    @State private var newDueDate: Date = .now
    
    @State private var newProjectName: String = ""
    @State private var projectSuggestions: [String] = []

    // Removed: @State private var editingTask: TaskItem?
    @State private var editTitle: String = ""
    @State private var editHasDueDate: Bool = false
    @State private var editDueDate: Date = .now
    @State private var editTaskID: String? = nil

    @State private var expandedTaskID: String? = nil

    @State private var editProjectName: String = ""
    @State private var editProjectSuggestions: [String] = []

    @State private var editArea: TaskArea = .personal
    @State private var editPriority: TaskPriority = .three
    @State private var editRepeat: RepeatRule = .none

    var filteredTasks: [TaskItem] {
        switch currentFilter {
        case .all:
            return tasks
        case .dueToday:
            let cal = Calendar.current
            return tasks.filter { !$0.isCompleted && ($0.dueAt.map { cal.isDateInToday($0) } ?? false) }
        case .completed:
            return tasks.filter { $0.isCompleted }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSyncing && tasks.isEmpty {
                    ProgressView()
                } else if let errorMessage, tasks.isEmpty {
                    VStack(spacing: 12) {
                        Text("Failed to load tasks").font(.headline)
                        Text(errorMessage).foregroundColor(.red).multilineTextAlignment(.center)
                        Button("Retry") { Task { await syncNow() } }
                    }.padding()
                } else if filteredTasks.isEmpty {
                    ContentUnavailableView("No Tasks", systemImage: "checkmark.circle")
                } else {
                    List(filteredTasks) { task in
                        HStack(alignment: .center, spacing: 0) {
                            Button {
                                Task { await toggleComplete(task) }
                            } label: {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(task.isCompleted ? .green : .secondary)
                                    .imageScale(.large)
                                    .frame(width: 36, height: 36, alignment: .center)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Spacer().frame(width: 6)

                            VStack(alignment: .leading, spacing: 4) {
                                Group {
                                    if let name = task.project, !name.isEmpty {
                                        Text("\(name) \(task.title)")
                                    } else {
                                        Text(task.title)
                                    }
                                }
                                if let due = task.dueAt {
                                    Text("Due: \(due.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.leading, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { startEdit(task) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await deleteTask(task) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }

                        if expandedTaskID == task.id {
                            VStack(alignment: .leading, spacing: 12) {
                                // Title
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Title").font(.caption).foregroundColor(.secondary)
                                    TextField("Task title", text: $editTitle)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Due Date
                                VStack(alignment: .leading, spacing: 6) {
                                    Toggle("Has due date", isOn: $editHasDueDate.animation())
                                    if editHasDueDate {
                                        DatePicker("Due Date", selection: $editDueDate, displayedComponents: [.date])
                                    }
                                }

                                // Project with suggestions
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Project").font(.caption).foregroundColor(.secondary)
                                    TextField("Project (optional)", text: $editProjectName)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: editProjectName) { text in
                                            Task {
                                                self.editProjectSuggestions = await env.projectCache.suggestions(prefix: text)
                                            }
                                        }
                                    if !editProjectSuggestions.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(editProjectSuggestions, id: \.self) { name in
                                                Button(action: {
                                                    self.editProjectName = name
                                                    self.editProjectSuggestions = []
                                                }) {
                                                    HStack {
                                                        Image(systemName: "folder")
                                                        Text(name)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // Area (Personal/Work)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Area").font(.caption).foregroundColor(.secondary)
                                    Picker("Area", selection: $editArea) {
                                        Text("Personal").tag(TaskArea.personal)
                                        Text("Work").tag(TaskArea.work)
                                    }
                                    .pickerStyle(.segmented)
                                }

                                // Priority (1-5)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Priority").font(.caption).foregroundColor(.secondary)
                                    Picker("Priority", selection: $editPriority) {
                                        ForEach(TaskPriority.allCases) { p in
                                            Text(p.displayName).tag(p)
                                        }
                                    }
                                }

                                // Repeat Rule
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Repeat").font(.caption).foregroundColor(.secondary)
                                    Picker("Repeat", selection: $editRepeat) {
                                        ForEach(RepeatRule.allCases) { r in
                                            Text(r.rawValue.capitalized).tag(r)
                                        }
                                    }
                                }

                                HStack {
                                    Button("Cancel") {
                                        withAnimation { expandedTaskID = nil }
                                        editProjectSuggestions = []
                                        editTaskID = nil
                                    }
                                    Spacer()
                                    Button("Save") {
                                        Task { await saveEdits() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await syncNow() }
                    .animation(.default, value: expandedTaskID)
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(Array(appPrefs.visibleFilters), id: \.self) { option in
                            Button(action: { currentFilter = option }) {
                                if currentFilter == option { Image(systemName: "checkmark") }
                                Text(option.displayName)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(currentFilter.displayName)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingPreferences = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCreateSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .task {
                currentFilter = appPrefs.defaultWidgetFilter
                await initialSyncIfNeeded()
            }
            .sheet(isPresented: $showingCreateSheet) { createSheet }
            .sheet(isPresented: $showingPreferences) {
                AppPreferencesView()
                    .environmentObject(env)
                    .environmentObject(env.preferencesStore)
                    .environmentObject(env.notificationPreferencesStore)
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil; pendingRetry = nil } })) {
                if let retry = pendingRetry {
                    Button("Retry") { Task { await retry() } }
                }
                Button("Dismiss", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func initialSyncIfNeeded() async { if tasks.isEmpty { await syncNow() } }

    private func syncNow() async {
        await MainActor.run { isSyncing = true }
        defer { Task { await MainActor.run { isSyncing = false } } }
        await env.syncEngine.syncNow()
    }

    private func startEdit(_ task: TaskItem) {
        if expandedTaskID == task.id {
            withAnimation { expandedTaskID = nil }
            editTaskID = nil
            return
        }
        editTaskID = task.id
        editTitle = task.title
        if let due = task.dueAt { editDueDate = due; editHasDueDate = true } else { editHasDueDate = false }
        editProjectName = task.project ?? ""
        editProjectSuggestions = []
        editArea = .personal
        editPriority = .three
        editRepeat = .none
        withAnimation { expandedTaskID = task.id }
    }

    private func toggleComplete(_ task: TaskItem) async {
        let newValue = !task.isCompleted
        await MainActor.run {
            task.isCompleted = newValue
            task.isDirty = true
            try? modelContext.save()
        }
        do {
            let updated = try await env.apiClient.updateTask(id: task.id, title: nil, completed: newValue, dueAt: task.dueAt)
            await env.syncEngine.upsertTasks([updated])
            await env.syncEngine.pushPendingChanges()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                pendingRetry = { [weak task] in
                    if let task = task { await self.toggleComplete(task) }
                }
            }
        }
    }

    private func deleteTask(_ task: TaskItem) async {
        do {
            try await env.apiClient.deleteTask(id: task.id)
            await env.syncEngine.upsertTasks([])
            await PersistenceController.shared.deleteTask(id: task.id)
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                pendingRetry = { [id = task.id] in
                    await self.deleteTaskById(id)
                }
            }
        }
    }

    private func deleteTaskById(_ id: String) async {
        do {
            try await env.apiClient.deleteTask(id: id)
            await PersistenceController.shared.deleteTask(id: id)
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func createTask() async {
        let due: Date? = newHasDueDate ? newDueDate : nil
        let projectName: String? = newProjectName.isEmpty ? nil : newProjectName
        do {
            let created = try await env.apiClient.createTask(title: newTitle, dueAt: due, projectName: projectName)
            await env.syncEngine.upsertTasks([created])
            await MainActor.run {
                newTitle = ""
                newHasDueDate = false
                newProjectName = ""
                projectSuggestions = []
                showingCreateSheet = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                pendingRetry = { await self.createTask() }
            }
        }
    }

    private func saveEdits() async {
        guard let id = editTaskID else { return }
        let due: Date? = editHasDueDate ? editDueDate : nil
        do {
            // Changed per instruction: discard returned TaskDTO, update local SwiftData state directly
            _ = try await env.apiClient.updateTask(
                id: id,
                title: editTitle,
                completed: nil,
                dueAt: due,
                projectName: editProjectName.isEmpty ? nil : editProjectName,
                area: editArea,
                priority: editPriority,
                repeatRule: editRepeat
            )
            // Update local data model directly to reflect saved changes
            await MainActor.run {
                if let task = tasks.first(where: { $0.id == id }) {
                    task.title = editTitle
                    task.dueAt = due
                    task.project = editProjectName.isEmpty ? nil : editProjectName
                    task.updatedAt = Date()
                    task.isDirty = true // Mark dirty so sync can push changes
                    try? modelContext.save()
                }
                expandedTaskID = nil
                editTaskID = nil
                editProjectSuggestions = []
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                pendingRetry = { await self.saveEdits() }
            }
        }
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("Title")) {
                    TextField("Task title", text: $newTitle)
                }
                Section(header: Text("Due Date")) {
                    Toggle("Has due date", isOn: $newHasDueDate.animation())
                    if newHasDueDate {
                        DatePicker("Due Date", selection: $newDueDate, displayedComponents: [.date])
                    }
                }
                Section(header: Text("Project")) {
                    TextField("Project (optional)", text: $newProjectName)
                        .onChange(of: newProjectName) { text in
                            Task {
                                self.projectSuggestions = await env.projectCache.suggestions(prefix: text)
                            }
                        }
                    if !projectSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(projectSuggestions, id: \.self) { name in
                                Button(action: {
                                    self.newProjectName = name
                                    self.projectSuggestions = []
                                }) {
                                    HStack {
                                        Image(systemName: "folder")
                                        Text(name)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createTask() }
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingCreateSheet = false
                        projectSuggestions = []
                    }
                }
            }
        }
    }
}

@main
struct TaskHubMobileApp: App {
    // Injected environment holding all services
    @StateObject private var appEnvironment = DefaultAppEnvironment()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appEnvironment)
                .environmentObject(appEnvironment.authStore)
        }
        .modelContainer(PersistenceController.shared.container)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .deviceTokenReceived, object: deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Optionally log the error
        os_log("APNs registration failed: %{public@}", type: .error, String(describing: error))
    }
}

