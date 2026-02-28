import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment

    @State private var isSigningIn = false
    @State private var isSigningOut = false
    @State private var signInErrorMessage: String?
    @State private var isPresentingSignInError = false

    private var appConfig: AppConfig { env.appConfig }
    private var authStore: AuthStore { env.authStore }
    private var syncController: SyncController { env.syncController }
    private var deviceRegistry: DeviceRegistry { env.deviceRegistry }

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
                    appConfig.resetAll()
                    authStore.clear()
                    syncController.forceFullResync()
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
                            await authStore.logout(revocationEndpoint: nil)
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
        guard let base = appConfig.baseURL else { return }
        appConfig.setBaseURL(base)
        guard let canonicalBase = appConfig.baseURL else { return }
        signInErrorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await authStore.signIn(baseURL: canonicalBase)
                await MainActor.run {
                    deviceRegistry.syncRegistrationOnForeground()
                    syncController.syncNow()
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
