import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FilterChipBar: View {
    @Namespace private var namespace

    let selected: TaskListScope
    let onSelect: (TaskListScope) -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(TaskListScope.allCases, id: \.rawValue) { scope in
                Button {
                    withAnimation(DS.Motion.quick) {
                        onSelect(scope)
                    }
                } label: {
                    Text(scope.title)
                        .font(DS.Typography.caption)
                        .foregroundStyle(selected == scope ? Color.white : .primary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected == scope {
                                RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                                    .fill(DS.Colors.accentAlt)
                                    .matchedGeometryEffect(id: "scope-chip", in: namespace)
                            } else {
                                RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                                    .fill(DS.Colors.surface)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter \(scope.title)")
                .accessibilityIdentifier("filter.\(scope.title.lowercased())")
            }
        }
        .padding(DS.Spacing.xs)
        .background(DS.Colors.elevated)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

struct SyncStatusPill: View {
    @EnvironmentObject private var env: DefaultAppEnvironment

    var body: some View {
        let style = statusStyle
        Label(style.text, systemImage: style.symbol)
            .font(DS.Typography.caption)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(style.tint.opacity(0.12))
            .foregroundStyle(style.tint)
            .clipShape(Capsule())
            .accessibilityLabel("Sync status: \(style.text)")
    }

    private var statusStyle: (text: String, symbol: String, tint: Color) {
        if !env.networkMonitor.isOnline {
            return ("Offline", "wifi.slash", DS.Colors.warning)
        }

        if env.syncController.isSyncing {
            return ("Syncing", "arrow.triangle.2.circlepath", DS.Colors.accent)
        }

        if let retryAt = env.syncController.nextAllowedSync, retryAt > Date() {
            let seconds = Int(max(1, retryAt.timeIntervalSinceNow.rounded()))
            return ("Retrying in \(seconds)s", "clock.badge.exclamationmark", DS.Colors.warning)
        }

        if let lastSync = env.syncController.lastSync {
            let rel = RelativeDateTimeFormatter().localizedString(for: lastSync, relativeTo: Date())
            return ("Up to date \(rel)", "checkmark.circle", DS.Colors.success)
        }

        return ("Not synced yet", "clock", .secondary)
    }
}

struct ToastBanner: View {
    let toast: InAppToast

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
            Text(toast.message)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .font(DS.Typography.caption)
        .foregroundStyle(.white)
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.toast")
        .accessibilityLabel(toast.message)
    }

    private var icon: String {
        switch toast.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var background: some ShapeStyle {
        switch toast.style {
        case .info:
            return AnyShapeStyle(DS.Colors.accentAlt)
        case .success:
            return AnyShapeStyle(DS.Colors.success)
        case .error:
            return AnyShapeStyle(DS.Colors.danger)
        }
    }
}

struct QuickAddSheet: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @Environment(\.dismiss) private var dismiss

    let onCreated: () -> Void
    let onFailed: (String) -> Void

    @State private var title = ""
    @State private var area: TaskArea = .personal
    @State private var isAdvancedExpanded = true
    @State private var priority: TaskPriority = .three
    @State private var projectName = ""
    @State private var hasDueDate = false
    @State private var dueDate: Date = .now
    @State private var repeatRule: RepeatRule = .none
    @State private var projectSuggestions: [String] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isSubmitting = false
    @State private var inlineError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Task")
                            .font(DS.Typography.caption)
                            .foregroundStyle(.secondary)
                        TextField("What needs to be done?", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("quickadd.title")
                    }

                    Picker("Area", selection: $area) {
                        Text("Personal").tag(TaskArea.personal)
                        Text("Work").tag(TaskArea.work)
                    }
                    .pickerStyle(.segmented)

                    Button {
                        withAnimation(DS.Motion.quick) {
                            isAdvancedExpanded.toggle()
                        }
                    } label: {
                        Label(isAdvancedExpanded ? "Hide details" : "Add details", systemImage: "slider.horizontal.3")
                            .font(DS.Typography.caption)
                    }
                    .buttonStyle(.plain)

                    if isAdvancedExpanded {
                        advancedFields
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

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
                            Text(isSubmitting ? "Adding…" : "Add Task")
                                .font(DS.Typography.body)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, DS.Spacing.sm)
                        .foregroundStyle(.white)
                        .background(DS.Colors.accentAlt)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .disabled(isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quickadd.submit")
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
            .navigationTitle("Quick Add")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Priority")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                Picker("Priority", selection: $priority) {
                    ForEach(TaskPriority.allCases) { p in
                        Text(p.displayName).tag(p)
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

            Toggle("Due Date", isOn: $hasDueDate.animation())
            if hasDueDate {
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
                .pickerStyle(.segmented)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
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
                try await env.syncController.createTask(
                    title: trimmedTitle,
                    area: area,
                    priority: isAdvancedExpanded ? priority : nil,
                    projectName: projectName.isEmpty ? nil : projectName,
                    dueAt: hasDueDate ? dueDate : nil,
                    repeatRule: isAdvancedExpanded ? repeatRule : .none
                )
                await MainActor.run {
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                    onCreated()
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

struct SignInRequiredView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.accentAlt)

                Text("Sign In Required")
                    .font(DS.Typography.headline)
                    .accessibilityIdentifier("auth.required.title")

                Text("Connect your account to sync and manage tasks.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorMessage {
                    Text(errorMessage)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.danger)
                        .multilineTextAlignment(.center)
                }

                Button {
                    signIn()
                } label: {
                    if isSigningIn {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In")
                            .font(DS.Typography.body)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, DS.Spacing.sm)
                .foregroundStyle(.white)
                .background(DS.Colors.accentAlt)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .disabled(isSigningIn)
                .accessibilityIdentifier("auth.signin.button")

                NavigationLink("Open Settings") {
                    SettingsView()
                }
                .font(DS.Typography.caption)
            }
            .padding(DS.Spacing.xl)
            .navigationTitle("Account")
        }
    }

    private func signIn() {
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await env.signIn()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isSigningIn = false
            }
        }
    }
}

struct OnboardingGateView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    let message: String

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            OnboardingView(message: message) {
                Task { await env.refreshUXState(forceSessionCheck: true) }
            }

            Button("Sign Out", role: .destructive) {
                Task { await env.signOut() }
            }
        }
        .padding(DS.Spacing.md)
    }
}

struct AppLoadingView: View {
    let message: String?

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            ProgressView()
            Text(message ?? "Loading…")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DS.Spacing.xl)
    }
}

struct AppErrorView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    let message: String

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(DS.Colors.warning)
            Text("Unable to Load")
                .font(DS.Typography.headline)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await env.refreshUXState(forceSessionCheck: true) }
            }
            .buttonStyle(.borderedProminent)

            Button("Sign Out") {
                Task { await env.signOut() }
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
    }
}
