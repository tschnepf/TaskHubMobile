import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment

    @State private var isSigningIn = false
    @State private var isSigningOut = false
    @State private var signInErrorMessage: String?
    @State private var isPresentingSignInError = false
    @AppStorage("ui.taskDensity") private var taskDensityRaw = TaskDensity.expanded.rawValue

    private var appConfig: AppConfig { env.appConfig }
    private var authStore: AuthStore { env.authStore }

    var body: some View {
        Form {
            Section("Connection") {
                if let baseURL = appConfig.baseURL {
                    Text(baseURL.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No server configured")
                        .foregroundStyle(.secondary)
                }
                Button("Change Server", role: .destructive) {
                    env.clearServerAndSession()
                }
            }

            Section("Authentication") {
                if authStore.accessToken != nil {
                    Text("Signed in")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let expiry = authStore.expiryDate {
                        LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(role: .destructive) {
                        isSigningOut = true
                        Task {
                            await env.signOut()
                            await MainActor.run { isSigningOut = false }
                        }
                    } label: {
                        if isSigningOut {
                            ProgressView()
                        } else {
                            Text("Sign Out")
                        }
                    }
                    .disabled(isSigningOut)
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button {
                        signIn()
                    } label: {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Text("Sign In")
                        }
                    }
                    .disabled(isSigningIn || appConfig.baseURL == nil)
                }
            }

            Section("Appearance") {
                Picker("Task Density", selection: $taskDensityRaw) {
                    ForEach(TaskDensity.allCases) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Tools") {
                NavigationLink("Developer Settings", destination: DeveloperSettingsView())
                NavigationLink("Sync Settings", destination: SyncSettingsView())
            }
        }
        .navigationTitle("Settings")
        .alert("Sign In Failed", isPresented: $isPresentingSignInError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(signInErrorMessage ?? "Unknown error")
        }
    }

    private func signIn() {
        guard appConfig.baseURL != nil else { return }
        signInErrorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await env.signIn()
                await MainActor.run {
                    isSigningIn = false
                }
            } catch {
                await MainActor.run {
                    signInErrorMessage = error.localizedDescription
                    isPresentingSignInError = true
                    isSigningIn = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(DefaultAppEnvironment())
    }
}
