import Foundation
import SwiftUI
import SwiftData

struct TaskListView: View {
    let scope: TaskListScope
    let density: TaskDensity
    let onMessage: (String, ToastStyle) -> Void

    @EnvironmentObject private var env: DefaultAppEnvironment

    private let completedRetentionInterval: TimeInterval = 24 * 60 * 60

    @Query
    private var allTasks: [TaskItem]

    @State private var pendingTaskIDs: Set<String> = []
    @State private var optimisticCompletion: [String: Bool] = [:]
    @State private var inlineErrorMessage: String?
    @State private var editDraft: TaskEditDraft?

    init(scope: TaskListScope, density: TaskDensity = .expanded, onMessage: @escaping (String, ToastStyle) -> Void) {
        self.scope = scope
        self.density = density
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
                            areaColor: areaColor(for: task),
                            density: density
                        ) {
                            toggleCompletion(for: task)
                        } onEditDueDate: { selectedDueAt in
                            updateDueDate(for: task, dueAt: selectedDueAt)
                        }
                        .listRowInsets(
                            EdgeInsets(
                                top: density == .compact ? 2 : 6,
                                leading: density == .compact ? DS.Spacing.sm : DS.Spacing.md,
                                bottom: density == .compact ? 2 : 6,
                                trailing: density == .compact ? DS.Spacing.sm : DS.Spacing.md
                            )
                        )
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
                                editDraft = TaskEditDraft(task: task)
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
        .sheet(item: $editDraft) { draft in
            TaskEditSheet(draft: draft) {
                onMessage("Task updated.", .success)
                env.syncController.syncNow(source: .reconcile)
            } onFailed: { message in
                onMessage(message, .error)
            }
            .environmentObject(env)
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

    private func updateDueDate(for task: TaskItem, dueAt: Date) {
        let nextDueAt = Calendar.current.startOfDay(for: dueAt)
        Task {
            do {
                try await env.syncController.setTaskDueDate(taskID: task.serverID, dueAt: nextDueAt)
                env.syncController.syncNow(source: .reconcile)
                await MainActor.run {
                    onMessage("Due date updated.", .success)
                }
            } catch {
                await MainActor.run {
                    onMessage(error.localizedDescription, .error)
                }
            }
        }
    }
}

private struct TaskEditDraft: Identifiable {
    let id: String
    let title: String
    let area: TaskArea
    let priority: TaskPriority?
    let projectName: String
    let dueAt: Date?
    let repeatRule: RepeatRule

    init(task: TaskItem) {
        self.id = task.serverID
        self.title = task.title
        self.area = task.normalizedArea ?? .personal
        self.priority = task.priority.flatMap(TaskPriority.init(rawValue:))
        self.projectName = task.projectName ?? task.project ?? ""
        self.dueAt = task.dueAt
        self.repeatRule = task.repeatRule ?? .none
    }
}

private struct TaskEditSheet: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @Environment(\.dismiss) private var dismiss

    let draft: TaskEditDraft
    let onSaved: () -> Void
    let onFailed: (String) -> Void

    @State private var title: String
    @State private var area: TaskArea
    @State private var priorityRawValue: Int
    @State private var projectName: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var repeatRule: RepeatRule
    @State private var projectSuggestions: [String] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isSubmitting = false
    @State private var inlineError: String?

    init(draft: TaskEditDraft, onSaved: @escaping () -> Void, onFailed: @escaping (String) -> Void) {
        self.draft = draft
        self.onSaved = onSaved
        self.onFailed = onFailed
        _title = State(initialValue: draft.title)
        _area = State(initialValue: draft.area)
        _priorityRawValue = State(initialValue: draft.priority?.rawValue ?? 0)
        _projectName = State(initialValue: draft.projectName)
        _hasDueDate = State(initialValue: draft.dueAt != nil)
        _dueDate = State(initialValue: draft.dueAt ?? Date())
        _repeatRule = State(initialValue: draft.repeatRule)
    }

