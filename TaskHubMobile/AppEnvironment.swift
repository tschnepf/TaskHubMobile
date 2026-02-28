import SwiftUI
import SwiftData
import Combine

enum AppUXState: Equatable {
    case loading
    case bootstrap
    case unauthenticated
    case onboardingRequired
    case ready
    case offlineLimited
    case error
}

struct AppUXContext: Equatable {
    var state: AppUXState
    var message: String?
}

enum AppDeepLinkAction: Equatable {
    case openTasks(scope: TaskListScope?)
    case openQuickAdd(scope: TaskListScope?)
}

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
    @Published private(set) var uxContext: AppUXContext = .init(state: .loading, message: nil)
    @Published private(set) var pendingDeepLink: AppDeepLinkAction?

    private var onboardingRequired = false
    private var onboardingMessage = "Your identity needs to be linked by an administrator before you can sign in."
    private var lastSessionError: String?
    private var lastSessionCheckAt: Date?
    private var lastSessionToken: String?
    private var uiTestForcesOffline = false

    private let sessionCheckTTL: TimeInterval = 90
    private let uiTestModeEnabled: Bool
    private let skipSessionCheckForUITests: Bool
    private var cancellables: Set<AnyCancellable> = []

    var uxState: AppUXState { uxContext.state }
    var isOfflineForDisplay: Bool { !networkMonitor.isOnline || uiTestForcesOffline || uxState == .offlineLimited }

    init(modelContainer: ModelContainer? = nil) {
        let processEnvironment = ProcessInfo.processInfo.environment
        self.uiTestModeEnabled = processEnvironment["UITEST_MODE"] == "1"
        self.skipSessionCheckForUITests = processEnvironment["UITEST_SKIP_SESSION"] == "1"

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

        configureForUITestsIfNeeded()

        bindChildPublishers()
        bindStatePublishers()

        Task { await refreshUXState(forceSessionCheck: true) }
    }

    func clearStartupWarning() {
        startupWarning = nil
    }

    func fetchMobilePreferencesOnLaunch() {
        guard let base = appConfig.baseURL, authStore.accessToken != nil else { return }
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

    func signIn() async throws {
        guard let base = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }
        appConfig.setBaseURL(base)
        guard let canonicalBase = appConfig.baseURL else {
            throw APIClientError.missingBaseURL
        }
        try await authStore.signIn(baseURL: canonicalBase)
        deviceRegistry.syncRegistrationOnForeground()
        syncController.syncNow(source: .manual)
        fetchMobilePreferencesOnLaunch()
        await refreshUXState(forceSessionCheck: true)
    }

    func signOut() async {
        await authStore.logout(revocationEndpoint: nil)
        onboardingRequired = false
        lastSessionError = nil
        await refreshUXState(forceSessionCheck: false)
    }

    func clearServerAndSession() {
        appConfig.resetAll()
        authStore.clear()
        onboardingRequired = false
        lastSessionError = nil
        syncController.forceFullResync()
        Task { await refreshUXState(forceSessionCheck: false) }
    }

    func handleIncomingURL(_ url: URL) {
        guard let action = Self.parseDeepLinkAction(from: url) else { return }
        pendingDeepLink = action
    }

    func consumePendingDeepLink() -> AppDeepLinkAction? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    static func parseDeepLinkAction(from url: URL) -> AppDeepLinkAction? {
        guard url.scheme?.lowercased() == "taskhubmobile" else { return nil }
        guard url.host?.lowercased() == "open" else { return nil }

        let path = url.path.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scopeValue = components?.queryItems?.first(where: { $0.name.lowercased() == "scope" })?.value?.lowercased()

        let parsedScope: TaskListScope? = {
            switch scopeValue {
            case "all":
                return .all
            case "work":
                return .work
            case "personal":
                return .personal
            default:
                return nil
            }
        }()

        switch path {
        case "/tasks":
            return .openTasks(scope: parsedScope)
        case "/quickadd":
            return .openQuickAdd(scope: parsedScope)
        default:
            return nil
        }
    }

    func refreshUXState(forceSessionCheck: Bool = false) async {
        guard appConfig.baseURL != nil else {
            onboardingRequired = false
            lastSessionError = nil
            setUXContext(state: .bootstrap, message: nil)
            return
        }

        guard let token = authStore.accessToken, !token.isEmpty else {
            onboardingRequired = false
            lastSessionError = nil
            setUXContext(state: .unauthenticated, message: nil)
            return
        }

        if uiTestModeEnabled && skipSessionCheckForUITests {
            if onboardingRequired {
                setUXContext(state: .onboardingRequired, message: onboardingMessage)
                return
            }
            let isOffline = networkMonitor.isOnline ? uiTestForcesOffline : true
            setUXContext(state: isOffline ? .offlineLimited : .ready, message: isOffline ? "Offline mode" : nil)
            return
        }

        let shouldCheckSession = forceSessionCheck || token != lastSessionToken || sessionCheckIsStale()
        if shouldCheckSession && networkMonitor.isOnline {
            setUXContext(state: .loading, message: "Checking account status…")
            do {
                guard let base = appConfig.baseURL else {
                    setUXContext(state: .bootstrap, message: nil)
                    return
                }
                _ = try await SessionAPI.checkSession(baseURL: base, token: token)
                onboardingRequired = false
                lastSessionError = nil
                lastSessionToken = token
                lastSessionCheckAt = Date()
            } catch {
                let nsErr = error as NSError
                if let code = nsErr.userInfo["error.code"] as? String, code == "onboarding_required" {
                    onboardingRequired = true
                    onboardingMessage = nsErr.localizedDescription.isEmpty ? onboardingMessage : nsErr.localizedDescription
                    lastSessionError = nil
                    lastSessionToken = token
                    lastSessionCheckAt = Date()
                } else if nsErr.code == 401 {
                    authStore.clear()
                    onboardingRequired = false
                    lastSessionError = nil
                    setUXContext(state: .unauthenticated, message: nil)
                    return
                } else {
                    onboardingRequired = false
                    lastSessionError = nsErr.localizedDescription
                }
            }
        }

        if onboardingRequired {
            setUXContext(state: .onboardingRequired, message: onboardingMessage)
            return
        }

        if uiTestForcesOffline || !networkMonitor.isOnline {
            setUXContext(state: .offlineLimited, message: "Offline mode")
            return
        }

        if let lastSessionError {
            setUXContext(state: .error, message: lastSessionError)
            return
        }

        setUXContext(state: .ready, message: nil)
    }

    private func sessionCheckIsStale() -> Bool {
        guard let lastSessionCheckAt else { return true }
        return Date().timeIntervalSince(lastSessionCheckAt) > sessionCheckTTL
    }

    private func setUXContext(state: AppUXState, message: String?) {
        let next = AppUXContext(state: state, message: message)
        if uxContext != next {
            uxContext = next
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

    private func bindStatePublishers() {
        Publishers.CombineLatest3(
            appConfig.$baseURL
                .map { $0?.absoluteString ?? "" }
                .removeDuplicates(),
            authStore.$accessToken
                .map { $0 ?? "" }
                .removeDuplicates(),
            networkMonitor.$isOnline.removeDuplicates()
        )
        .sink { [weak self] _, _, _ in
            guard let self else { return }
            Task { await self.refreshUXState() }
        }
        .store(in: &cancellables)

        authStore.$accessToken
            .removeDuplicates()
            .sink { [weak self] token in
                guard let self else { return }
                if token != nil {
                    self.fetchMobilePreferencesOnLaunch()
                }
            }
            .store(in: &cancellables)
    }

    private func configureForUITestsIfNeeded() {
        guard uiTestModeEnabled else { return }

        // Keep UI tests deterministic regardless of prior simulator launches.
        UserDefaults.standard.removeObject(forKey: "task.home.scope")

        let scenario = ProcessInfo.processInfo.environment["UITEST_SCENARIO"] ?? "bootstrap"
        let testURL = URL(string: "https://uitest.taskhub.local")!

        switch scenario {
        case "bootstrap":
            appConfig.resetAll()
            authStore.clear()
            onboardingRequired = false
            lastSessionError = nil
            uiTestForcesOffline = false
            clearUITestTasks()
        case "unauthenticated":
            appConfig.setBaseURL(testURL)
            authStore.clear()
            onboardingRequired = false
            lastSessionError = nil
            uiTestForcesOffline = false
            clearUITestTasks()
        case "onboarding":
            appConfig.setBaseURL(testURL)
            #if DEBUG
            authStore.setTestingTokens()
            #endif
            onboardingRequired = true
            onboardingMessage = "Your account is waiting for administrator onboarding."
            lastSessionError = nil
            uiTestForcesOffline = false
            clearUITestTasks()
        case "ready":
            appConfig.setBaseURL(testURL)
            #if DEBUG
            authStore.setTestingTokens()
            #endif
            onboardingRequired = false
            lastSessionError = nil
            uiTestForcesOffline = false
            replaceWithUITestTasks()
        case "offline":
            appConfig.setBaseURL(testURL)
            #if DEBUG
            authStore.setTestingTokens()
            #endif
            onboardingRequired = false
            lastSessionError = nil
            uiTestForcesOffline = true
            replaceWithUITestTasks()
        default:
            break
        }
    }

    private func clearUITestTasks() {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let existing = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        for item in existing {
            context.delete(item)
        }
        try? context.save()
    }

    private func replaceWithUITestTasks() {
        clearUITestTasks()

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let now = Date()
        let samples = [
            TaskItem(
                serverID: "t1",
                title: "Review iOS UX refactor",
                completed: false,
                updatedAt: now,
                dueAt: Calendar.current.date(byAdding: .day, value: 1, to: now),
                project: "Mobile",
                projectId: "mobile",
                projectName: "Mobile",
                areaRaw: "work",
                priority: 2,
                recurrenceRaw: "none"
            ),
            TaskItem(
                serverID: "t2",
                title: "Plan personal errands",
                completed: false,
                updatedAt: now.addingTimeInterval(-1200),
                dueAt: nil,
                project: "Life",
                projectId: "life",
                projectName: "Life",
                areaRaw: "personal",
                priority: 4,
                recurrenceRaw: "weekly"
            ),
            TaskItem(
                serverID: "t3",
                title: "Completed sample task",
                completed: true,
                updatedAt: now.addingTimeInterval(-3600),
                dueAt: nil,
                project: nil,
                projectId: nil,
                projectName: nil,
                areaRaw: "work",
                priority: 3,
                recurrenceRaw: "none"
            )
        ]

        for item in samples {
            context.insert(item)
        }
        try? context.save()
    }
}

struct RootView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch env.uxState {
            case .loading:
                AppLoadingView(message: env.uxContext.message)
            case .bootstrap:
                BootstrapView()
            case .unauthenticated:
                SignInRequiredView()
            case .onboardingRequired:
                OnboardingGateView(message: env.uxContext.message ?? "Your account is waiting for administrator onboarding.")
            case .ready, .offlineLimited:
                ContentView()
            case .error:
                AppErrorView(message: env.uxContext.message ?? "Something went wrong.")
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
        .onAppear {
            env.syncController.startLiveSyncLoop()
            env.fetchMobilePreferencesOnLaunch()
            Task { await env.refreshUXState(forceSessionCheck: true) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                env.syncController.startLiveSyncLoop()
                env.syncController.syncOnForeground()
                env.deviceRegistry.syncRegistrationOnForeground()
                Task { await env.refreshUXState(forceSessionCheck: true) }
            } else if newPhase == .background {
                env.syncController.stopLiveSyncLoop()
            }
        }
        .onOpenURL { url in
            if DefaultAppEnvironment.parseDeepLinkAction(from: url) != nil {
                env.handleIncomingURL(url)
                env.syncController.syncNow(source: .manual)
            }
        }
    }
}
