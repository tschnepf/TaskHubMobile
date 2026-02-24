//
//  AppIdentifiers.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

enum AppIdentifiers {
    /// Shared App Group identifier used by app and extensions. Ensure this is added to all relevant targets' capabilities.
    static let appGroupID: String = "group.com.ie.taskhub"
    static let keychainAccessGroup: String? = nil // e.g., "com.yourorg.taskhub.sharedkeychain" when configured
}
