//
//  TaskHubMobileApp.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI
import SwiftData
import Combine
import UserNotifications

protocol Syncing: AnyObject {
    func syncNow()
    func startLiveSyncLoop()
    func stopLiveSyncLoop()
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    var deviceRegistry: DeviceRegistry?
    weak var syncController: Syncing?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        deviceRegistry?.didRegisterForRemoteNotifications(with: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        deviceRegistry?.didFailToRegisterForRemoteNotifications(with: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard let sync = self.syncController else { completionHandler(.noData); return }
            sync.syncNow()
            // Allow a brief window for the sync to complete; in production consider BGTask
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            completionHandler(.newData)
        }
    }
}

@main
struct TaskHubMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var appConfig: AppConfig
    @StateObject private var authStore: AuthStore
    @StateObject private var syncController: SyncController
    @StateObject private var deviceRegistry: DeviceRegistry
    @StateObject private var networkMonitor: NetworkMonitor

    private let modelContainer: ModelContainer

    init() {
        let appConfig = AppConfig()
        _appConfig = StateObject(wrappedValue: appConfig)
        let authStore = AuthStore()
        _authStore = StateObject(wrappedValue: authStore)

        // Build SwiftData container manually so we can also inject it into SyncEngine
        let schema = Schema([TaskItem.self])
        let config = ModelConfiguration()
        let container = try! ModelContainer(for: schema, configurations: [config])
        self.modelContainer = container

        let syncController = SyncController(container: container, appConfig: appConfig, authStore: authStore)
        _syncController = StateObject(wrappedValue: syncController)

        let deviceRegistry = DeviceRegistry(appConfig: appConfig, authStore: authStore)
        _deviceRegistry = StateObject(wrappedValue: deviceRegistry)

        let networkMonitor = NetworkMonitor()
        _networkMonitor = StateObject(wrappedValue: networkMonitor)

        // Bridge registry to app delegate for APNs callbacks
        appDelegate.deviceRegistry = deviceRegistry
        appDelegate.syncController = syncController
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appConfig.baseURL != nil {
                    ContentView()
                        .environmentObject(appConfig)
                        .environmentObject(authStore)
                        .environmentObject(syncController)
                        .environmentObject(deviceRegistry)
                        .environmentObject(networkMonitor)
                        .onAppear { syncController.startLiveSyncLoop() }
                        .onDisappear { syncController.stopLiveSyncLoop() }
                } else {
                    BootstrapView()
                        .environmentObject(appConfig)
                        .environmentObject(authStore)
                        .environmentObject(syncController)
                        .environmentObject(deviceRegistry)
                        .environmentObject(networkMonitor)
                        .onAppear { syncController.startLiveSyncLoop() }
                        .onDisappear { syncController.stopLiveSyncLoop() }
                }
            }
            .modelContainer(modelContainer)
        }
    }
}