    private var selectedPriority: TaskPriority? {
        TaskPriority(rawValue: priorityRawValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Task")
                            .font(DS.Typography.caption)
                            .foregroundStyle(.secondary)
                        TextField("Task title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("taskedit.title")
                    }

                    Picker("Area", selection: $area) {
                        Text("Personal").tag(TaskArea.personal)
                        Text("Work").tag(TaskArea.work)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Priority")
                                .font(DS.Typography.caption)
                                .foregroundStyle(.secondary)
                            Picker("Priority", selection: $priorityRawValue) {
                                Text("None").tag(0)
                                ForEach(TaskPriority.allCases) { value in
                                    Text(value.displayName).tag(value.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Project")
                                .font(DS.Typography.caption)
                                .foregroundStyle(.secondary)
                            TextField("Project name", text: $projectName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: projectName) { _, newValue in
                                    suggestionTask?.cancel()
                                    let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !query.isEmpty else {
                                        projectSuggestions = []
                                        return
                                    }
                                    suggestionTask = Task {
                                        try? await Task.sleep(nanoseconds: 200_000_000)
                                        guard !Task.isCancelled else { return }
                                        let results = await env.syncController.projectSuggestions(prefix: query)
                                        await MainActor.run { projectSuggestions = results }
                                    }
                                }

                            if !projectSuggestions.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: DS.Spacing.xs) {
                                        ForEach(projectSuggestions, id: \.self) { suggestion in
                                            Button(suggestion) {
                                                projectName = suggestion
                                                projectSuggestions = []
                                            }
                                            .font(DS.Typography.caption)
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 10)
                                            .background(DS.Colors.surface)
                                            .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }

                        if draft.dueAt == nil {
                            Toggle("Due Date", isOn: $hasDueDate.animation())
                        }

                        if hasDueDate || draft.dueAt != nil {
                            DatePicker("Due", selection: $dueDate, displayedComponents: [.date])
                                .datePickerStyle(.graphical)
                        }

                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Repeat")
                                .font(DS.Typography.caption)
                                .foregroundStyle(.secondary)
                            Picker("Repeat", selection: $repeatRule) {
                                ForEach(RepeatRule.allCases) { value in
                                    Text(value.rawValue.capitalized).tag(value)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(DS.Spacing.md)
                    .background(DS.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                    if let inlineError {
                        Text(inlineError)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.danger)
                    }

                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSubmitting ? "Saving…" : "Save Changes")
                                .font(DS.Typography.body)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, DS.Spacing.sm)
                        .foregroundStyle(.white)
                        .background(DS.Colors.accentAlt)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .disabled(isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("taskedit.submit")
                }
                .padding(DS.Spacing.md)
            }
            .background(
                LinearGradient(
                    colors: [DS.Colors.elevated.opacity(0.15), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .navigationTitle("Edit Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        inlineError = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            inlineError = "Task title is required."
            return
        }

        isSubmitting = true
        Task {
            do {
                let due: Date? = {
                    if draft.dueAt == nil {
                        return hasDueDate ? Calendar.current.startOfDay(for: dueDate) : nil
                    }
                    return Calendar.current.startOfDay(for: dueDate)
                }()

                try await env.syncController.updateTask(
                    taskID: draft.id,
                    title: trimmedTitle,
                    area: area,
                    priority: selectedPriority,
                    projectName: projectName,
                    dueAt: due,
                    repeatRule: repeatRule
                )

                await MainActor.run {
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                    onSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    inlineError = error.localizedDescription
                    onFailed(error.localizedDescription)
                }
            }

            await MainActor.run {
                isSubmitting = false
            }
        }
    }
}

struct TaskCardRow: View {
    let task: TaskItem
    let isCompleted: Bool
    let isPending: Bool
    let areaColor: Color
    let density: TaskDensity
    let onToggleComplete: () -> Void
    let onEditDueDate: (Date) -> Void

    @State private var dueDateDraft: Date = .now
    @State private var isDueDatePopoverPresented = false

    private var dueText: String? {
        guard let due = task.dueAt else { return nil }
        return due.formatted(date: .abbreviated, time: .omitted)
    }

    private var dueIsOverdue: Bool {
        guard let due = task.dueAt else { return false }
        return due < Calendar.current.startOfDay(for: Date()) && !isCompleted
    }

    private var cardTintOpacity: Double {
        isCompleted ? 0.06 : 0.14
    }

    private var isCompact: Bool {
        density == .compact
    }

    var body: some View {
        HStack(spacing: isCompact ? DS.Spacing.xs : DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: isCompact ? DS.Spacing.xxs : DS.Spacing.xs) {
                HStack(alignment: .top, spacing: isCompact ? DS.Spacing.xs : DS.Spacing.sm) {
                    completionButton
                    Text(task.title)
                        .font(isCompact ? .system(.subheadline, design: .rounded).weight(.medium) : DS.Typography.body)
                        .strikethrough(isCompleted)
                        .foregroundStyle(isCompleted ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isCompact ? 1 : 3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: isCompact ? DS.Spacing.xxs : DS.Spacing.xs) {
                    if let dueText {
                        Button {
                            dueDateDraft = Calendar.current.startOfDay(for: task.dueAt ?? Date())
                            isDueDatePopoverPresented = true
                        } label: {
                            InfoChip(
                                text: dueIsOverdue ? "Overdue \(dueText)" : "Due \(dueText)",
                                tint: dueIsOverdue ? DS.Colors.danger : .secondary,
                                compact: isCompact
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit due date")
                        .accessibilityIdentifier("task.editDue.\(task.serverID)")
                        .popover(isPresented: $isDueDatePopoverPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                DatePicker("Due date", selection: $dueDateDraft, displayedComponents: [.date])
                                    .datePickerStyle(.graphical)
                                    .labelsHidden()
                                    .onChange(of: dueDateDraft) { _, newValue in
                                        onEditDueDate(Calendar.current.startOfDay(for: newValue))
                                        isDueDatePopoverPresented = false
                                    }
                            }
                            .padding(DS.Spacing.xs)
                            .frame(minWidth: 320)
                            .forcePopoverCompactAdaptation()
                        }
                    }

                    if let project = task.projectName ?? task.project, !project.isEmpty {
                        InfoChip(text: project, tint: areaColor, compact: isCompact)
                    }

                    if !isCompact, let priority = task.priorityLabel {
                        InfoChip(text: priority, tint: DS.Colors.accentAlt, compact: false)
                    }
                }

                if !isCompact, let repeatRule = task.repeatRule, repeatRule != .none {
                    Text("Repeats \(repeatRule.rawValue.capitalized)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, isCompact ? 6 : DS.Spacing.sm)
        .padding(.horizontal, isCompact ? DS.Spacing.xs : DS.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: isCompact ? DS.Radius.sm : DS.Radius.md, style: .continuous)
                .fill(DS.Colors.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: isCompact ? DS.Radius.sm : DS.Radius.md, style: .continuous)
                        .fill(areaColor.opacity(cardTintOpacity))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? DS.Radius.sm : DS.Radius.md, style: .continuous)
                .stroke(areaColor.opacity(isCompleted ? 0.14 : 0.22), lineWidth: 1)
        }
        .accessibilityIdentifier("task.row.\(task.serverID)")
        .animation(DS.Motion.quick, value: isCompleted)
    }

    private var completionButton: some View {
        Button(action: onToggleComplete) {
            Group {
                if isPending {
                    ProgressView()
                        .controlSize(isCompact ? .mini : .small)
                } else {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCompleted ? DS.Colors.success : .secondary)
                }
            }
            .frame(width: isCompact ? 20 : 24, height: isCompact ? 20 : 24)
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
    let compact: Bool

    var body: some View {
        Text(text)
            .font(compact ? .system(.caption2, design: .rounded).weight(.medium) : DS.Typography.caption)
            .padding(.vertical, compact ? 2 : 4)
            .padding(.horizontal, compact ? 6 : 8)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

private extension View {
    @ViewBuilder
    func forcePopoverCompactAdaptation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }
}

#Preview {
    TaskListView(scope: .all) { _, _ in }
        .modelContainer(for: TaskItem.self, inMemory: true)
        .environmentObject(DefaultAppEnvironment())
}
