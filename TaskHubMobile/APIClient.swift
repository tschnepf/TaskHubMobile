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

fileprivate enum NetworkDateParsers {
    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let retryAfterPrimary: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter
    }()

    static let retryAfterFallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE',' dd-MMM-yy HH':'mm':'ss zzz"
        return formatter
    }()
}

fileprivate enum NetworkDebugLog {
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }

    static func sanitizedBodyPreview(_ data: Data, limit: Int = 400) -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            return "<non-utf8>"
        }
        let redactions: [(String, String)] = [
            ("(?i)\"access_token\"\\s*:\\s*\"[^\"]*\"", "\"access_token\":\"<redacted>\""),
            ("(?i)\"refresh_token\"\\s*:\\s*\"[^\"]*\"", "\"refresh_token\":\"<redacted>\""),
            ("(?i)\"authorization\"\\s*:\\s*\"[^\"]*\"", "\"authorization\":\"<redacted>\""),
        ]
        for (pattern, replacement) in redactions {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(text.prefix(limit))
    }
}

fileprivate enum JSONDecoders {
    static func tolerant() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = NetworkDateParsers.iso8601Fractional.date(from: str) { return d }
            if let d = NetworkDateParsers.iso8601.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return decoder
    }
}

fileprivate enum HTTPDateParser {
    static func parse(_ value: String) -> Date? {
        if let date = NetworkDateParsers.retryAfterPrimary.date(from: value) { return date }
        return NetworkDateParsers.retryAfterFallback.date(from: value)
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
                    let preview = NetworkDebugLog.sanitizedBodyPreview(data)
                    NetworkDebugLog.log("[Decode] Failed GET /\(path): \(error)")
                    NetworkDebugLog.log("[Decode] Body prefix: \(preview)")
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
                let preview = NetworkDebugLog.sanitizedBodyPreview(data)
                NetworkDebugLog.log("[Decode] Failed \(method) /\(path): \(error)")
                NetworkDebugLog.log("[Decode] Body prefix: \(preview)")
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

    // MARK: - Tasks: Update
    func updateTask(id: String, title: String?, completed: Bool?, dueAt: Date?, projectName: String? = nil, area: TaskArea? = nil, priority: TaskPriority? = nil, repeatRule: RepeatRule? = nil) async throws -> MobileTaskDetailDTO {
        guard let base = baseURLProvider() else { throw APIClientError.missingBaseURL }
        var basePayload: [String: Any] = [:]
        if let title { basePayload["title"] = title }
        if let dueAt {
            basePayload["due_at"] = NetworkDateParsers.iso8601.string(from: dueAt)
        }
        if let projectName, !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { basePayload["project"] = projectName }
        if let area { basePayload["area"] = area.rawValue }
        if let priority { basePayload["priority"] = priority.rawValue }
        if let repeatRule { basePayload["recurrence"] = repeatRule.rawValue }

        var payloadVariants: [[String: Any]] = []
        if let completed {
            var statusPayload = basePayload
            statusPayload["status"] = completed ? "done" : "next"
            payloadVariants.append(statusPayload)

            // Backward compatibility for servers that accept boolean completion directly.
            var legacyPayload = basePayload
            legacyPayload["is_completed"] = completed
            payloadVariants.append(legacyPayload)
        } else {
            payloadVariants.append(basePayload)
        }

        let urls = [
            base.appendingPathComponent("api/mobile/v1/tasks").appendingPathComponent(id),
            base.appendingPathComponent("api/mobile/v1/tasks").appendingPathComponent(id).appendingPathComponent("")
        ]
        let transientStatusCodes: Set<Int> = [429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 527]
        let transientURLErrorCodes: Set<URLError.Code> = [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .badServerResponse]
        let maxRetries = 3
        var lastError: Error?

        for payload in payloadVariants {
            let body = try JSONSerialization.data(withJSONObject: payload, options: [])
            for url in urls {
                for retry in 0..<maxRetries {
                    do {
                        var req = URLRequest(url: url)
                        req.httpMethod = "PATCH"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("application/json", forHTTPHeaderField: "Accept")
                        req.timeoutInterval = 15
                        req.httpBody = body
                        try await attachAuth(&req)

                        var (data, resp) = try await APIClient.urlSession.data(for: req)
                        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                            await authStore.refresh()
                            try await attachAuth(&req)
                            (data, resp) = try await APIClient.urlSession.data(for: req)
                        }
                        guard let http = resp as? HTTPURLResponse else {
                            lastError = URLError(.badServerResponse)
                            continue
                        }

                        switch http.statusCode {
                        case 200...299:
                            if data.isEmpty {
                                if let fetched = try? await getTaskDetail(id: id) { return fetched }
                                return MobileTaskDetailDTO(
                                    id: id,
                                    title: title ?? "",
                                    description: nil,
                                    notes: nil,
                                    attachments: nil,
                                    intent: nil,
                                    area: area.map { $0 == .work ? .work : .personal },
                                    projectId: nil,
                                    projectName: projectName,
                                    status: nil,
                                    priority: priority?.rawValue,
                                    due_at: dueAt,
                                    recurrence: repeatRule.map {
                                        switch $0 {
                                        case .none: return .none
                                        case .daily: return .daily
                                        case .weekly: return .weekly
                                        case .monthly: return .monthly
                                        case .yearly: return .yearly
                                        }
                                    },
                                    completed_at: nil,
                                    position: nil,
                                    created_at: nil,
                                    updated_at: Date(),
                                    is_completed: completed ?? false
                                )
                            }
                            let decoder = JSONDecoder.mobileRFC3339()
                            if let detail = try? decoder.decode(MobileTaskDetailDTO.self, from: data) {
                                return detail
                            }
                            if let fetched = try? await getTaskDetail(id: id) { return fetched }
                            return MobileTaskDetailDTO(
                                id: id,
                                title: title ?? "",
                                description: nil,
                                notes: nil,
                                attachments: nil,
                                intent: nil,
                                area: area.map { $0 == .work ? .work : .personal },
                                projectId: nil,
                                projectName: projectName,
                                status: nil,
                                priority: priority?.rawValue,
                                due_at: dueAt,
                                recurrence: repeatRule.map {
                                    switch $0 {
                                    case .none: return .none
                                    case .daily: return .daily
                                    case .weekly: return .weekly
                                    case .monthly: return .monthly
                                    case .yearly: return .yearly
                                    }
                                },
                                completed_at: nil,
                                position: nil,
                                created_at: nil,
                                updated_at: Date(),
                                is_completed: completed ?? false
                            )
                        case 401:
                            throw APIClientError.unauthorized
                        default:
                            if transientStatusCodes.contains(http.statusCode), retry < (maxRetries - 1) {
                                try? await Task.sleep(nanoseconds: UInt64((retry + 1) * 300_000_000))
                                continue
                            }
                            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                                lastError = APIClientError.serverError(code: envelope.error.code, message: envelope.error.message, requestID: envelope.request_id, details: data)
                            } else {
                                lastError = APIClientError.serverError(
                                    code: "http_\(http.statusCode)",
                                    message: "Task update failed: HTTP \(http.statusCode). Body prefix: \(NetworkDebugLog.sanitizedBodyPreview(data, limit: 200))",
                                    requestID: http.value(forHTTPHeaderField: "X-Request-ID"),
                                    details: data
                                )
                            }
                        }
                    } catch let urlError as URLError {
                        if transientURLErrorCodes.contains(urlError.code), retry < (maxRetries - 1) {
                            try? await Task.sleep(nanoseconds: UInt64((retry + 1) * 300_000_000))
                            continue
                        }
                        lastError = urlError
                    } catch {
                        lastError = error
                    }
                }
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }

    // MARK: - Tasks: Detail
    func getTaskDetail(id: String) async throws -> MobileTaskDetailDTO {
        guard let base = baseURLProvider() else { throw APIClientError.missingBaseURL }
        let urls = [
            base.appendingPathComponent("api/mobile/v1/tasks").appendingPathComponent(id),
            base.appendingPathComponent("api/mobile/v1/tasks").appendingPathComponent(id).appendingPathComponent("")
        ]
        var lastError: Error?

        for url in urls {
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
            guard let http = resp as? HTTPURLResponse else {
                lastError = URLError(.badServerResponse)
                continue
            }
            switch http.statusCode {
            case 200...299:
                let decoder = JSONDecoder.mobileRFC3339()
                do {
                    return try decoder.decode(MobileTaskDetailDTO.self, from: data)
                } catch {
                    lastError = APIClientError.decodingError
                }
            case 401:
                throw APIClientError.unauthorized
            default:
                if let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                    lastError = APIClientError.serverError(code: env.error.code, message: env.error.message, requestID: env.request_id, details: data)
                } else {
                    let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<non-utf8>"
                    lastError = APIClientError.serverError(
                        code: "http_\(http.statusCode)",
                        message: "Task detail fetch failed: HTTP \(http.statusCode). Body prefix: \(preview)",
                        requestID: http.value(forHTTPHeaderField: "X-Request-ID"),
                        details: data
                    )
                }
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }

    // MARK: - Mobile Preferences
    struct MobilePreferencesDTO: Codable {
        enum CodingKeys: String, CodingKey {
            case areaTextColoringEnabled = "area_text_coloring_enabled"
            case workAreaTextColor = "work_area_text_color"
            case personalAreaTextColor = "personal_area_text_color"
        }
        var areaTextColoringEnabled: Bool?
        var workAreaTextColor: String?
        var personalAreaTextColor: String?
    }

    func getMobilePreferences() async throws -> MobilePreferencesDTO {
        return try await get("api/mobile/v1/me/preferences")
    }

    func patchMobilePreferences(_ payload: [String: Any]) async throws -> MobilePreferencesDTO {
        guard let base = baseURLProvider() else { throw APIClientError.missingBaseURL }
        let url = base.appendingPathComponent("api/mobile/v1/me/preferences")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await attachAuth(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        var (data, resp) = try await APIClient.urlSession.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            await authStore.refresh()
            try await attachAuth(&req)
            (data, resp) = try await APIClient.urlSession.data(for: req)
        }
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoders.tolerant()
            do { return try decoder.decode(MobilePreferencesDTO.self, from: data) } catch { throw APIClientError.decodingError }
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
}
