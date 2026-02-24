//
//  AppConstants.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

enum AppConstants {
    static let redirectScheme = "taskhubmobile"
    static let redirectPath = "/oauth/callback"
    static var redirectURI: URL { URL(string: "\(redirectScheme)://oauth/callback")! }
    
    // Supported API version range
    static let minAPIVersion = 1
    static let maxExclusiveAPIVersion = 2
}

