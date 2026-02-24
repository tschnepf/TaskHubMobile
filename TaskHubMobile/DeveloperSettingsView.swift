//
//  DeveloperSettingsView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI

struct DeveloperSettingsView: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var appConfig: AppConfig
    @EnvironmentObject private var deviceRegistry: DeviceRegistry

    var body: some View {
        Form {
            Section("Auth") {
                Toggle("Ephemeral Web Auth Session", isOn: $authStore.prefersEphemeralWebAuthSession)
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
    NavigationStack { DeveloperSettingsView() }
        .environmentObject(AppConfig())
        .environmentObject(AuthStore())
        .environmentObject(DeviceRegistry(appConfig: AppConfig(), authStore: AuthStore()))
}

