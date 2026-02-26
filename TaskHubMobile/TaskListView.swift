//
//  TaskListView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI
import SwiftData

enum TaskListScope: Hashable {
    case all
    case work
    case personal
}

struct TaskListView: View {
    let scope: TaskListScope
    @Query private var tasks: [TaskItem]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appConfig: AppConfig
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var syncController: SyncController
    @State private var editTaskID: String? = nil
    @State private var editTitle: String = ""
    @State private var expandedTaskID: String? = nil
    @State private var editHasDueDate: Bool = false
    @State private var editDueDate: Date = .now
    @State private var editArea: TaskArea = .personal
    @State private var editPriority: TaskPriority = .three
    @State private var editRepeat: RepeatRule = .none
    @State private var editProjectName: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSaving: Bool = false
    
    @State private var editDirty: Bool = false
    @State private var editCancelled: Bool = false

    init(scope: TaskListScope = .all) {
        self.scope = scope
        let sort = [SortDescriptor(\TaskItem.updatedAt, order: .reverse)]
        _tasks = Query(sort: sort)
    }

    private var displayedTasks: [TaskItem] {
        switch scope {
        case .all:
            return tasks
        case .work:
            let explicit = tasks.filter { $0.areaRaw == "work" }
            let fallback = tasks.filter { ($0.areaRaw == nil || $0.areaRaw == "") && (($0.projectId != nil) || ((($0.projectName) ?? "").isEmpty == false)) }
            var map: [String: TaskItem] = [:]
            for t in explicit { map[t.serverID] = t }
            for t in fallback { map[t.serverID] = t }
            return map.values.sorted(by: { $0.updatedAt > $1.updatedAt })
        case .personal:
            let explicit = tasks.filter { $0.areaRaw == "personal" }
            let fallback = tasks.filter { ($0.areaRaw == nil || $0.areaRaw == "") && ($0.projectId == nil) && ((($0.projectName) ?? "").isEmpty) }
            var map: [String: TaskItem] = [:]
            for t in explicit { map[t.serverID] = t }
            for t in fallback { map[t.serverID] = t }
            return map.values.sorted(by: { $0.updatedAt > $1.updatedAt })
        }
    }

    var body: some View {
        if displayedTasks.isEmpty {
            ContentUnavailableView("No Tasks", systemImage: "checklist", description: Text("Your tasks will appear here automatically."))
        } else {
            List(displayedTasks) { task in
                HStack(alignment: .center, spacing: 0) {
                    // Compact completion button
                    Button {
                        toggleComplete(task)
                    } label: {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.completed ? .green : .secondary)
                            .imageScale(.large)
                            .frame(width: 36, height: 36, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer().frame(width: 6)

                    // Right side opens inline editor
                    Button {
                        Task { await startEdit(task) }
                    } label: {
                        VStack(alignment: .leading) {
                            if let name = task.projectName, !name.isEmpty {
                                Text("\(name) \(task.title)")
                            } else {
                                Text(task.title)
                            }
                            Text(task.updatedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Inline editor expands between rows
                if expandedTaskID == task.serverID {
                    VStack(alignment: .leading, spacing: 12) {
                        // Title
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Title").font(.caption).foregroundStyle(.secondary)
                            TextField("Task title", text: $editTitle)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Area
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Area").font(.caption).foregroundStyle(.secondary)
                            Picker("Area", selection: $editArea) {
                                Text("Personal").tag(TaskArea.personal)
                                Text("Work").tag(TaskArea.work)
                            }
                            .pickerStyle(.segmented)
                        }

                        // Priority
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Priority").font(.caption).foregroundStyle(.secondary)
                            Picker("Priority", selection: $editPriority) {
                                ForEach(TaskPriority.allCases) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                        }

                        // Repeat
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Repeat").font(.caption).foregroundStyle(.secondary)
                            Picker("Repeat", selection: $editRepeat) {
                                ForEach(RepeatRule.allCases) { r in
                                    Text(r.rawValue.capitalized).tag(r)
                                }
                            }
                        }

                        // Project
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Project").font(.caption).foregroundStyle(.secondary)
                            TextField("Project (optional)", text: $editProjectName)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Due Date
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Has due date", isOn: $editHasDueDate.animation())
                            if editHasDueDate {
                                DatePicker("Due Date", selection: $editDueDate, displayedComponents: [.date])
                            }
                        }

                        HStack {
                            Button("Cancel") {
                                editCancelled = true
                                withAnimation { expandedTaskID = nil }
                            }
                            Spacer()
                            Button(action: { Task { await saveEdits() } }) {
                                if isSaving {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                } else {
                                    Text("Save")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                        }
                    }
                    .padding(.vertical, 8)
                    .onChange(of: editTitle) { _, _ in editDirty = true }
                    .onChange(of: editHasDueDate) { _, _ in editDirty = true }
                    .onChange(of: editDueDate) { _, _ in editDirty = true }
                    .onChange(of: editArea) { _, _ in editDirty = true }
                    .onChange(of: editPriority) { _, _ in editDirty = true }
                    .onChange(of: editRepeat) { _, _ in editDirty = true }
                    .onChange(of: editProjectName) { _, _ in editDirty = true }
                }
            }
            .listStyle(.plain)
            .refreshable { syncController.syncNow() }
            .onChange(of: expandedTaskID) { _, newValue in
                if newValue == nil, editDirty, !editCancelled {
                    Task { await saveEdits() }
                }
                if newValue == nil { editCancelled = false }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startEdit(_ task: TaskItem) async {
        if expandedTaskID == task.serverID {
            withAnimation { expandedTaskID = nil }
            return
        }
        if let current = expandedTaskID, current != task.serverID, editDirty {
            await saveEdits()
        }
        editTaskID = task.serverID
        editTitle = task.title
        if let due = task.dueAt { editDueDate = due; editHasDueDate = true } else { editHasDueDate = false }
        editProjectName = task.projectName ?? ""
        // Reset or keep other edit fields as needed
        withAnimation { expandedTaskID = task.serverID }
        editDirty = false
        editCancelled = false
    }

    @MainActor
    private func saveEdits() async
    {
        guard let id = editTaskID else { return }
        isSaving = true
        defer { isSaving = false }
        print("[Edit] Save tapped for id=\(id)")
        let client = APIClient(baseURLProvider: { appConfig.baseURL }, authStore: authStore)
        let due = editHasDueDate ? editDueDate : nil
        do {
            _ = try await client.updateTask(
                id: id,
                title: editTitle,
                completed: nil,
                dueAt: due,
                projectName: editProjectName.isEmpty ? nil : editProjectName,
                area: editArea,
                priority: editPriority,
                repeatRule: editRepeat
            )
            if let item = try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.serverID == id })).first {
                item.title = editTitle
                item.dueAt = due
                item.project = editProjectName.isEmpty ? nil : editProjectName
                item.projectName = editProjectName.isEmpty ? nil : editProjectName
                item.areaRaw = editArea.rawValue
                item.updatedAt = Date()
                try? modelContext.save()
            }
            editDirty = false
            withAnimation { expandedTaskID = nil }
            editTaskID = nil
            print("[Edit] Save completed for id=\(id)")
        } catch {
            print("[Edit] Save failed for id=\(id):", error.localizedDescription)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteTask(_ task: TaskItem) {
        modelContext.delete(task)
        try? modelContext.save()
    }

    private func toggleComplete(_ task: TaskItem) {
        task.completed.toggle()
        task.updatedAt = Date()
        try? modelContext.save()
    }
}

#Preview {
    TaskListView()
        .modelContainer(for: TaskItem.self, inMemory: true)
}

