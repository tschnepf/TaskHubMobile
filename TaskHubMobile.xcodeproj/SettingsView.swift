#if false
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appConfig: AppConfig
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var deviceRegistry: DeviceRegistry
    @EnvironmentObject private var syncController: SyncController

    @State private var isSigningIn = false

    var body: some View {
        Form {
            Section(header: Text("Connection")) {
                if let baseURL = appConfig.baseURL {
                    Text(baseURL.absoluteString)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Change Server…", role: .destructive) {
                    appConfig.resetAll()
                    authStore.clear()
                    syncController.forceFullResync()
                }
            }

            Section(header: Text("Authentication")) {
                if let token = authStore.accessToken {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token prefix: \(token.prefix(10))…")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        if let expiry = authStore.accessTokenExpiry {
                            Text("Expires: \(expiry.formatted(date: .numeric, time: .standard))")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    Button("Sign Out") {
                        Task {
                            await authStore.logout(revocationEndpoint: nil)
                        }
                    }
                    .tint(.red)
                } else {
                    Button("Sign In") {
                        Task {
                            await signIn()
                        }
                    }
                    .disabled(isSigningIn)
                }
            }

            Section(header: Text("Push & Device Registration")) {
                Button("Request Permission & Register") {
                    deviceRegistry.requestAuthorizationAndRegister()
                }
                if let token = deviceRegistry.token {
                    Text("Push token: \(token)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Status: \(deviceRegistry.status)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                if let date = deviceRegistry.updatedAt {
                    Text("Updated: \(date.formatted(date: .numeric, time: .standard))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            #if DEBUG
            Section(header: Text("Developer")) {
                if let developerSettingsView = DeveloperSettingsView() as? View {
                    NavigationLink("Developer Settings", destination: developerSettingsView)
                }
                if let syncSettingsView = SyncSettingsView() as? View {
                    NavigationLink("Sync Settings", destination: syncSettingsView)
                }
            }
            #endif
        }
        .navigationTitle("Settings")
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        await authStore.signIn(
            redirectURI: AppConstants.redirectURI,
            clientID: AppConstants.clientID,
            clientSecret: AppConstants.clientSecret,
            tokenEndpoint: AppConstants.tokenEndpoint,
            authorizationEndpoint: AppConstants.authorizationEndpoint
        )
    }
}
#endif
