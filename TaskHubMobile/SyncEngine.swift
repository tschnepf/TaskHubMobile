//
//  SyncEngine.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import SwiftData

enum SyncError: Error {
    case cursorExpired
}

fileprivate enum SyncDateCodec {
    nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static func parse(_ value: String) -> Date? {
        if let withFractional = iso8601Fractional.date(from: value) {
            return withFractional
        }
        return iso8601.date(from: value)
    }

    nonisolated static func string(from date: Date) -> String {
        iso8601Fractional.string(from: date)
    }
}

actor SyncEngine {
    private let api: APIClient
    private let container: ModelContainer

    private let cursorNamespace: String
    private var cursorKey: String { "sync.cursor." + cursorNamespace }

    init(api: APIClient, modelContainer: ModelContainer, cursorNamespace: String = "default") {
        self.api = api
        self.container = modelContainer
        self.cursorNamespace = cursorNamespace
    }

    func apiForUtilities() -> APIClient { api }

    func runDeltaSync() async throws {
        let cursor = currentCursor() ?? ""
        try await runDelta(cursor: cursor)
    }

    func currentCursor() -> String? {
        UserDefaults.standard.string(forKey: cursorKey)
    }

    private func saveCursor(_ cursor: String?) {
        if let cursor { UserDefaults.standard.set(cursor, forKey: cursorKey) }
        else { UserDefaults.standard.removeObject(forKey: cursorKey) }
    }

    @MainActor
    private func fetchDelta(cursor: String?) async throws -> MobileDeltaResponse {
        if let c = cursor, !c.isEmpty {
            return try await api.get("api/mobile/v1/sync/delta", query: [URLQueryItem(name: "cursor", value: c)])
        } else {
            return try await api.get("api/mobile/v1/sync/delta", query: [])
        }
    }

    @MainActor
    private func fetchFullList() async throws -> [TaskDTO] {
        return try await api.get("api/mobile/v1/tasks")
    }

    func performInitialOrDeltaSync() async throws {
        // If local store is empty, a cursor-only delta can produce no rows.
        // Force full snapshot bootstrap so the UI always has a baseline.
        if localTaskCount() == 0 {
            try await runFullSync()
            return
        }
        let cursor = currentCursor()
        if let cursor, !cursor.isEmpty {
            try await runDelta(cursor: cursor)
        } else {
            try await runFullSync()
        }
    }

    func forceFullResync() async {
        saveCursor(nil)
        do { try await runFullSync() } catch { /* TODO: surface error */ }
    }

    private func runFullSync() async throws {
        print("[Sync] FULL RESYNC: /api/mobile/v1/tasks then baseline cursor")
        // 1) Fetch full list and replace local snapshot
        try await runFullListSync()
        // 2) Fetch a baseline delta with no cursor to get a fresh next_cursor
        let baseline = try await fetchDelta(cursor: nil)
        if let next = baseline.next_cursor { saveCursor(next) }
    }

    private func runFullListSync() async throws {
        print("[Sync] GET /api/mobile/v1/tasks (full list)")
        let tasks: [TaskDTO] = try await fetchFullList()
        try await replaceAllTasks(with: tasks)
    }

    private func replaceAllTasks(with tasks: [TaskDTO]) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<TaskItem>())
        var existingByID: [String: TaskItem] = [:]
        for item in existing { existingByID[item.serverID] = item }

        let incomingIDs = Set(tasks.map { $0.id })

        for dto in tasks {
            if let current = existingByID[dto.id] {
                current.title = dto.title
                current.completed = dto.is_completed
                current.dueAt = dto.due_at
                current.updatedAt = dto.updated_at
                // Map project fields distinctly
                if let pid = dto.project { current.project = pid; current.projectId = pid }
                if let pname = dto.project_name { current.projectName = pname }
                if let area = dto.area { current.areaRaw = area.rawValue }
                current.priority = dto.priority
                if let recurrence = dto.recurrence {
                    current.recurrenceRaw = recurrence.rawValue
                }
            } else {
                let item = TaskItem(
                    serverID: dto.id,
                    title: dto.title,
                    completed: dto.is_completed,
                    updatedAt: dto.updated_at,
                    dueAt: dto.due_at,
                    project: dto.project,
                    projectId: dto.project,
                    projectName: dto.project_name,
                    areaRaw: dto.area?.rawValue,
                    priority: dto.priority,
                    recurrenceRaw: dto.recurrence?.rawValue
                )
                context.insert(item)
            }
        }

        for item in existing where !incomingIDs.contains(item.serverID) {
            context.delete(item)
        }

        try context.save()
        try pruneExpiredCompletedTasks(in: context)
    }

    private func localTaskCount() -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<TaskItem>()
        let items = (try? context.fetch(descriptor)) ?? []
        return items.count
    }

    private func importTasks(_ tasks: [TaskDTO]) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            for dto in tasks {
                if let existing = all.first(where: { $0.serverID == dto.id }) {
                    existing.title = dto.title
                    existing.completed = dto.is_completed
                    existing.dueAt = dto.due_at
                    existing.updatedAt = dto.updated_at
                    // Map project fields distinctly
                    existing.project = dto.project // legacy
                    existing.projectId = dto.project
                    if let name = dto.project_name { existing.projectName = name }
                    existing.areaRaw = dto.area?.rawValue
                    existing.priority = dto.priority
                    if let recurrence = dto.recurrence {
                        existing.recurrenceRaw = recurrence.rawValue
                    }
                } else {
                    let item = TaskItem(
                        serverID: dto.id,
                        title: dto.title,
                        completed: dto.is_completed,
                        updatedAt: dto.updated_at,
                        dueAt: dto.due_at,
                        project: dto.project,
                        projectId: dto.project,
                        projectName: dto.project_name,
                        areaRaw: dto.area?.rawValue,
                        priority: dto.priority,
                        recurrenceRaw: dto.recurrence?.rawValue
                    )
                    context.insert(item)
                }
            }
            try context.save()
        } catch {
            throw error
        }
    }

    private func runDelta(cursor: String) async throws {
        print("[Sync] GET /api/mobile/v1/sync/delta with cursor:", cursor)
        do {
            let response = try await fetchDelta(cursor: cursor)
            try await importEvents(response.events, newCursor: response.next_cursor ?? cursor)
        } catch {
            // Map server error envelope to cursor_expired when possible
            if let apiErr = error as? APIClientError {
                switch apiErr {
                case .serverError(let code, _, _, _):
                    if code == "cursor_expired" {
                        // Full resync path: replace snapshot, then fetch baseline cursor
                        saveCursor(nil)
                        try await runFullListSync()
                        let baseline = try await fetchDelta(cursor: nil)
                        if let next = baseline.next_cursor { saveCursor(next) }
                        return
                    }
                default: break
                }
            }
            throw error
        }
    }

    private func importEvents(_ events: [MobileDeltaEvent], newCursor: String) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        do {
            let existing = try context.fetch(FetchDescriptor<TaskItem>())
            var tasksByServerID: [String: TaskItem] = [:]
            tasksByServerID.reserveCapacity(existing.count)
            for item in existing {
                tasksByServerID[item.serverID] = item
            }

            for e in events {
                let serverID = (e.task_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !serverID.isEmpty else {
                    continue
                }
                let summary = e.payload_summary ?? [:]

                let hasTitle = summary["title"] != nil
                let hasCompleted = summary["is_completed"] != nil
                let hasDueAt = summary["due_at"] != nil
                let hasUpdatedAt = summary["updated_at"] != nil
                let hasProject = summary["project"] != nil
                let hasProjectName = summary["project_name"] != nil
                let hasArea = summary["area"] != nil
                let hasPriority = summary["priority"] != nil
                let hasRecurrence = summary["recurrence"] != nil

                var title: String? = nil
                if case let .string(value)? = summary["title"] {
                    title = value
                }

                var isCompleted: Bool? = nil
                if let completedValue = summary["is_completed"] {
                    switch completedValue {
                    case let .bool(value):
                        isCompleted = value
                    case let .number(value):
                        isCompleted = value != 0
                    case let .string(value):
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        isCompleted = ["1", "true", "yes", "on", "done", "archived"].contains(normalized)
                    default:
                        break
                    }
                }

                var dueAt: Date?? = nil
                if let dueValue = summary["due_at"] {
                    switch dueValue {
                    case let .string(value):
                        dueAt = SyncDateCodec.parse(value)
                    case .null:
                        dueAt = nil
                    default:
                        break
                    }
                }

                var updatedAt: Date? = nil
                if case let .string(value)? = summary["updated_at"],
                   let parsed = SyncDateCodec.parse(value) {
                    updatedAt = parsed
                }

                var project: String? = nil
                if let projectValue = summary["project"] {
                    switch projectValue {
                    case let .string(value):
                        project = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .null:
                        project = nil
                    default:
                        break
                    }
                }

                var projectName: String? = nil
                if let projectNameValue = summary["project_name"] {
                    switch projectNameValue {
                    case let .string(value):
                        projectName = value
                    case .null:
                        projectName = nil
                    default:
                        break
                    }
                }

                var areaValue: String? = nil
                if let areaSummary = summary["area"] {
                    switch areaSummary {
                    case let .string(value):
                        areaValue = value.lowercased()
                    case .null:
                        areaValue = nil
                    default:
                        break
                    }
                }

                var priorityValue: Int? = nil
                if let prioritySummary = summary["priority"] {
                    switch prioritySummary {
                    case let .number(value):
                        priorityValue = Int(value)
                    case let .string(value):
                        priorityValue = Int(value)
                    case .null:
                        priorityValue = nil
                    default:
                        break
                    }
                }

                var recurrenceValue: String? = nil
                if let recurrenceSummary = summary["recurrence"] {
                    switch recurrenceSummary {
                    case let .string(value):
                        recurrenceValue = value.lowercased()
                    case .null:
                        recurrenceValue = nil
                    default:
                        break
                    }
                }

                print("[Import] Event type=\(e.event_type) serverID=\(serverID) tombstone=\(e.tombstone) title=\(title ?? "<nil>")")

                if e.tombstone || e.event_type == "task.deleted" || e.event_type.hasSuffix(".deleted") {
                    if let existingTask = tasksByServerID.removeValue(forKey: serverID) {
                        context.delete(existingTask)
                    }
                    continue
                }

                if let existingTask = tasksByServerID[serverID] {
                    if hasTitle, let title {
                        existingTask.title = title
                    }
                    if hasCompleted, let isCompleted {
                        existingTask.completed = isCompleted
                    }
                    if hasDueAt {
                        existingTask.dueAt = dueAt ?? nil
                    }
                    if hasUpdatedAt {
                        existingTask.updatedAt = updatedAt ?? e.occurred_at
                    }
                    if hasProject {
                        existingTask.project = project
                        existingTask.projectId = project
                    }
                    if hasProjectName {
                        existingTask.projectName = projectName
                    }
                    if hasArea {
                        existingTask.areaRaw = areaValue
                    }
                    if hasPriority {
                        existingTask.priority = priorityValue
                    }
                    if hasRecurrence {
                        existingTask.recurrenceRaw = recurrenceValue
                    }
                } else {
                    let newItem = TaskItem(
                        serverID: serverID,
                        title: title ?? "Untitled",
                        completed: isCompleted ?? false,
                        updatedAt: updatedAt ?? e.occurred_at,
                        dueAt: dueAt ?? nil,
                        project: project,
                        projectId: project,
                        projectName: projectName,
                        areaRaw: areaValue,
                        priority: priorityValue,
                        recurrenceRaw: recurrenceValue
                    )
                    context.insert(newItem)
                    tasksByServerID[serverID] = newItem
                }
            }

            let cutoff = Date().addingTimeInterval(-(24 * 60 * 60))
            for item in tasksByServerID.values where item.completed && item.updatedAt < cutoff {
                context.delete(item)
            }
            try context.save()
            print("[Import] Saved batch. New cursor:", newCursor)
            saveCursor(newCursor)
        } catch {
            throw error
        }
    }

    private func pruneExpiredCompletedTasks(in context: ModelContext) throws {
        let cutoff = Date().addingTimeInterval(-(24 * 60 * 60))
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        var removed = false
        for item in all where item.completed && item.updatedAt < cutoff {
            context.delete(item)
            removed = true
        }
        if removed {
            try context.save()
        }
    }

    func resetLocalState() async {
        saveCursor(nil)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        if let items = try? context.fetch(FetchDescriptor<TaskItem>()) {
            for item in items { context.delete(item) }
            try? context.save()
        }
    }

    func createTask(title: String, area: TaskArea = .personal, priority: TaskPriority? = nil, projectName: String? = nil, dueAt: Date? = nil, repeatRule: RepeatRule? = nil, idempotencyKey: String) async throws {
        struct CreateTaskBody: Encodable {
            let title: String
            let project: String?
            let area: TaskArea
            let priority: Int?
            let due_at: String?
            let recurrence: RepeatRule?
        }
        let body = CreateTaskBody(
            title: title,
            project: projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
            area: area,
            priority: priority?.rawValue,
            due_at: dueAt.map { SyncDateCodec.string(from: $0) },
            recurrence: repeatRule
        )
        let _: EmptyDecodable = try await api.post("api/mobile/v1/tasks", body: body, idempotencyKey: idempotencyKey)
        // After a successful create, trigger a quick delta sync to pull new state
        try await runDelta(cursor: currentCursor() ?? "")
    }

    private struct TaskDTO: Decodable {
        let id: String
        let title: String
        let is_completed: Bool
        let due_at: Date?
        let updated_at: Date
        let project: String?
        let project_name: String?
        let area: TaskArea?
        let priority: Int?
        let recurrence: RepeatRule?
    }

    private struct EmptyDecodable: Decodable {}
}
