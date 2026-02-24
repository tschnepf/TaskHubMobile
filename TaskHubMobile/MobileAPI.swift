//
//  MobileAPI.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

enum MobileAPI {
    static func fetchMeta(baseURL: URL) async throws -> ServerMeta {
        let metaURL = baseURL.appendingPathComponent("api/mobile/v1/meta")
        var req = URLRequest(url: metaURL)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ServerMeta.self, from: data)
    }
}
