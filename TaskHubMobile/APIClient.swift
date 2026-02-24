//
//  APIClient.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

extension APIClient {
    static var urlSession: URLSession = .shared
}

fileprivate enum JSONDecoders {
    static func tolerant() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            // Try fractional seconds first
            let iso8601Frac = ISO8601DateFormatter()
            iso8601Frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso8601Frac.date(from: str) { return d }
            // Fallback to no fractional seconds
            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime]
            if let d = iso8601.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return decoder
    }
}

fileprivate enum HTTPDateParser {
    static func parse(_ value: String) -> Date? {
        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz"
        ]
        for f in formats {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = f
            if let date = fmt.date(from: value) { return date }
        }
        return nil
    }
}

enum APIClientError: Error, LocalizedError {
    case missingBaseURL
    case unauthorized
    case serverError(code: String, message: String, requestID: String?, details: Data?)
    case rateLimited(retryAfter: TimeInterval?)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Missing server URL."
        case .unauthorized:
            return "Unauthorized. Please sign in again."
        case let .serverError(code, message, requestID, _):
            if let requestID { return "\(message) (\(code), req: \(requestID))" }
            return "\(message) (\(code))"
        case let .rateLimited(retryAfter):
            if let s = retryAfter { return "Rate limited. Retry after \(Int(s))s." }
            return "Rate limited. Please try again later."
        case .decodingError:
            return "Failed to decode server response."
        }
    }
}

struct APIClient {
    let baseURLProvider: () -> URL?
    @MainActor let authStore: AuthStore

    init(baseURLProvider: @escaping () -> URL?, authStore: AuthStore) {
        self.baseURLProvider = baseURLProvider
        self.authStore = authStore
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path: path, method: "GET", body: nil, idempotencyKey: nil)
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        guard let base = baseURLProvider() else { throw APIClientError.missingBaseURL }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        try await attachAuth(&req)
        var (data, resp) = try await APIClient.urlSession.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            await authStore.refresh()
            try await attachAuth(&req)
            (data, resp) = try await APIClient.urlSession.data(for: req)
        }
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200...299:
            do {
                let decoder = JSONDecoders.tolerant()
                do {
                    return try decoder.decode(T.self, from: data)
                } catch {
                    let preview = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
                    print("[Decode] Failed GET /\(path):", error)
                    print("[Decode] Body prefix:", preview)
                    throw APIClientError.decodingError
                }
            }
        case 401:
            throw APIClientError.unauthorized
        default:
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                throw APIClientError.serverError(code: envelope.error.code, message: envelope.error.message, requestID: envelope.request_id, details: data)
            } else {
                throw URLError(.badServerResponse)
            }
        }
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B, idempotencyKey: String? = nil) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: "POST", body: data, idempotencyKey: idempotencyKey)
    }

    private func request<T: Decodable>(path: String, method: String, body: Data?, idempotencyKey: String?) async throws -> T {
        guard let base = baseURLProvider() else { throw APIClientError.missingBaseURL }
        let url = base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // Attach token and attempt preemptive refresh
        try await attachAuth(&req)

        // First attempt
        var (data, resp) = try await APIClient.urlSession.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            // Refresh once and retry
            await authStore.refresh()
            try await attachAuth(&req)
            (data, resp) = try await APIClient.urlSession.data(for: req)
        }

        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoders.tolerant()
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                let preview = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
                print("[Decode] Failed \(method) /\(path):", error)
                print("[Decode] Body prefix:", preview)
                throw APIClientError.decodingError
            }
        case 401:
            throw APIClientError.unauthorized
        default:
            if http.statusCode == 429 {
                var retryAfterSeconds: TimeInterval? = nil
                if let retryAfter = http.value(forHTTPHeaderField: "Retry-After") {
                    if let seconds = TimeInterval(retryAfter) {
                        retryAfterSeconds = seconds
                    } else if let date = HTTPDateParser.parse(retryAfter) {
                        retryAfterSeconds = max(0, date.timeIntervalSinceNow)
                    }
                }
                throw APIClientError.rateLimited(retryAfter: retryAfterSeconds)
            }
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                throw APIClientError.serverError(code: envelope.error.code, message: envelope.error.message, requestID: envelope.request_id, details: data)
            } else {
                throw URLError(.badServerResponse)
            }
        }
    }

    @MainActor
    private func attachAuth(_ req: inout URLRequest) async throws {
        await authStore.refreshIfNeeded()
        if let token = authStore.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    struct ProjectDTO: Decodable { let id: String; let name: String }
    func findProjectByName(_ name: String) async throws -> ProjectDTO? {
        let items: [ProjectDTO] = try await get("api/mobile/v1/projects", query: [URLQueryItem(name: "name", value: name)])
        return items.first
    }

    func createProject(name: String) async throws -> ProjectDTO {
        struct CreateProjectBody: Encodable { let name: String }
        return try await post("api/mobile/v1/projects", body: CreateProjectBody(name: name))
    }

    func listProjects() async throws -> [ProjectDTO] {
        return try await get("api/mobile/v1/projects")
    }
}

