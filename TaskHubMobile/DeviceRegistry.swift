//
//  DeviceRegistry.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import UIKit
import UserNotifications
import Combine

@MainActor
final class DeviceRegistry: NSObject, ObservableObject {
    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var deviceTokenHex: String?
    @Published private(set) var lastRegistrationStatus: String?
    @Published private(set) var lastRegistrationDate: Date?

    private let appConfig: AppConfig
    private let authStore: AuthStore
    private let keychain = KeychainStore(service: "com.ie.taskhub.device", accessGroup: AppIdentifiers.keychainAccessGroup)
    private let installationIDKey = "device.installation.id"

    init(appConfig: AppConfig, authStore: AuthStore) {
        self.appConfig = appConfig
        self.authStore = authStore
        super.init()
    }

    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAuthorized = granted
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func didRegisterForRemoteNotifications(with deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        self.deviceTokenHex = hex
        Task { await self.registerDeviceIfPossible() }
    }

    func didFailToRegisterForRemoteNotifications(with error: Error) {
        self.lastRegistrationStatus = "APNs registration failed: \(error.localizedDescription)"
    }

    func registerDeviceIfPossible() async {
        guard let base = appConfig.baseURL, let tokenHex = deviceTokenHex else { return }
        let client = APIClient(baseURLProvider: { base }, authStore: authStore)
        let payload = DeviceRegistrationPayload(
            apns_device_token: tokenHex,
            apns_environment: apnsEnvironment(),
            device_installation_id: installationID(),
            app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            build_number: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            ios_version: UIDevice.current.systemVersion,
            timezone: TimeZone.current.identifier
        )
        do {
            let _: DeviceRegistrationResponse = try await client.post("api/mobile/v1/devices/register", body: payload)
            self.lastRegistrationStatus = "Registered"
            self.lastRegistrationDate = Date()
        } catch {
            self.lastRegistrationStatus = "Registration failed: \(error.localizedDescription)"
        }
    }

    private func installationID() -> String {
        if let data = try? keychain.data(for: installationIDKey), let s = String(data: data, encoding: .utf8) {
            return s
        }
        let new = UUID().uuidString
        try? keychain.set(Data(new.utf8), for: installationIDKey)
        return new
    }

    private func apnsEnvironment() -> String {
        #if DEBUG
        return "sandbox"
        #else
        return "production" // TestFlight and App Store
        #endif
    }
    
    func syncRegistrationOnForeground() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let authorized = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                self.isAuthorized = authorized
                guard authorized else { return }
                if UIApplication.shared.isRegisteredForRemoteNotifications {
                    if self.deviceTokenHex != nil {
                        await self.registerDeviceIfPossible()
                    } else {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                } else {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }
}

// MARK: - Models

private struct DeviceRegistrationPayload: Encodable {
    let apns_device_token: String
    let apns_environment: String
    let device_installation_id: String
    let app_version: String
    let build_number: String
    let ios_version: String
    let timezone: String
}

private struct DeviceRegistrationResponse: Decodable { let id: String? }

