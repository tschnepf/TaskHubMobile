//
//  SyncSettingsView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI
import SwiftData

struct SyncSettingsView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment

    private var syncController: SyncController { env.syncController }

    var body: some View {
        Form {
            Section("Status") {
                if let last = syncController.lastSync {
                    LabeledContent("Last Sync", value: last.formatted(date: .abbreviated, time: .standard))
                } else {
                    LabeledContent("Last Sync", value: "Never")
                }
                if let next = syncController.nextAllowedSync {
                    LabeledContent("Next Allowed", value: next.formatted(date: .abbreviated, time: .standard))
                }
                if let err = syncController.lastError, !err.isEmpty {
                    Text(err).foregroundStyle(.red)
                }
                LabeledContent("Syncing", value: syncController.isSyncing ? "Yes" : "No")
            }

            Section("Actions") {
                Button("Sync Now") { syncController.syncNow() }
                Button("Force Full Resync") { syncController.forceFullResync() }
            }

            Section("Widget Snapshot") {
                if let last = syncController.lastSync {
                    LabeledContent("Last App Sync", value: last.formatted(date: .abbreviated, time: .standard))
                }
                Button("Refresh Widget Snapshot") { syncController.refreshWidgetSnapshot() }
            }
        }
        .navigationTitle("Sync Settings")
    }
}

#Preview {
    let schema = Schema([TaskItem.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let env = DefaultAppEnvironment(modelContainer: container)

    NavigationStack {
        SyncSettingsView()
            .environmentObject(env)
    }
    .modelContainer(container)
}
