//
//  MobileAPI.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

enum MobileAPI {
    static func fetchMeta(baseURL: URL) async throws -> ServerMeta
    {
        let metaURL = baseURL.appendingPathComponent("api/mobile/v1/meta")
        var req = URLRequest(url: metaURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200...299).contains(http.statusCode) {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<non-utf8>"
            let userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: "Meta request failed: HTTP \(http.statusCode). Body prefix: \(preview)",
                "http.status": http.statusCode,
                "body.preview": String(preview)
            ]
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: userInfo)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ServerMeta.self, from: data)
    }
}

