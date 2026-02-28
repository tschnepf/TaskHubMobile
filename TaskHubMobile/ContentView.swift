import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @StateObject private var viewModel = TaskHomeViewModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [DS.Colors.elevated.opacity(0.35), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: DS.Spacing.sm) {
                    header
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.xs)

                    if env.isOfflineForDisplay {
                        offlineBanner
                            .padding(.horizontal, DS.Spacing.md)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    FilterChipBar(selected: viewModel.selectedScope) { scope in
                        viewModel.setScope(scope)
                    }
                    .padding(.horizontal, DS.Spacing.md)

                    TaskListView(scope: viewModel.selectedScope) { message, style in
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        env.syncController.syncNow(source: .manual)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Sync now")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isPresentingQuickAdd = true
                    } label: {
                        Label("Quick Add", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Quick Add")
                    .accessibilityIdentifier("home.quickadd")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
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
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Task Hub")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                SyncStatusPill()
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
                .buttonStyle(.borderedProminent)
            }
        }
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
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(DS.Colors.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.offlineBanner")
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
