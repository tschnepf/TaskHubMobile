//
//  AppConfig.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import Combine
import SwiftUI

/// Central app configuration and shared state.
/// Stores the Task Hub base URL in a location that can be shared with extensions when App Group is configured.
@MainActor
final class AppConfig: ObservableObject {
    @Published var baseURL: URL?
    @Published var liveActivitiesEnabled: Bool

    private let baseURLKey = "AppConfig.baseURL"
    private let liveActivitiesEnabledKey = "AppConfig.liveActivitiesEnabled"

    /// Set this to your actual App Group identifier when entitlements are configured.
    /// If the suite cannot be opened (e.g., entitlements not yet set), we fall back to standard UserDefaults.
    static let appGroupIdentifier: String = AppIdentifiers.appGroupID // Set in AppIdentifiers.swift and Xcode entitlements

    private let defaults: UserDefaults

    init() {
        if let suite = UserDefaults(suiteName: AppConfig.appGroupIdentifier) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        if let urlString = defaults.string(forKey: baseURLKey),
           let url = URL(string: urlString),
           let canonical = ServerBootstrap.canonicalBaseURL(url) {
            self.baseURL = canonical
            if canonical.absoluteString != urlString {
                defaults.set(canonical.absoluteString, forKey: baseURLKey)
            }
        } else {
            self.baseURL = nil
        }
        if let stored = defaults.object(forKey: liveActivitiesEnabledKey) as? Bool {
            self.liveActivitiesEnabled = stored
        } else {
            self.liveActivitiesEnabled = true
            defaults.set(true, forKey: liveActivitiesEnabledKey)
        }
    }

    /// Persist (or clear) the base URL.
    func setBaseURL(_ url: URL?) {
        if let url, let canonical = ServerBootstrap.canonicalBaseURL(url) {
            baseURL = canonical
            defaults.set(canonical.absoluteString, forKey: baseURLKey)
        } else {
            baseURL = nil
            defaults.removeObject(forKey: baseURLKey)
        }
    }

    func setLiveActivitiesEnabled(_ enabled: Bool) {
        liveActivitiesEnabled = enabled
        defaults.set(enabled, forKey: liveActivitiesEnabledKey)
    }

    /// Clears all persisted app configuration and resets in-memory state.
    func resetAll() {
        defaults.removeObject(forKey: baseURLKey)
        baseURL = nil
    }
}
