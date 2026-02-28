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

enum SyncTriggerSource: String {
    case manual
    case foreground
    case background
    case reconcile
    case remoteNotification
}

struct TaskCompletionMutationResult {
    let taskID: String
    let completed: Bool
    let updatedAt: Date?
    let elapsedMs: Int
}

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

    private lazy var liveActivityCoordinator = LiveActivityCoordinator(modelContainer: container)
    private let projectCache = LocalProjectCache(suiteName: nil)

    private var liveLoopTask: Task<Void, Never>? = nil
    private var authTokenCancellable: AnyCancellable? = nil
    private var stopLoopFlag = false
    private var uiTestModeEnabled: Bool { ProcessInfo.processInfo.environment["UITEST_MODE"] == "1" }
    private var uiTestStubMutationsEnabled: Bool { ProcessInfo.processInfo.environment["UITEST_STUB_MUTATIONS"] == "1" }
    private var uiTestForceToggleFailure: Bool { ProcessInfo.processInfo.environment["UITEST_FORCE_TOGGLE_FAILURE"] == "1" }

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
                self.stopLiveSyncLoop()
                Task { await self.engine?.resetLocalState() }
            } else {
                self.rebuildEngineIfPossible()
                self.triggerImmediateDelta(source: .reconcile)
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
                if self.authStore.accessToken != nil {
                    self.syncNow(source: .background)
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

    func triggerImmediateDelta(source: SyncTriggerSource = .reconcile) {
        backoffSeconds = 0
        nextAllowedSync = Date(timeIntervalSinceNow: 0)
        syncNow(source: source)
    }

    func syncNow() {
        syncNow(source: .manual)
    }

    func syncNow(source: SyncTriggerSource) {
        if isSyncing { return }
        if let next = nextAllowedSync, Date() < next { return }
        guard let engine else {
            lastError = "Sync engine unavailable."
            return
        }

        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.isSyncing = true
                    self.refreshLiveActivity(syncState: .syncing)
                }
                try await engine.performInitialOrDeltaSync()
                await MainActor.run {
                    self.isSyncing = false
                    self.lastSync = Date()
                    self.lastError = nil
                    self.backoffSeconds = 0
                    self.nextAllowedSync = nil
                    self.runPostSyncSideEffects()
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    os_log("[Sync] Success source=%{public}@ duration_ms=%{public}d", source.rawValue, elapsed)
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
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    os_log("[Sync] Failure source=%{public}@ duration_ms=%{public}d", source.rawValue, elapsed)
                    self.refreshLiveActivity(syncState: .retrying)
                }
            }
        }
    }

    private func runPostSyncSideEffects() {
        writeWidgetSnapshotFromStore()
        reloadWidgetTimelines()
        refreshLiveActivity(syncState: .upToDate)
        Task { await refreshProjectsCache() }
        if shouldRunBackfill() {
            Task { await backfillMissingAreas(limit: 20) }
        }
    }

    func createTask(title: String, area: TaskArea = .personal, priority: TaskPriority? = nil, projectName: String? = nil, dueAt: Date? = nil, repeatRule: RepeatRule? = nil) async throws {
        if uiTestModeEnabled && uiTestStubMutationsEnabled {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let item = TaskItem(
                serverID: "local-\(UUID().uuidString)",
                title: title,
                completed: false,
                updatedAt: Date(),
                dueAt: dueAt,
                project: projectName,
                projectId: projectName?.lowercased(),
                projectName: projectName,
                areaRaw: area.rawValue,
                priority: priority?.rawValue,
                recurrenceRaw: repeatRule?.rawValue
            )
            context.insert(item)
            try context.save()
            lastError = nil
            refreshWidgetAndLiveAfterMutation()
            return
        }

        guard let engine else { throw NSError(domain: "Sync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync engine unavailable"]) }

        let started = Date()
        let key = idStore.generate()
        idStore.save(key)

        do {
            try await engine.createTask(title: title, area: area, priority: priority, projectName: projectName, dueAt: dueAt, repeatRule: repeatRule, idempotencyKey: key.value)
            idStore.use(key)
            await MainActor.run {
                self.lastError = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                os_log("[CreateTask] Success duration_ms=%{public}d", elapsed)
                self.refreshWidgetAndLiveAfterMutation()
            }
            triggerImmediateDelta(source: .reconcile)
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                os_log("[CreateTask] Failure duration_ms=%{public}d", elapsed)
            }
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
        syncNow(source: .foreground)
    }

    func refreshWidgetSnapshot() {
        writeWidgetSnapshotFromStore()
        reloadWidgetTimelines()
        refreshLiveActivity(syncState: .upToDate)
    }

    private func reloadWidgetTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: taskHubHomeWidgetKind)
    }

    private func refreshLiveActivity(syncState: TaskHubLiveSyncState) {
        liveActivityCoordinator.refresh(syncState: syncState)
    }

    private func refreshWidgetAndLiveAfterMutation() {
        writeWidgetSnapshotFromStore()
        reloadWidgetTimelines()
        refreshLiveActivity(syncState: .upToDate)
    }

    func setTaskCompleted(taskID: String, completed: Bool, triggerReconcile: Bool = false) async throws -> TaskCompletionMutationResult {
        if uiTestModeEnabled && uiTestStubMutationsEnabled {
            if uiTestForceToggleFailure {
                throw NSError(domain: "UITest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated completion failure"])
            }
            let started = Date()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            if let item = all.first(where: { $0.serverID == taskID }) {
                item.completed = completed
                item.updatedAt = Date()
                try context.save()
            }
            refreshWidgetAndLiveAfterMutation()
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return TaskCompletionMutationResult(taskID: taskID, completed: completed, updatedAt: Date(), elapsedMs: elapsed)
        }

        guard let base = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }

        let started = Date()
        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let updated = try await client.updateTask(id: taskID, title: nil, completed: completed, dueAt: nil)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        if let item = all.first(where: { $0.serverID == taskID }) {
            apply(detail: updated, to: item)
            try context.save()
        }

        lastError = nil
        if triggerReconcile {
            syncNow(source: .reconcile)
        }
        refreshWidgetAndLiveAfterMutation()

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        os_log("[ToggleTask] task=%{public}@ completed=%{public}@ duration_ms=%{public}d", taskID, completed.description, elapsed)
        return TaskCompletionMutationResult(taskID: taskID, completed: completed, updatedAt: updated.updated_at, elapsedMs: elapsed)
    }

    func deferTaskDueDate(taskID: String, currentDueAt: Date?) async throws {
        if uiTestModeEnabled && uiTestStubMutationsEnabled {
            let baseDate = currentDueAt ?? Date()
            let deferred = Calendar.current.date(byAdding: .day, value: 1, to: baseDate) ?? baseDate.addingTimeInterval(24 * 60 * 60)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            if let item = all.first(where: { $0.serverID == taskID }) {
                item.dueAt = deferred
                item.updatedAt = Date()
                try context.save()
            }
            lastError = nil
            refreshWidgetAndLiveAfterMutation()
            return
        }

        guard let base = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }
        let baseDate = currentDueAt ?? Date()
        let deferred = Calendar.current.date(byAdding: .day, value: 1, to: baseDate) ?? baseDate.addingTimeInterval(24 * 60 * 60)

        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let updated = try await client.updateTask(id: taskID, title: nil, completed: nil, dueAt: deferred)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        if let item = all.first(where: { $0.serverID == taskID }) {
            apply(detail: updated, to: item)
            try context.save()
        }
        lastError = nil
        refreshWidgetAndLiveAfterMutation()
    }

    func setTaskDueDate(taskID: String, dueAt: Date) async throws {
        let normalizedDueAt = Calendar.current.startOfDay(for: dueAt)

        if uiTestModeEnabled && uiTestStubMutationsEnabled {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            if let item = all.first(where: { $0.serverID == taskID }) {
                item.dueAt = normalizedDueAt
                item.updatedAt = Date()
                try context.save()
            }
            lastError = nil
            refreshWidgetAndLiveAfterMutation()
            return
        }

        guard let base = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }

        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let updated = try await client.updateTask(id: taskID, title: nil, completed: nil, dueAt: normalizedDueAt)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        if let item = all.first(where: { $0.serverID == taskID }) {
            apply(detail: updated, to: item)
            try context.save()
        }
        lastError = nil
        refreshWidgetAndLiveAfterMutation()
    }

    func updateTask(
        taskID: String,
        title: String,
        area: TaskArea,
        priority: TaskPriority?,
        projectName: String?,
        dueAt: Date?,
        repeatRule: RepeatRule
    ) async throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw NSError(domain: "TaskEdit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Task title is required."])
        }

        let normalizedProjectName: String? = {
            guard let projectName else { return nil }
            let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let normalizedDueAt = dueAt.map { Calendar.current.startOfDay(for: $0) }

        if uiTestModeEnabled && uiTestStubMutationsEnabled {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            if let item = all.first(where: { $0.serverID == taskID }) {
                item.title = normalizedTitle
                item.areaRaw = area.rawValue
                item.priority = priority?.rawValue
                item.project = normalizedProjectName
                item.projectName = normalizedProjectName
                item.dueAt = normalizedDueAt ?? item.dueAt
                item.recurrenceRaw = repeatRule.rawValue
                item.updatedAt = Date()
                try context.save()
            }
            lastError = nil
            refreshWidgetAndLiveAfterMutation()
            return
        }

        guard let base = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }

        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let updated = try await client.updateTask(
            id: taskID,
            title: normalizedTitle,
            completed: nil,
            dueAt: normalizedDueAt,
            projectName: normalizedProjectName,
            area: area,
            priority: priority,
            repeatRule: repeatRule
        )

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        if let item = all.first(where: { $0.serverID == taskID }) {
            apply(detail: updated, to: item)
            try context.save()
        }
        lastError = nil
        refreshWidgetAndLiveAfterMutation()
        Task { await refreshProjectsCache() }
    }

    private func apply(detail: MobileTaskDetailDTO, to item: TaskItem) {
        item.title = detail.title
        item.completed = detail.is_completed
        item.updatedAt = detail.updated_at ?? Date()
        item.dueAt = detail.due_at
        item.project = detail.projectId
        item.projectId = detail.projectId
        item.projectName = detail.projectName
        item.priority = detail.priority
        item.recurrenceRaw = detail.recurrence?.rawValue
        if let area = detail.area {
            switch area {
            case .personal:
                item.areaRaw = "personal"
            case .work:
                item.areaRaw = "work"
            case .unknown(let value):
                item.areaRaw = value.lowercased()
            }
        }
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
                        item.priority = detail.priority
                        item.recurrenceRaw = detail.recurrence?.rawValue
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

    private func writeWidgetSnapshotFromStore(limit: Int = 40) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var descriptor = FetchDescriptor<TaskItem>(
                sortBy: [
                    SortDescriptor(\TaskItem.dueAt, order: .forward),
                    SortDescriptor(\TaskItem.updatedAt, order: .reverse)
                ]
            )
            descriptor.fetchLimit = limit
            let items: [TaskItem] = try context.fetch(descriptor)
            struct OutItem: Codable {
                enum CodingKeys: String, CodingKey {
                    case id
                    case title
                    case isCompleted = "is_completed"
                    case dueAt = "due_at"
                    case area
                    case projectName = "project_name"
                    case priority
                    case updatedAt = "updated_at"
                }
                let id: String
                let title: String
                let isCompleted: Bool
                let dueAt: Date?
                let area: String?
                let projectName: String?
                let priority: Int?
                let updatedAt: Date
            }
            struct OutSnapshot: Codable {
                enum CodingKeys: String, CodingKey {
                    case version
                    case generatedAt = "generated_at"
                    case count
                    case tasks
                }
                let version: Int
                let generatedAt: Date
                let count: Int
                let tasks: [OutItem]
            }
            let mapped = items.map {
                OutItem(
                    id: $0.serverID,
                    title: $0.title,
                    isCompleted: $0.completed,
                    dueAt: $0.dueAt,
                    area: $0.areaRaw,
                    projectName: $0.projectName ?? $0.project,
                    priority: $0.priority,
                    updatedAt: $0.updatedAt
                )
            }
            let incompleteCount = mapped.filter { !$0.isCompleted }.count
            let snapshot = OutSnapshot(
                version: 2,
                generatedAt: Date(),
                count: incompleteCount,
                tasks: mapped
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let url = widgetSnapshotURL(), let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: Data.WritingOptions.atomic)
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
