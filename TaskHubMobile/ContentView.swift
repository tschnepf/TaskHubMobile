//
//  ContentView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var appConfig: AppConfig
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var syncController: SyncController
    @EnvironmentObject private var deviceRegistry: DeviceRegistry
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var newTaskTitle: String = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var onboardingRequired: Bool = false

    @State private var showingAddSheet: Bool = false
    @State private var addSheetTitle: String = ""
    @State private var addSheetArea: TaskArea = .personal
    @State private var addSheetPriority: TaskPriority = .three
    @State private var addSheetProject: String = ""
    @State private var addSheetHasDueDate: Bool = false
    @State private var addSheetDueDate: Date = .now
    @State private var addSheetRepeat: RepeatRule = .none

    @State private var projectSuggestions: [String] = []
    @State private var suggestionTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                TaskListView()
                    .refreshable {
                        if networkMonitor.isOnline {
                            syncController.syncNow()
                        }
                    }
                
                if !networkMonitor.isOnline {
                    VStack {
                        HStack {
                            Image(systemName: "wifi.slash")
                            Text("Offline")
                                .bold()
                            Spacer()
                        }
                        .padding(8)
                        .background(.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                        Spacer()
                    }
                    .transition(.move(edge: .top))
                }

                if syncController.isSyncing {
                    VStack {
                        HStack {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                            Text("Syncing…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(8)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                        Spacer()
                    }
                    .transition(.opacity)
                }

                if onboardingRequired {
                    OnboardingView(message: "Your identity needs to be linked by an administrator before you can sign in.") {
                        // Retry session check
                        Task { await checkSession() }
                    }
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Task Hub")
            .safeAreaInset(edge: .bottom) {
                Text("Last Sync: \(syncController.lastSync?.formatted(date: .abbreviated, time: .standard) ?? "Never")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addSheetTitle = ""
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear {
                syncController.startLiveSyncLoop()
                syncController.syncOnForeground()
                deviceRegistry.syncRegistrationOnForeground()
            }
            .sheet(isPresented: $showingAddSheet) { addTaskSheet }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    syncController.startLiveSyncLoop()
                    syncController.syncOnForeground()
                    deviceRegistry.syncRegistrationOnForeground()
                } else if newPhase == .background {
                    syncController.stopLiveSyncLoop()
                }
            }
        }
    }

    @ViewBuilder
    private var addTaskSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("New Task")) {
                    TextField("Task title", text: $addSheetTitle)
                }
                Section(header: Text("Area")) {
                    Picker("Area", selection: $addSheetArea) {
                        Text("Personal").tag(TaskArea.personal)
                        Text("Work").tag(TaskArea.work)
                    }
                    .pickerStyle(.segmented)
                }
                Section(header: Text("Priority")) {
                    Picker("Priority", selection: $addSheetPriority) {
                        ForEach(TaskPriority.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                }
                Section(header: Text("Project")) {
                    TextField("Project (name)", text: $addSheetProject)
                        .onChange(of: addSheetProject) { oldValue, newValue in
                            suggestionTask?.cancel()
                            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !query.isEmpty else {
                                self.projectSuggestions = []
                                return
                            }
                            suggestionTask = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
                                guard !Task.isCancelled else { return }
                                let results = await syncController.projectSuggestions(prefix: query)
                                await MainActor.run { self.projectSuggestions = results }
                            }
                        }
                    if !projectSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(projectSuggestions, id: \.self) { name in
                                Button(action: { self.addSheetProject = name; self.projectSuggestions = [] }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(name)
                                            .foregroundStyle(.primary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                Section(header: Text("Due Date")) {
                    Toggle("Has Due Date", isOn: $addSheetHasDueDate)
                    if addSheetHasDueDate {
                        DatePicker("Due", selection: $addSheetDueDate, displayedComponents: [.date])
                    }
                }
                Section(header: Text("Repeat")) {
                    Picker("Repeat", selection: $addSheetRepeat) {
                        ForEach(RepeatRule.allCases) { r in
                            Text(r.rawValue.capitalized).tag(r)
                        }
                    }
                }
            }
            .navigationTitle("Add Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let title = addSheetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        Task {
                            do {
                                try await syncController.createTask(
                                    title: title,
                                    area: addSheetArea,
                                    priority: addSheetPriority,
                                    projectName: addSheetProject.isEmpty ? nil : addSheetProject,
                                    dueAt: addSheetHasDueDate ? addSheetDueDate : nil,
                                    repeatRule: addSheetRepeat
                                )
                                addSheetTitle = ""
                                addSheetArea = .personal
                                addSheetPriority = .three
                                addSheetProject = ""
                                addSheetHasDueDate = false
                                addSheetDueDate = .now
                                addSheetRepeat = .none
                                showingAddSheet = false
                                await MainActor.run {
                                    projectSuggestions = []
                                }
                            } catch {
                                if let apiErr = error as? APIClientError, case let .serverError(_, message, requestID, _) = apiErr {
                                    if let req = requestID { errorMessage = "Create failed: \(message) (req: \(req))" }
                                    else { errorMessage = "Create failed: \(message)" }
                                } else {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    .disabled(addSheetTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func signIn() {
        guard let base = appConfig.baseURL else { return }
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await authStore.signIn(baseURL: base)
                await checkSession()
                // After successful login, attempt device registration and initial sync
                await MainActor.run {
                    deviceRegistry.syncRegistrationOnForeground()
                    syncController.syncNow()
                }
                isSigningIn = false
            } catch {
                errorMessage = error.localizedDescription
                isSigningIn = false
            }
        }
    }

    @MainActor
    private func checkSession() async {
        guard let base = appConfig.baseURL, let token = authStore.accessToken else { return }
        do {
            _ = try await SessionAPI.checkSession(baseURL: base, token: token)
            onboardingRequired = false
            errorMessage = nil
        } catch {
            let nsErr = error as NSError
            if let code = nsErr.userInfo["error.code"] as? String, code == "onboarding_required" {
                onboardingRequired = true
            } else {
                onboardingRequired = false
                errorMessage = nsErr.localizedDescription
            }
        }
    }
}

#Preview {
    let appConfig = AppConfig()
    let authStore = AuthStore()
    // In-memory SwiftData container for previews
    let schema = Schema([TaskItem.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let syncController = SyncController(container: container, appConfig: appConfig, authStore: authStore)
    let deviceRegistry = DeviceRegistry(appConfig: appConfig, authStore: authStore)
    let networkMonitor = NetworkMonitor()

    ContentView()
        .environmentObject(appConfig)
        .environmentObject(authStore)
        .environmentObject(syncController)
        .environmentObject(deviceRegistry)
        .environmentObject(networkMonitor)
        .modelContainer(container)
}

