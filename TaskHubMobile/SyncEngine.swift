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
                    areaRaw: dto.area?.rawValue
                )
                context.insert(item)
            }
        }

        for item in existing where !incomingIDs.contains(item.serverID) {
            context.delete(item)
        }

        try context.save()
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
                        areaRaw: dto.area?.rawValue
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

        func parseISO8601(_ s: String) -> Date? {
            let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: s) { return d }
            let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: s)
        }

        do {
            var all = try context.fetch(FetchDescriptor<TaskItem>())

            for e in events {
                let serverID = e.task_id ?? ""
                let summary = e.payload_summary ?? [:]
                var title: String? = nil
                var isCompleted: Bool = false
                var dueAt: Date? = nil
                var updatedAt: Date = e.occurred_at
                var project: String? = nil
                var projectName: String? = nil
                var areaValue: String? = nil

                if let v = summary["title"], case let MobileDeltaJSONValue.string(t) = v { title = t }
                if let v = summary["is_completed"], case let MobileDeltaJSONValue.bool(b) = v { isCompleted = b }
                if let v = summary["due_at"], case let MobileDeltaJSONValue.string(s) = v { dueAt = parseISO8601(s) }
                if let v = summary["updated_at"], case let MobileDeltaJSONValue.string(s) = v, let d = parseISO8601(s) { updatedAt = d }
                if let v = summary["project"], case let MobileDeltaJSONValue.string(p) = v { project = p }
                if let v = summary["project_name"], case let MobileDeltaJSONValue.string(n) = v { projectName = n }
                if let v = summary["area"], case let MobileDeltaJSONValue.string(a) = v { areaValue = a.lowercased() }

                print("[Import] Event type=\(e.event_type) serverID=\(serverID) tombstone=\(e.tombstone) title=\(title ?? "<nil>")")

                if e.tombstone || e.event_type == "task.deleted" || e.event_type.hasSuffix(".deleted") {
                    // Delete if exists
                    if let idx = all.firstIndex(where: { $0.serverID == serverID }) {
                        let existing = all.remove(at: idx)
                        context.delete(existing)
                    }
                    continue
                }

                if let idx = all.firstIndex(where: { $0.serverID == serverID }) {
                    let existing = all[idx]
                    if let t = title { existing.title = t }
                    existing.completed = isCompleted
                    existing.dueAt = dueAt
                    existing.updatedAt = updatedAt
                    if let p = project { existing.project = p; existing.projectId = p }
                    if let n = projectName { existing.projectName = n }
                    if let a = areaValue { existing.areaRaw = a }
                } else {
                    let newItem = TaskItem(serverID: serverID, title: title ?? "Untitled", completed: isCompleted, updatedAt: updatedAt, dueAt: dueAt, project: project, projectId: project, projectName: projectName, areaRaw: areaValue)
                    context.insert(newItem)
                    all.append(newItem)
                }
            }
            try context.save()
            print("[Import] Saved batch. New cursor:", newCursor)
            saveCursor(newCursor)
        } catch {
            throw error
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
        let iso: (Date) -> String = { d in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
        }
        let body = CreateTaskBody(
            title: title,
            project: projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
            area: area,
            priority: priority?.rawValue,
            due_at: dueAt.map(iso),
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

