//
//  TaskListView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI
import SwiftData

struct TaskListView: View {
    @Query(sort: \TaskItem.updatedAt, order: .reverse) private var tasks: [TaskItem]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appConfig: AppConfig
    @EnvironmentObject private var authStore: AuthStore
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

    var body: some View {
        if tasks.isEmpty {
            ContentUnavailableView("No Tasks", systemImage: "checklist", description: Text("Your tasks will appear here automatically."))
        } else {
            List(tasks) { task in
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
                        startEdit(task)
                    } label: {
                        VStack(alignment: .leading) {
                            if let name = task.project, !name.isEmpty {
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
                }
            }
            .listStyle(.plain)
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startEdit(_ task: TaskItem) {
        if expandedTaskID == task.serverID {
            withAnimation { expandedTaskID = nil }
            editTaskID = nil
            return
        }
        editTaskID = task.serverID
        editTitle = task.title
        if let due = task.dueAt { editDueDate = due; editHasDueDate = true } else { editHasDueDate = false }
        editArea = .personal
        editPriority = .three
        editRepeat = .none
        editProjectName = ""
        withAnimation { expandedTaskID = task.serverID }
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
                item.updatedAt = Date()
                try? modelContext.save()
            }
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
