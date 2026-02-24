//
//  Idempotency.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

struct IdempotencyKey: Codable, Hashable {
    let value: String
    let createdAt: Date
    let ttlSeconds: TimeInterval

    var isExpired: Bool { Date() > createdAt.addingTimeInterval(ttlSeconds) }
}

final class IdempotencyStore {
    private let defaults: UserDefaults
    private let storageKey = "idempotency.keys"

    init(suiteName: String? = AppIdentifiers.appGroupID) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
    }

    func generate(ttlSeconds: TimeInterval = 24 * 60 * 60) -> IdempotencyKey {
        IdempotencyKey(value: UUID().uuidString, createdAt: Date(), ttlSeconds: ttlSeconds)
    }

    func save(_ key: IdempotencyKey) {
        var all = loadAll()
        all[key.value] = key
        persist(all)
    }

    func use(_ key: IdempotencyKey) {
        // Optionally keep for audit or remove immediately
        var all = loadAll()
        all[key.value] = key
        persist(all)
    }

    func cleanupExpired() {
        var all = loadAll()
        all = all.filter { !$0.value.isExpired }
        persist(all)
    }

    private func loadAll() -> [String: IdempotencyKey] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        let dict = (try? JSONDecoder().decode([String: IdempotencyKey].self, from: data)) ?? [:]
        return dict
    }

    private func persist(_ dict: [String: IdempotencyKey]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
