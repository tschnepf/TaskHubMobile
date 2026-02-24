import Foundation

actor ProjectCache {
    private var names: [String] = []
    private let defaults: UserDefaults
    private let storageKey = "project.names"

    init(suiteName: String? = AppIdentifiers.appGroupID) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        load()
    }

    private func load() {
        if let arr = defaults.array(forKey: storageKey) as? [String] {
            self.names = arr
        } else {
            self.names = []
        }
    }

    private func save() {
        defaults.set(names, forKey: storageKey)
    }

    func setProjects(_ input: [String]) async {
        names = Array(Set(input.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        save()
    }

    func addProjects(_ input: [String]) async {
        let cleaned = input.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        names.append(contentsOf: cleaned)
        names = Array(Set(names)).sorted()
        save()
    }

    func suggestions(prefix: String, limit: Int = 8) async -> [String] {
        let q = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let matches = names.filter { $0.lowercased().contains(q) }
        return Array(matches.prefix(limit))
    }
}
