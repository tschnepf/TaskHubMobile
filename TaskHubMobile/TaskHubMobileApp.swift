//
//  TaskHubMobileApp.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI
import SwiftData

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
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            completionHandler(.newData)
        }
    }
}

@main
struct TaskHubMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = DefaultAppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .onAppear {
                    appDelegate.deviceRegistry = env.deviceRegistry
                    appDelegate.syncController = env.syncController
                }
                .modelContainer(env.modelContainer)
        }
    }
}
