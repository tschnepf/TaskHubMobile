import Foundation

// Delta sync response models for mobile client
// Placed in a standalone file to avoid accidental global-actor isolation from other contexts.

struct MobileDeltaResponse: Decodable {
    let events: [MobileDeltaEvent]
    let next_cursor: String?
}

struct MobileDeltaEvent: Decodable {
    let cursor: String
    let event_type: String
    let task_id: String?
    let payload_summary: [String: MobileDeltaJSONValue]?
    let occurred_at: Date
    let tombstone: Bool
}

enum MobileDeltaJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: MobileDeltaJSONValue])
    case array([MobileDeltaJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let arr = try? c.decode([MobileDeltaJSONValue].self) { self = .array(arr); return }
        if let obj = try? c.decode([String: MobileDeltaJSONValue].self) { self = .object(obj); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
}
