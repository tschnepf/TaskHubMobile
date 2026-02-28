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
#if canImport(UIKit)
import UIKit
#endif

actor LocalProjectCache {
    private var names: [String] = []
    private let defaults: UserDefaults
    private let storageKey = "project.names"

    init(suiteName: String? = nil) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
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
    private var lastBackfillAt: Date?
    private let backfillMinimumInterval: TimeInterval = 15 * 60

    private lazy var widgetCache: WidgetCache = {
        let appConfig = self.appConfig
        let authStore = self.authStore
        return WidgetCache(appGroupID: AppIdentifiers.appGroupID, apiClientProvider: {
            APIClient(baseURLProvider: { appConfig.baseURL }, authStore: authStore)
        })
    }()
    private let projectCache = LocalProjectCache(suiteName: nil)
    
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

    private func preferredLiveSyncInterval() -> TimeInterval {
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active:
            return 20
        case .inactive:
            return 45
        case .background:
            return 90
        @unknown default:
            return 30
        }
        #else
        return 30
        #endif
    }

    private func shouldRunBackfill(now: Date = Date()) -> Bool {
        guard let lastBackfillAt else {
            self.lastBackfillAt = now
            return true
        }
        guard now.timeIntervalSince(lastBackfillAt) >= backfillMinimumInterval else {
            return false
        }
        self.lastBackfillAt = now
        return true
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
                let baseInterval = self.preferredLiveSyncInterval()
                let adaptive = self.backoffSeconds > 0 ? max(baseInterval, self.backoffSeconds) : baseInterval
                var delay = Int(max(10, min(120, adaptive)))
                if self.isSyncing { delay = min(120, delay + 5) }
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
        guard let engine else {
            lastError = "Sync engine unavailable."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run { self.isSyncing = true }
                try await engine.performInitialOrDeltaSync()
                await MainActor.run {
                    self.isSyncing = false
                    self.lastSync = Date()
                    self.lastError = nil
                    self.backoffSeconds = 0
                    self.nextAllowedSync = nil
                    Task { await self.widgetCache.refreshSnapshotIfNeeded(); WidgetCenter.shared.reloadAllTimelines() }
                    self.writeWidgetSnapshotFromStore()
                    WidgetCenter.shared.reloadAllTimelines()
                    Task { await self.refreshProjectsCache() }
                    if self.shouldRunBackfill() {
                        Task { await self.backfillMissingAreas(limit: 20) }
                    }
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
        self.writeWidgetSnapshotFromStore()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func setTaskCompleted(taskID: String, completed: Bool) async throws {
        guard let base = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }

        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let updated = try await client.updateTask(id: taskID, title: nil, completed: completed, dueAt: nil)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        if let item = all.first(where: { $0.serverID == taskID }) {
            item.completed = updated.is_completed
            if let updatedAt = updated.updated_at {
                item.updatedAt = updatedAt
            } else {
                item.updatedAt = Date()
            }
            item.dueAt = updated.due_at
            item.project = updated.projectId
            item.projectId = updated.projectId
            item.projectName = updated.projectName
            if let area = updated.area {
                switch area {
                case .personal:
                    item.areaRaw = "personal"
                case .work:
                    item.areaRaw = "work"
                case .unknown(let value):
                    item.areaRaw = value.lowercased()
                }
            }
            try context.save()
        }

        lastError = nil
        triggerImmediateDelta()
    }
    
    private func backfillMissingAreas(limit: Int = 50) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.areaRaw == nil || $0.areaRaw == "" },
                sortBy: [SortDescriptor(\TaskItem.updatedAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let missing: [TaskItem] = try context.fetch(descriptor)
            guard !missing.isEmpty else { return }
            guard let base = appConfig.baseURL else { return }
            let client = APIClient(baseURLProvider: { base }, authStore: authStore)
            for item in missing {
                do {
                    let detail = try await client.getTaskDetail(id: item.serverID)
                    if let area = detail.area {
                        switch area {
                        case .personal: item.areaRaw = "personal"
                        case .work: item.areaRaw = "work"
                        case .unknown(let s): item.areaRaw = s.lowercased()
                        }
                        try? context.save()
                    }
                } catch {
                    // Ignore individual failures and continue
                }
            }
        } catch {
            // Ignore fetch failures
        }
    }
    
    // MARK: - Widget Snapshot Writing
    private func widgetSnapshotURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupID) else { return nil }
        let dir = container.appendingPathComponent("widget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget_tasks.json")
    }

    private func writeWidgetSnapshotFromStore(limit: Int = 7) {
        // Build a throwaway ModelContext to perform a read-only fetch
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var descriptor = FetchDescriptor<TaskItem>(
                sortBy: [
                    SortDescriptor(\TaskItem.dueAt, order: .forward),
                    SortDescriptor(\TaskItem.title, order: .forward)
                ]
            )
            descriptor.fetchLimit = limit
            let items = try context.fetch(descriptor)
            struct OutItem: Codable {
                enum CodingKeys: String, CodingKey { case title, isCompleted = "is_completed", dueAt = "due_at" }
                let title: String; let isCompleted: Bool; let dueAt: Date?
            }
            struct OutSnapshot: Codable { let count: Int; let tasks: [OutItem] }
            let mapped = items.map { OutItem(title: $0.title, isCompleted: $0.completed, dueAt: $0.dueAt) }
            let snapshot = OutSnapshot(count: mapped.count, tasks: mapped)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let url = widgetSnapshotURL(), let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        } catch {
            // Ignore snapshot write errors; widget will show placeholder or empty state
        }
    }
    
    deinit {
        liveLoopTask?.cancel()
        authTokenCancellable?.cancel()
    }
}

extension SyncController: Syncing {}
