//
//  OIDCModels.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

struct OIDCDiscovery: Codable {
    let authorization_endpoint: URL
    let token_endpoint: URL
    let revocation_endpoint: URL?
}

struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let token_type: String
}
