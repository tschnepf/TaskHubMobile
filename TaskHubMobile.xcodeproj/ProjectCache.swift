import Foundation
import WidgetKit

struct ProjectListSnapshot: Codable {
    let projects: [String]
}

actor ProjectCache {
    private let appGroupCache: AppGroupCache
    private let fileName = "projects.json"
    private var inMemory: [String] = []

    init(appGroupCache: AppGroupCache) {
        self.appGroupCache = appGroupCache
        Task { await load() }
    }

    func load() async {
        if let data = appGroupCache.readShared(fileName: fileName) {
            let decoder = JSONDecoder()
            if let snapshot = try? decoder.decode(ProjectListSnapshot.self, from: data) {
                inMemory = snapshot.projects
                return
            }
        }
        inMemory = []
        await save()
    }

    func save() async {
        let snapshot = ProjectListSnapshot(projects: inMemory)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            appGroupCache.writeShared(fileName: fileName, data: data)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func setProjects(_ names: [String]) async {
        inMemory = Array(Set(names)).sorted()
        await save()
    }

    func addProjects(_ names: [String]) async {
        inMemory.append(contentsOf: names)
        inMemory = Array(Set(inMemory)).sorted()
        await save()
    }

    func all() async -> [String] { inMemory }

    func suggestions(prefix: String, limit: Int = 8) async -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return [] }
        let matches = inMemory.filter { $0.lowercased().contains(p) }
        return Array(matches.prefix(limit))
    }
}
