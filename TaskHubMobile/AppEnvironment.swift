import SwiftUI
import SwiftData
import Combine

@MainActor
final class DefaultAppEnvironment: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    let modelContainer: ModelContainer
    let appConfig: AppConfig
    let authStore: AuthStore
    let syncController: SyncController
    let deviceRegistry: DeviceRegistry
    let networkMonitor: NetworkMonitor
    let themeStore: ThemeStore
    @Published private(set) var startupWarning: String?
    private var cancellables: Set<AnyCancellable> = []

    init(modelContainer: ModelContainer? = nil) {
        self.appConfig = AppConfig()
        self.authStore = AuthStore()

        if let modelContainer {
            self.modelContainer = modelContainer
        } else {
            let schema = Schema([TaskItem.self])
            let persistentConfig = ModelConfiguration()
            do {
                self.modelContainer = try ModelContainer(for: schema, configurations: [persistentConfig])
            } catch {
                self.startupWarning = "Local storage could not be opened. Using temporary in-memory storage for this session."
                let fallbackConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                do {
                    self.modelContainer = try ModelContainer(for: schema, configurations: [fallbackConfig])
                } catch {
                    preconditionFailure("Unable to initialize any SwiftData store: \(error.localizedDescription)")
                }
            }
        }

        self.syncController = SyncController(container: self.modelContainer, appConfig: self.appConfig, authStore: self.authStore)
        self.deviceRegistry = DeviceRegistry(appConfig: self.appConfig, authStore: self.authStore)
        self.networkMonitor = NetworkMonitor()
        self.themeStore = ThemeStore()
        bindChildPublishers()
    }

    func clearStartupWarning() {
        startupWarning = nil
    }

    func fetchMobilePreferencesOnLaunch() {
        guard let base = appConfig.baseURL else { return }
        Task { @MainActor in
            let client = APIClient(baseURLProvider: { base }, authStore: authStore)
            do {
                let prefs = try await client.getMobilePreferences()
                themeStore.applyServerPreferences(
                    areaTextColoringEnabled: prefs.areaTextColoringEnabled,
                    workAreaTextColor: prefs.workAreaTextColor,
                    personalAreaTextColor: prefs.personalAreaTextColor
                )
            } catch {
                // Keep cached values on failure.
            }
        }
    }

    private func bindChildPublishers() {
        appConfig.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        authStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        syncController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        deviceRegistry.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        networkMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        themeStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

struct RootView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment

    var body: some View {
        Group {
            if env.appConfig.baseURL != nil {
                ContentView()
                    .onAppear {
                        env.syncController.startLiveSyncLoop()
                        env.fetchMobilePreferencesOnLaunch()
                    }
                    .onDisappear { env.syncController.stopLiveSyncLoop() }
            } else {
                BootstrapView()
                    .onAppear {
                        env.syncController.startLiveSyncLoop()
                        env.fetchMobilePreferencesOnLaunch()
                    }
                    .onDisappear { env.syncController.stopLiveSyncLoop() }
            }
        }
        .alert(
            "Storage Warning",
            isPresented: Binding(
                get: { env.startupWarning != nil },
                set: { if !$0 { env.clearStartupWarning() } }
            )
        ) {
            Button("OK", role: .cancel) { env.clearStartupWarning() }
        } message: {
            Text(env.startupWarning ?? "")
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "taskhubmobile" else { return }
            let host = url.host?.lowercased()
            let path = url.path.lowercased()
            if host == "open" && path == "/tasks" {
                env.syncController.syncNow()
            }
        }
        .onReceive(env.authStore.$accessToken) { _ in
            env.fetchMobilePreferencesOnLaunch()
        }
    }
}
