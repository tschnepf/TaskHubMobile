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
    @State private var editTaskID: String? = nil
    @State private var editTitle: String = ""
    @State private var expandedTaskID: String? = nil

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
                            Text(task.title)
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Title").font(.caption).foregroundStyle(.secondary)
                            TextField("Task title", text: $editTitle)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button("Cancel") {
                                withAnimation { expandedTaskID = nil }
                            }
                            Spacer()
                            Button("Save") {
                                saveEdits()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.plain)
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
        withAnimation { expandedTaskID = task.serverID }
    }

    private func saveEdits() {
        guard let id = editTaskID else { return }
        // Fetch the task by id from the modelContext
        if let item = try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.serverID == id })).first {
            item.title = editTitle
            item.updatedAt = Date()
            try? modelContext.save()
        }
        withAnimation { expandedTaskID = nil }
        editTaskID = nil
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
