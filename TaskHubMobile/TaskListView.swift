import Foundation
import SwiftUI
import SwiftData

struct TaskListView: View {
    let scope: TaskListScope
    @EnvironmentObject private var env: DefaultAppEnvironment
    private let completedRetentionInterval: TimeInterval = 24 * 60 * 60

    @Query
    private var allTasks: [TaskItem]
    @State private var pendingTaskIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false

    init(scope: TaskListScope) {
        self.scope = scope
        _allTasks = Query(sort: [SortDescriptor(\TaskItem.updatedAt, order: .reverse)])
    }

    private var visibleTasks: [TaskItem] {
        let cutoff = Date().addingTimeInterval(-completedRetentionInterval)
        let retained = allTasks.filter { !($0.completed && $0.updatedAt < cutoff) }
        let scoped: [TaskItem]
        switch scope {
        case .all:
            scoped = retained
        case .work:
            scoped = retained.filter { ($0.areaRaw ?? "").lowercased() == "work" }
        case .personal:
            scoped = retained.filter { ($0.areaRaw ?? "").lowercased() == "personal" }
        }
        return scoped.sorted(by: taskSort)
    }

    private func taskSort(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.completed != rhs.completed {
            return !lhs.completed && rhs.completed
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private var emptyDescription: String {
        switch scope {
        case .all:
            return "No tasks synced yet."
        case .work:
            return "No work tasks synced yet."
        case .personal:
            return "No personal tasks synced yet."
        }
    }

    var body: some View {
        Group {
            if visibleTasks.isEmpty {
                ContentUnavailableView("Tasks", systemImage: "checkmark.circle", description: Text(emptyDescription))
            } else {
                List(visibleTasks) { task in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            toggleCompletion(for: task)
                        } label: {
                            if pendingTaskIDs.contains(task.serverID) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.completed ? .green : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(pendingTaskIDs.contains(task.serverID))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .strikethrough(task.completed)
                                .foregroundStyle(task.completed ? .secondary : .primary)
                            if let due = task.dueAt {
                                Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let project = task.projectName ?? task.project, !project.isEmpty {
                                Text(project)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Tasks")
        .alert("Update Failed", isPresented: $isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func toggleCompletion(for task: TaskItem) {
        let taskID = task.serverID
        let newValue = !task.completed
        pendingTaskIDs.insert(taskID)
        Task {
            do {
                try await env.syncController.setTaskCompleted(taskID: taskID, completed: newValue)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isShowingError = true
                }
            }
            await MainActor.run {
                pendingTaskIDs.remove(taskID)
            }
        }
    }
}

#Preview {
    TaskListView(scope: .all)
        .modelContainer(for: TaskItem.self, inMemory: true)
}
