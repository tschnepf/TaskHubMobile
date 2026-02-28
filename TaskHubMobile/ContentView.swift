import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @StateObject private var viewModel = TaskHomeViewModel()
    @AppStorage("ui.taskDensity") private var taskDensityRaw = TaskDensity.expanded.rawValue

    private var taskDensity: TaskDensity {
        TaskDensity(rawValue: taskDensityRaw) ?? .expanded
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [DS.Colors.elevated.opacity(0.35), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: taskDensity == .compact ? DS.Spacing.xxs : DS.Spacing.xs) {
                    header
                        .padding(.horizontal, taskDensity == .compact ? DS.Spacing.sm : DS.Spacing.md)
                        .padding(.top, taskDensity == .compact ? 2 : DS.Spacing.xxs)

                    if env.isOfflineForDisplay {
                        offlineBanner
                            .padding(.horizontal, taskDensity == .compact ? DS.Spacing.sm : DS.Spacing.md)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    FilterChipBar(selected: viewModel.selectedScope, density: taskDensity) { scope in
                        viewModel.setScope(scope)
                    }
                    .padding(.horizontal, taskDensity == .compact ? DS.Spacing.sm : DS.Spacing.md)

                    TaskListView(scope: viewModel.selectedScope, density: taskDensity) { message, style in
                        viewModel.showToast(message, style: style)
                    }
                    .environmentObject(env)
                }
                .animation(DS.Motion.quick, value: env.isOfflineForDisplay)

                if let toast = viewModel.toast {
                    VStack {
                        Spacer()
                        ToastBanner(toast: toast)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.bottom, DS.Spacing.md)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $viewModel.isPresentingQuickAdd) {
            QuickAddSheet(
                onCreated: {
                    viewModel.showToast("Task added.", style: .success)
                },
                onFailed: { message in
                    viewModel.showToast(message, style: .error)
                }
            )
            .environmentObject(env)
        }
        .onAppear {
            applyPendingDeepLinkIfNeeded()
        }
        .onChange(of: env.pendingDeepLink) { _, _ in
            applyPendingDeepLinkIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: taskDensity == .compact ? DS.Spacing.xs : DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: taskDensity == .compact ? 2 : DS.Spacing.xxs) {
                Text("Task Hub")
                    .font(.system(taskDensity == .compact ? .title3 : .title2, design: .rounded).weight(.bold))
                SyncStatusPill(density: taskDensity)
                    .environmentObject(env)
            }

            Spacer()

            if env.authStore.accessToken == nil {
                Button("Sign In") {
                    Task {
                        do {
                            try await env.signIn()
                        } catch {
                            viewModel.showToast(error.localizedDescription, style: .error)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: DS.Spacing.xs) {
                Button {
                    env.syncController.syncNow(source: .manual)
                } label: {
                    actionIcon("arrow.clockwise")
                }
                .accessibilityLabel("Sync now")

                Button {
                    viewModel.isPresentingQuickAdd = true
                } label: {
                    actionIcon("plus")
                }
                .accessibilityLabel("Quick Add")
                .accessibilityIdentifier("home.quickadd")

                NavigationLink {
                    SettingsView()
                } label: {
                    actionIcon("gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private func actionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: taskDensity == .compact ? 13 : 14, weight: .semibold))
            .frame(width: taskDensity == .compact ? 26 : 30, height: taskDensity == .compact ? 26 : 30)
            .background(DS.Colors.surface)
            .clipShape(Circle())
    }

    private var offlineBanner: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(DS.Colors.warning)
            Text("You’re offline. Showing local data.")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                env.syncController.syncNow(source: .foreground)
            }
            .font(DS.Typography.caption)
        }
        .padding(.vertical, taskDensity == .compact ? DS.Spacing.xxs : DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(DS.Colors.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.offlineBanner")
    }

    private func applyPendingDeepLinkIfNeeded() {
        guard let action = env.consumePendingDeepLink() else { return }

        switch action {
        case .openTasks(let scope):
            if let scope {
                viewModel.setScope(scope)
            }
        case .openQuickAdd(let scope):
            if let scope {
                viewModel.setScope(scope)
            }
            viewModel.isPresentingQuickAdd = true
        }
    }
}

#Preview {
    let schema = Schema([TaskItem.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let env = DefaultAppEnvironment(modelContainer: container)

    ContentView()
        .environmentObject(env)
        .modelContainer(container)
}
