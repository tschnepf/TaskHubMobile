import Foundation

// MARK: - Resilient enums

enum MobileTaskArea: Decodable, Equatable {
    case personal
    case work
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "personal": self = .personal
        case "work": self = .work
        default: self = .unknown(raw)
        }
    }
}

enum MobileTaskStatus: Decodable, Equatable {
    case open
    case closed
    case archived
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "open": self = .open
        case "closed": self = .closed
        case "archived": self = .archived
        default: self = .unknown(raw)
        }
    }
}

enum MobileTaskRecurrence: Decodable, Equatable {
    case none
    case daily
    case weekly
    case monthly
    case yearly
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "none": self = .none
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: self = .unknown(raw)
        }
    }
}

enum MobileTaskIntent: Decodable, Equatable {
    case task
    case reminder
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "task": self = .task
        case "reminder": self = .reminder
        default: self = .unknown(raw)
        }
    }
}

// MARK: - DTOs

struct MobileTaskSummaryDTO: Decodable, Equatable {
    let id: String
    let title: String
    let is_completed: Bool
    let due_at: Date?
    let updated_at: Date
}

struct MobileTaskDetailDTO: Decodable, Equatable {
    let id: String
    let title: String
    let description: String?
    let notes: String?
    let attachments: [String]? // Placeholder; adjust to actual shape when needed
    let intent: MobileTaskIntent?
    let area: MobileTaskArea?
    let project: String? // UUID string or null
    let status: MobileTaskStatus?
    let priority: Int?
    let due_at: Date?
    let recurrence: MobileTaskRecurrence?
    let completed_at: Date?
    let position: Int?
    let created_at: Date?
    let updated_at: Date?
    let is_completed: Bool
}
