//
//  SyncController.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import SwiftData
import Combine
import os.log
import WidgetKit
import CryptoKit

actor LocalProjectCache {
    private var names: [String] = []
    private let defaults: UserDefaults
    private let storageKey = "project.names"

    init(suiteName: String? = AppIdentifiers.appGroupID) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        load()
    }

    private func load() {
        if let arr = defaults.array(forKey: storageKey) as? [String] {
            self.names = arr
        } else {
            self.names = []
        }
    }

    private func save() { defaults.set(names, forKey: storageKey) }

    func setProjects(_ input: [String]) async {
        names = Array(Set(input.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        save()
    }

    func addProjects(_ input: [String]) async {
        let cleaned = input.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        names.append(contentsOf: cleaned)
        names = Array(Set(names)).sorted()
        save()
    }

    func suggestions(prefix: String, limit: Int = 8) async -> [String] {
        let q = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let matches = names.filter { $0.lowercased().contains(q) }
        return Array(matches.prefix(limit))
    }
}

enum TaskArea: String, Codable { case work, personal }

enum TaskPriority: Int, Codable, CaseIterable, Identifiable {
    case one = 1, two, three, four, five
    var id: Int { rawValue }
    var displayName: String { String(rawValue) }
}

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, yearly
    var id: String { rawValue }
}

@MainActor
final class SyncController: ObservableObject {
    private let container: ModelContainer
    private let appConfig: AppConfig
    private let authStore: AuthStore
    private var engine: SyncEngine?

    @Published var lastSync: Date?
    @Published var nextAllowedSync: Date?
    @Published var lastError: String?
    @Published var isSyncing: Bool = false

    private let idStore = IdempotencyStore()

    private var backoffSeconds: TimeInterval = 0
    private let maxBackoff: TimeInterval = 60

    private lazy var widgetCache: WidgetCache = {
        WidgetCache(appGroupID: AppIdentifiers.appGroupID, apiClientProvider: { [weak self] in
            let base = self?.appConfig.baseURL
            return APIClient(baseURLProvider: { base }, authStore: self!.authStore)
        })
    }()
    private let projectCache = LocalProjectCache(suiteName: AppIdentifiers.appGroupID)
    
    private var liveLoopTask: Task<Void, Never>? = nil
    private var authTokenCancellable: AnyCancellable? = nil
    private var stopLoopFlag = false
    
    private func getAPIClientForUtilities() async -> APIClient? { await engine?.apiForUtilities() }
    
    private func refreshProjectsCache() async {
        guard let base = appConfig.baseURL else { return }
        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        do {
            let items = try await client.listProjects()
            await projectCache.setProjects(items.map { $0.name })
        } catch {
            // Ignore failures; suggestions will fall back gracefully
        }
    }

    init(container: ModelContainer, appConfig: AppConfig, authStore: AuthStore) {
        self.container = container
        self.appConfig = appConfig
        self.authStore = authStore
        rebuildEngineIfPossible()
        authTokenCancellable = authStore.$accessToken.sink { [weak self] token in
            guard let self else { return }
            if token == nil {
                // Signed out: stop loop and clear local state
                self.stopLiveSyncLoop()
                Task { await self.engine?.resetLocalState() }
            } else {
                // Signed in: rebuild engine with namespaced cursor and trigger immediate sync
                self.rebuildEngineIfPossible()
                self.triggerImmediateDelta()
            }
        }
    }

    func rebuildEngineIfPossible() {
        guard let base = appConfig.baseURL else {
            engine = nil
            lastError = nil
            return
        }
        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let ns = computeCursorNamespace()
        engine = SyncEngine(api: client, modelContainer: container, cursorNamespace: ns)
    }
    
