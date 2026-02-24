//
//  ServerBootstrap.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

struct ServerMeta: Decodable {
    let api_version: String
    let oidc_discovery_url: URL
    let oidc_client_id: String
    let required_scopes: [String]
    let required_audience: String?
}

enum BootstrapError: LocalizedError {
    case invalidURL
    case nonHTTPS
    case unreachable
    case invalidResponse
    case invalidMeta

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid URL (e.g., https://example.com)."
        case .nonHTTPS:
            return "A secure https URL is required."
        case .unreachable:
            return "Server is unreachable. Check the URL and your network connection."
        case .invalidResponse:
            return "Unexpected response from server."
        case .invalidMeta:
            return "Server meta is invalid or missing required fields."
        }
    }
}

struct ServerBootstrap {
    /// Normalize input text to a https URL with no trailing slash.
    static func normalizeBaseURL(from input: String) -> URL? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed) else { return nil }
        guard url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Validate the server by calling /health/live and /api/mobile/v1/meta
    static func validate(baseURL: URL) async throws -> ServerMeta {
        let healthURL = baseURL.appendingPathComponent("health/live")
        let metaURL = baseURL.appendingPathComponent("api/mobile/v1/meta")

        // Health check
        var healthReq = URLRequest(url: healthURL)
        healthReq.httpMethod = "GET"
        print("[Validate] GET", healthURL.absoluteString)
        do {
            let (healthData, healthResp) = try await URLSession.shared.data(for: healthReq)
            if let http1 = healthResp as? HTTPURLResponse {
                let ct = http1.value(forHTTPHeaderField: "Content-Type") ?? "nil"
                print("[Validate] Health status:", http1.statusCode, "Content-Type:", ct, "Bytes:", healthData.count)
                guard (200...299).contains(http1.statusCode) else {
                    let preview = String(data: healthData, encoding: .utf8)?.prefix(200) ?? ""
                    print("[Validate] Health body preview:", preview)
                    throw BootstrapError.unreachable
                }
            } else {
                print("[Validate] Health: no HTTPURLResponse")
                throw BootstrapError.unreachable
            }
        } catch {
            print("[Validate] Health request failed:", error.localizedDescription)
            throw BootstrapError.unreachable
        }

        // Meta
        var metaReq = URLRequest(url: metaURL)
        metaReq.httpMethod = "GET"
        metaReq.setValue("application/json", forHTTPHeaderField: "Accept")
        print("[Validate] GET", metaURL.absoluteString)
        let (metaData, metaResp) = try await URLSession.shared.data(for: metaReq)
        guard let http2 = metaResp as? HTTPURLResponse else {
            print("[Validate] Meta: no HTTPURLResponse")
            throw BootstrapError.invalidResponse
        }
        let ct2 = http2.value(forHTTPHeaderField: "Content-Type") ?? "nil"
        print("[Validate] Meta status:", http2.statusCode, "Content-Type:", ct2, "Bytes:", metaData.count)
        guard (200...299).contains(http2.statusCode) else {
            let preview = String(data: metaData, encoding: .utf8)?.prefix(300) ?? ""
            print("[Validate] Meta body preview:", preview)
            throw BootstrapError.invalidResponse
        }

        let decoder = JSONDecoder()
        do {
            let meta = try decoder.decode(ServerMeta.self, from: metaData)
            print("[Validate] Decoded meta OK: api_version=\(meta.api_version), client_id=\(meta.oidc_client_id)")
            return meta
        } catch {
            let preview = String(data: metaData, encoding: .utf8)?.prefix(400) ?? ""
            print("[Validate] Meta decode failed:", error.localizedDescription)
            print("[Validate] Raw meta body prefix:", preview)
            throw BootstrapError.invalidMeta
        }
    }
}

