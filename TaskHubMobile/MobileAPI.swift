//
//  MobileAPI.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

enum MobileAPI {
    static func fetchMeta(baseURL: URL) async throws -> ServerMeta {
        let canonical = ServerBootstrap.canonicalBaseURL(baseURL) ?? baseURL
        var candidateURLs: [URL] = [canonical.appendingPathComponent("api/mobile/v1/meta")]
        let legacyCandidate = baseURL.appendingPathComponent("api/mobile/v1/meta")
        if !candidateURLs.contains(legacyCandidate) {
            candidateURLs.append(legacyCandidate)
        }

        var lastError: Error?
        for metaURL in candidateURLs {
            for attempt in 0..<3 {
                do {
                    var req = URLRequest(url: metaURL)
                    req.httpMethod = "GET"
                    req.timeoutInterval = 20
                    req.cachePolicy = .reloadIgnoringLocalCacheData
                    req.setValue("application/json", forHTTPHeaderField: "Accept")

                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard (200...299).contains(http.statusCode) else {
                        let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<non-utf8>"
                        let userInfo: [String: Any] = [
                            NSLocalizedDescriptionKey: "Meta request failed: HTTP \(http.statusCode). Body prefix: \(preview)",
                            "http.status": http.statusCode,
                            "body.preview": String(preview),
                            "url": metaURL.absoluteString
                        ]
                        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: userInfo)
                    }
                    return try JSONDecoder().decode(ServerMeta.self, from: data)
                } catch {
                    lastError = error
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 300_000_000))
                    }
                }
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }
}
