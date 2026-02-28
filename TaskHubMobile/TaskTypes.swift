import Foundation

// Shared task-related types used by APIClient, views, and sync.
// Keep raw values in sync with server expectations.

enum TaskArea: String, Codable, CaseIterable, Identifiable {
    case personal
    case work

    var id: String { rawValue }
}

enum TaskPriority: Int, Codable, CaseIterable, Identifiable {
    case one = 1, two, three, four, five

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .one: return "1 (Highest)"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5 (Lowest)"
        }
    }
}

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }
}
