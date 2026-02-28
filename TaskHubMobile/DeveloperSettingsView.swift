//
//  DeveloperSettingsView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI

struct DeveloperSettingsView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment

    private var authStore: AuthStore { env.authStore }
    private var appConfig: AppConfig { env.appConfig }
    private var deviceRegistry: DeviceRegistry { env.deviceRegistry }
    private var prefersEphemeralBinding: Binding<Bool> {
        Binding(
            get: { authStore.prefersEphemeralWebAuthSession },
            set: { authStore.prefersEphemeralWebAuthSession = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Auth") {
                Toggle("Ephemeral Web Auth Session", isOn: prefersEphemeralBinding)
            }
            Section("Server") {
                if let base = appConfig.baseURL {
                    LabeledContent("Base URL", value: base.absoluteString)
                } else {
                    Text("No server configured")
                        .foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Min API", value: String(AppConstants.minAPIVersion))
                LabeledContent("Max API (exclusive)", value: String(AppConstants.maxExclusiveAPIVersion))
            }
            Section("Push & Device Registration") {
                Button("Request Push Permission & Register") {
                    deviceRegistry.requestAuthorizationAndRegister()
                }
                if let token = deviceRegistry.deviceTokenHex {
                    LabeledContent("APNs Token", value: String(token.prefix(12)) + "…")
                }
                if let status = deviceRegistry.lastRegistrationStatus {
                    LabeledContent("Registration", value: status)
                }
                if let date = deviceRegistry.lastRegistrationDate {
                    LabeledContent("Registered At", value: date.formatted(date: .abbreviated, time: .standard))
                }
            }
        }
        .navigationTitle("Developer Settings")
    }
}

#Preview {
    NavigationStack {
        DeveloperSettingsView()
            .environmentObject(DefaultAppEnvironment())
    }
}
