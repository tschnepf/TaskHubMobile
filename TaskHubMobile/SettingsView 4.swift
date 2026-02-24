import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appConfig: AppConfig
    @EnvironmentObject private var authStore: AuthStore

    @State private var isSigningIn: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    if let base = appConfig.baseURL {
                        LabeledContent("Server", value: base.absoluteString)
                    } else {
                        Text("No server configured").foregroundStyle(.secondary)
                    }
                    Button("Change Server…", role: .destructive) {
                        // Clear the configured server. On next launch or flow, bootstrap can be shown.
                        appConfig.resetAll()
                    }
                }

                Section("Authentication") {
                    if let token = authStore.accessToken {
                        LabeledContent("Access Token", value: String(token.prefix(12)) + "…")
                        Button("Sign Out") {
                            Task { await authStore.logout(revocationEndpoint: nil) }
                        }
                    } else {
                        Button(action: signIn) {
                            if isSigningIn { ProgressView() } else { Text("Sign In") }
                        }
                        .disabled(isSigningIn || appConfig.baseURL == nil)
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func signIn() {
        guard let base = appConfig.baseURL else { return }
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await authStore.signIn(baseURL: base)
                isSigningIn = false
            } catch {
                errorMessage = error.localizedDescription
                isSigningIn = false
            }
        }
    }
}