    private func computeCursorNamespace() -> String {
        let base = appConfig.baseURL?.absoluteString ?? ""
        let token = authStore.refreshToken ?? "anon"
        let seed = (base + "|" + token).data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: seed)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func startLiveSyncLoop() {
        guard liveLoopTask == nil else { return }
        stopLoopFlag = false
        liveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.stopLoopFlag {
                // Only attempt when authenticated
                if self.authStore.accessToken != nil {
                    self.syncNow()
                }
                // Adaptive delay: use backoffSeconds if set, else 5s; clamp 3-10s
                var delay = max(3, min(10, Int(self.backoffSeconds == 0 ? 5 : self.backoffSeconds)))
                // If we are currently syncing, back off slightly
                if self.isSyncing { delay = min(10, delay + 2) }
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    func stopLiveSyncLoop() {
        stopLoopFlag = true
        liveLoopTask?.cancel()
        liveLoopTask = nil
    }

    func triggerImmediateDelta() {
        // Reset backoff and attempt a sync soon
        backoffSeconds = 0
        nextAllowedSync = Date(timeIntervalSinceNow: 0)
        syncNow()
    }

    func syncNow() {
        if isSyncing { return }
        // Respect simple backoff window
        if let next = nextAllowedSync, Date() < next { return }
        Task { [weak self, engine] in
            guard let self else { return }
            do {
                await MainActor.run { self.isSyncing = true }
                try await engine?.performInitialOrDeltaSync()
                await MainActor.run {
                    self.isSyncing = false
                    self.lastSync = Date()
                    self.lastError = nil
                    self.backoffSeconds = 0
                    self.nextAllowedSync = nil
                    Task { await self.widgetCache.refreshSnapshotIfNeeded(); WidgetCenter.shared.reloadAllTimelines() }
                    Task { await self.refreshProjectsCache() }
                }
            } catch {
                if case APIClientError.unauthorized = error {
                    await self.authStore.refresh()
                    if self.authStore.accessToken == nil {
                        await self.engine?.resetLocalState()
                        self.authStore.clear()
                    }
                }
                var retryAfter: TimeInterval? = nil
                if case let APIClientError.rateLimited(ra) = error { retryAfter = ra }
                let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                await MainActor.run {
                    self.isSyncing = false
                    self.lastError = msg
                    if let ra = retryAfter {
                        self.nextAllowedSync = Date().addingTimeInterval(ra)
                        self.backoffSeconds = ra
                    } else {
                        self.backoffSeconds = min((self.backoffSeconds == 0 ? 2 : self.backoffSeconds * 2), self.maxBackoff)
                        self.nextAllowedSync = Date().addingTimeInterval(self.backoffSeconds)
                    }
                }
            }
        }
    }
    
    func createTask(title: String, area: TaskArea = .personal, priority: TaskPriority? = nil, projectName: String? = nil, dueAt: Date? = nil, repeatRule: RepeatRule? = nil) async throws {
        guard let engine else { throw NSError(domain: "Sync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync engine unavailable"]) }
        struct CreateTaskBody: Encodable { let title: String; let area: TaskArea }
        // Prepare payload (kept for future engine support of area)
        let _ = CreateTaskBody(title: title, area: area)

        // Generate a fresh idempotency key for this logical create action
        let key = idStore.generate()
        idStore.save(key)

        do {
            try await engine.createTask(title: title, area: area, priority: priority, projectName: projectName, dueAt: dueAt, repeatRule: repeatRule, idempotencyKey: key.value)
            idStore.use(key)
            await MainActor.run { self.lastError = nil }
            self.triggerImmediateDelta()
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            throw error
        }
    }
    
    func createTaskResolvingProject(title: String, area: TaskArea = .personal, priority: TaskPriority? = nil, projectName: String?, dueAt: Date? = nil, repeatRule: RepeatRule? = nil) async throws {
        guard let engine else { throw NSError(domain: "Sync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync engine unavailable"]) }

        let key = idStore.generate(); idStore.save(key)
        do {
            try await engine.createTask(title: title, area: area, priority: priority, projectName: projectName, dueAt: dueAt, repeatRule: repeatRule, idempotencyKey: key.value)
            idStore.use(key)
            await MainActor.run { self.lastError = nil }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            throw error
        }
    }

    func projectSuggestions(prefix: String) async -> [String] {
        await projectCache.suggestions(prefix: prefix)
    }

    func forceFullResync() {
        Task { [weak self] in
            guard let engine = self?.engine else { return }
            await engine.forceFullResync()
        }
    }

    func syncOnForeground() {
        syncNow()
    }

    func refreshWidgetSnapshot() {
        Task { [weak self] in
            await self?.widgetCache.refreshSnapshot()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    
    deinit {
        liveLoopTask?.cancel()
        authTokenCancellable?.cancel()
    }
}

extension SyncController: Syncing {}
