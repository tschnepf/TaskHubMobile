//
//  ServerBootstrap.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

fileprivate enum BootstrapDebugLog {
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }

    static func sanitize(_ value: String) -> String {
        let redactions: [(String, String)] = [
            ("(?i)\"access_token\"\\s*:\\s*\"[^\"]*\"", "\"access_token\":\"<redacted>\""),
            ("(?i)\"refresh_token\"\\s*:\\s*\"[^\"]*\"", "\"refresh_token\":\"<redacted>\""),
        ]
        var output = value
        for (pattern, replacement) in redactions {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return output
    }
}

struct ServerMeta: Codable {
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
    private static func normalizePath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.isEmpty { return "" }
        return "/" + parts.joined(separator: "/")
    }

    /// Canonicalize a Task Hub base URL.
    /// - Keeps scheme/host/port.
    /// - Removes query/fragment.
    /// - Collapses duplicate slashes in path.
    /// - Strips known API-only suffixes so callers don't accidentally build `/api/api/...`.
    static func canonicalBaseURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.scheme?.lowercased() == "https", components.host != nil else { return nil }

        let normalizedPath = normalizePath(components.path)
        let lower = normalizedPath.lowercased()
        if lower.isEmpty || lower == "/api" || lower == "/api/mobile" || lower == "/api/mobile/v1" {
            components.path = ""
        } else {
            components.path = normalizedPath
        }

        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Normalize input text to a https URL with no trailing slash.
    static func normalizeBaseURL(from input: String) -> URL? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed) else { return nil }
        return canonicalBaseURL(url)
    }

    /// Validate the server by calling /health/live and /api/mobile/v1/meta
    static func validate(baseURL: URL) async throws -> ServerMeta {
        let normalizedBaseURL = canonicalBaseURL(baseURL) ?? baseURL
        let healthURL = normalizedBaseURL.appendingPathComponent("health/live")
        let metaURL = normalizedBaseURL.appendingPathComponent("api/mobile/v1/meta")

        // Health check
        var healthReq = URLRequest(url: healthURL)
        healthReq.httpMethod = "GET"
        BootstrapDebugLog.log("[Validate] GET \(healthURL.absoluteString)")
        do {
            let (healthData, healthResp) = try await URLSession.shared.data(for: healthReq)
            if let http1 = healthResp as? HTTPURLResponse {
                let ct = http1.value(forHTTPHeaderField: "Content-Type") ?? "nil"
                BootstrapDebugLog.log("[Validate] Health status: \(http1.statusCode) Content-Type: \(ct) Bytes: \(healthData.count)")
                guard (200...299).contains(http1.statusCode) else {
                    let preview = String(data: healthData, encoding: .utf8).map { BootstrapDebugLog.sanitize(String($0.prefix(200))) } ?? "<non-utf8>"
                    BootstrapDebugLog.log("[Validate] Health body preview: \(preview)")
                    throw BootstrapError.unreachable
                }
            } else {
                BootstrapDebugLog.log("[Validate] Health: no HTTPURLResponse")
                throw BootstrapError.unreachable
            }
        } catch {
            BootstrapDebugLog.log("[Validate] Health request failed: \(error.localizedDescription)")
            throw BootstrapError.unreachable
        }

        // Meta
        var metaReq = URLRequest(url: metaURL)
        metaReq.httpMethod = "GET"
        metaReq.setValue("application/json", forHTTPHeaderField: "Accept")
        BootstrapDebugLog.log("[Validate] GET \(metaURL.absoluteString)")
        let (metaData, metaResp) = try await URLSession.shared.data(for: metaReq)
        guard let http2 = metaResp as? HTTPURLResponse else {
            BootstrapDebugLog.log("[Validate] Meta: no HTTPURLResponse")
            throw BootstrapError.invalidResponse
        }
        let ct2 = http2.value(forHTTPHeaderField: "Content-Type") ?? "nil"
        BootstrapDebugLog.log("[Validate] Meta status: \(http2.statusCode) Content-Type: \(ct2) Bytes: \(metaData.count)")
        guard (200...299).contains(http2.statusCode) else {
            let preview = String(data: metaData, encoding: .utf8).map { BootstrapDebugLog.sanitize(String($0.prefix(300))) } ?? "<non-utf8>"
            BootstrapDebugLog.log("[Validate] Meta body preview: \(preview)")
            throw BootstrapError.invalidResponse
        }

        let decoder = JSONDecoder()
        do {
            let meta = try decoder.decode(ServerMeta.self, from: metaData)
            BootstrapDebugLog.log("[Validate] Decoded meta OK: api_version=\(meta.api_version), client_id=\(meta.oidc_client_id)")
            return meta
        } catch {
            let preview = String(data: metaData, encoding: .utf8).map { BootstrapDebugLog.sanitize(String($0.prefix(400))) } ?? "<non-utf8>"
            BootstrapDebugLog.log("[Validate] Meta decode failed: \(error.localizedDescription)")
            BootstrapDebugLog.log("[Validate] Raw meta body prefix: \(preview)")
            throw BootstrapError.invalidMeta
        }
    }
}
