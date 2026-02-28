import Foundation
import SwiftUI
import SwiftData

struct TaskListView: View {
    let scope: TaskListScope
    let onMessage: (String, ToastStyle) -> Void

    @EnvironmentObject private var env: DefaultAppEnvironment

    private let completedRetentionInterval: TimeInterval = 24 * 60 * 60

    @Query
    private var allTasks: [TaskItem]

    @State private var pendingTaskIDs: Set<String> = []
    @State private var optimisticCompletion: [String: Bool] = [:]
    @State private var inlineErrorMessage: String?

    init(scope: TaskListScope, onMessage: @escaping (String, ToastStyle) -> Void) {
        self.scope = scope
        self.onMessage = onMessage
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
        let lhsCompleted = isTaskCompleted(lhs)
        let rhsCompleted = isTaskCompleted(rhs)
        if lhsCompleted != rhsCompleted {
            return !lhsCompleted && rhsCompleted
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private var emptyDescription: String {
        switch scope {
        case .all:
            return "No tasks yet. Use Quick Add to create your first one."
        case .work:
            return "No work tasks right now."
        case .personal:
            return "No personal tasks right now."
        }
    }

    var body: some View {
        Group {
            if visibleTasks.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "checklist",
                    description: Text(emptyDescription)
                )
            } else {
                List {
                    ForEach(visibleTasks) { task in
                        TaskCardRow(
                            task: task,
                            isCompleted: isTaskCompleted(task),
                            isPending: pendingTaskIDs.contains(task.serverID),
                            areaColor: areaColor(for: task)
                        ) {
                            toggleCompletion(for: task)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: DS.Spacing.md, bottom: 6, trailing: DS.Spacing.md))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(isTaskCompleted(task) ? "Mark Incomplete" : "Complete") {
                                toggleCompletion(for: task)
                            }
                            .tint(DS.Colors.success)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Defer") {
                                deferDueDate(for: task)
                            }
                            .tint(DS.Colors.warning)

                            Button("Edit") {
                                onMessage("Metadata editor is coming soon.", .info)
                            }
                            .tint(DS.Colors.accentAlt)

                            Button("Archive") {
                                onMessage("Archive support will ship in a follow-up update.", .info)
                            }
                            .tint(.gray)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(
                    LinearGradient(
                        colors: [Color.clear, DS.Colors.elevated.opacity(0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .overlay(alignment: .top) {
            if let inlineErrorMessage {
                Text(inlineErrorMessage)
                    .font(DS.Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.vertical, DS.Spacing.xs)
                    .padding(.horizontal, DS.Spacing.sm)
                    .background(DS.Colors.danger)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    .padding(.top, DS.Spacing.xs)
                    .accessibilityIdentifier("tasklist.inlineError")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func isTaskCompleted(_ task: TaskItem) -> Bool {
        optimisticCompletion[task.serverID] ?? task.completed
    }

    private func areaColor(for task: TaskItem) -> Color {
        if env.themeStore.areaTextColoringEnabled {
            if task.normalizedArea == .work {
                return env.themeStore.workColor
            }
            if task.normalizedArea == .personal {
                return env.themeStore.personalColor
            }
        }
        return DS.Colors.accent
    }

    private func toggleCompletion(for task: TaskItem) {
        let taskID = task.serverID
        let previous = isTaskCompleted(task)
        let newValue = !previous

        withAnimation(DS.Motion.quick) {
            pendingTaskIDs.insert(taskID)
            optimisticCompletion[taskID] = newValue
        }

        Task {
            do {
                _ = try await env.syncController.setTaskCompleted(taskID: taskID, completed: newValue, triggerReconcile: false)
                await MainActor.run {
                    withAnimation(DS.Motion.quick) {
                        pendingTaskIDs.remove(taskID)
                        optimisticCompletion.removeValue(forKey: taskID)
                    }
                }
                env.syncController.syncNow(source: .reconcile)
            } catch {
                await MainActor.run {
                    withAnimation(DS.Motion.quick) {
                        pendingTaskIDs.remove(taskID)
                        optimisticCompletion[taskID] = previous
                    }
                    onMessage(error.localizedDescription, .error)
                    inlineErrorMessage = error.localizedDescription
                }
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run {
                        withAnimation(DS.Motion.quick) {
                            _ = optimisticCompletion.removeValue(forKey: taskID)
                        }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run { inlineErrorMessage = nil }
                }
            }
        }
    }

    private func deferDueDate(for task: TaskItem) {
        Task {
            do {
                try await env.syncController.deferTaskDueDate(taskID: task.serverID, currentDueAt: task.dueAt)
                await MainActor.run {
                    onMessage("Deferred to tomorrow.", .success)
                }
                env.syncController.syncNow(source: .reconcile)
            } catch {
                await MainActor.run {
                    onMessage(error.localizedDescription, .error)
                }
            }
        }
    }
}

struct TaskCardRow: View {
    let task: TaskItem
    let isCompleted: Bool
    let isPending: Bool
    let areaColor: Color
    let onToggleComplete: () -> Void

    private var dueText: String? {
        guard let due = task.dueAt else { return nil }
        return due.formatted(date: .abbreviated, time: .omitted)
    }

    private var dueIsOverdue: Bool {
        guard let due = task.dueAt else { return false }
        return due < Calendar.current.startOfDay(for: Date()) && !isCompleted
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            RoundedRectangle(cornerRadius: DS.Radius.pill)
                .fill(areaColor.opacity(isCompleted ? 0.28 : 0.9))
                .frame(width: 5)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    completionButton
                    Text(task.title)
                        .font(DS.Typography.body)
                        .strikethrough(isCompleted)
                        .foregroundStyle(isCompleted ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: DS.Spacing.xs) {
                    if let dueText {
                        InfoChip(
                            text: dueIsOverdue ? "Overdue \(dueText)" : "Due \(dueText)",
                            tint: dueIsOverdue ? DS.Colors.danger : .secondary
                        )
                    }

                    if let project = task.projectName ?? task.project, !project.isEmpty {
                        InfoChip(text: project, tint: areaColor)
                    }

                    if let area = task.normalizedArea {
                        InfoChip(text: area == .work ? "Work" : "Personal", tint: areaColor)
                    }

                    if let priority = task.priorityLabel {
                        InfoChip(text: priority, tint: DS.Colors.accentAlt)
                    }
                }

                if let repeatRule = task.repeatRule, repeatRule != .none {
                    Text("Repeats \(repeatRule.rawValue.capitalized)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .accessibilityIdentifier("task.row.\(task.serverID)")
        .animation(DS.Motion.quick, value: isCompleted)
    }

    private var completionButton: some View {
        Button(action: onToggleComplete) {
            Group {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCompleted ? DS.Colors.success : .secondary)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityLabel(isCompleted ? "Mark incomplete" : "Mark complete")
        .accessibilityIdentifier("task.toggle.\(task.serverID)")
    }
}

struct InfoChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(DS.Typography.caption)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

#Preview {
    TaskListView(scope: .all) { _, _ in }
        .modelContainer(for: TaskItem.self, inMemory: true)
        .environmentObject(DefaultAppEnvironment())
}
