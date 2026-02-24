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
final class AppConfig: ObservableObject {
    @Published var baseURL: URL?

    private let baseURLKey = "AppConfig.baseURL"

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
        if let urlString = defaults.string(forKey: baseURLKey), let url = URL(string: urlString) {
            self.baseURL = url
        } else {
            self.baseURL = nil
        }
    }

    /// Persist (or clear) the base URL.
    func setBaseURL(_ url: URL?) {
        baseURL = url
        if let url {
            defaults.set(url.absoluteString, forKey: baseURLKey)
        } else {
            defaults.removeObject(forKey: baseURLKey)
        }
    }

    /// Clears all persisted app configuration and resets in-memory state.
    func resetAll() {
        defaults.removeObject(forKey: baseURLKey)
        baseURL = nil
    }
}

