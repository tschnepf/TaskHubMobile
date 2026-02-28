//
//  WidgetCache.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

// Temporarily disabled widget snapshot fetching to prevent decode noise while focusing on in-app sync.
// This should be re-enabled when widget work resumes.

import Foundation
import Combine

fileprivate enum WidgetDateParsers {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

fileprivate func tolerantDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        if let d = WidgetDateParsers.withFractional.date(from: s) { return d }
        if let d = WidgetDateParsers.standard.date(from: s) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601: \(s)")
    }
    return d
}

struct WidgetSnapshotEnvelope: Codable {
    struct Meta: Codable { let timestamp: Date; let version: Int }
    let meta: Meta
    let payload: Data
}

struct WidgetSnapshot: Decodable {
    let generated_at: Date
    let tasks: [WidgetTask]
}

struct WidgetTask: Decodable {
    let id: String
    let title: String
    let status: String
    let due_at: Date?
    let priority: String
    let area: String
    let updated_at: Date
}

@MainActor
final class WidgetCache: ObservableObject {
    private let appGroupID: String
    private let fileManager = FileManager.default
    private let apiClientProvider: () -> APIClient
    private let ttl: TimeInterval

    @Published private(set) var lastWrite: Date?

    init(appGroupID: String, ttl: TimeInterval = 20 * 60, apiClientProvider: @escaping () -> APIClient) {
        self.appGroupID = appGroupID
        self.ttl = ttl
        self.apiClientProvider = apiClientProvider
    }

    private func cacheURL() -> URL? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            print("[WidgetCache] App Group container unavailable for id: \(appGroupID)")
            return nil
        }
        let dir = container.appendingPathComponent("widget", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    func isStale(now: Date = Date()) -> Bool {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url), let env = try? JSONDecoder().decode(WidgetSnapshotEnvelope.self, from: data) else {
            return true
        }
        return now.timeIntervalSince(env.meta.timestamp) > ttl
    }

    func refreshSnapshotIfNeeded() async {
        // Temporarily disabled while focusing on in-app sync.
        return
    }

    func refreshSnapshot() async {
        // Temporarily disabled while focusing on in-app sync.
        return
    }
}
