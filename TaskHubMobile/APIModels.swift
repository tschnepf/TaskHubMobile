//
//  APIModels.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
        let message: String
        // details intentionally omitted for resilience
    }
    let error: APIError
    let request_id: String?
}
