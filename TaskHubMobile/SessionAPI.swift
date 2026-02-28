//
//  SessionAPI.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

struct SessionInfo: Decodable {
    let userID: String
    let email: String?

    enum CodingKeys: String, CodingKey {
        case userID
        case user_id
        case email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let snake = try container.decodeIfPresent(String.self, forKey: .user_id) {
            userID = snake
        } else if let camel = try container.decodeIfPresent(String.self, forKey: .userID) {
            userID = camel
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.user_id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing user id")
            )
        }
        email = try container.decodeIfPresent(String.self, forKey: .email)
    }
}

enum SessionAPI {
    static func checkSession(baseURL: URL, token: String) async throws -> SessionInfo {
        let url = baseURL.appendingPathComponent("api/mobile/v1/session")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(SessionInfo.self, from: data)
        default:
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                throw NSError(domain: "Session", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: envelope.error.message,
                    "error.code": envelope.error.code,
                    "request_id": envelope.request_id ?? ""
                ])
            }
            throw URLError(.badServerResponse)
        }
    }
}
