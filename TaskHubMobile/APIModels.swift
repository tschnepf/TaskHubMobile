//
//  APIModels.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

fileprivate enum RFC3339Formatters {
    static let noFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

fileprivate enum RFC3339Decoders {
    static func rfc3339() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            // Primary: no fractional seconds
            if let d = RFC3339Formatters.noFractional.date(from: s) { return d }
            // Fallback: fractional seconds
            if let d = RFC3339Formatters.withFractional.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid RFC3339 date: \(s)")
        }
        return d
    }
}

struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
        let message: String
        // details intentionally omitted for resilience
    }
    let error: APIError
    let request_id: String?
}
extension JSONDecoder {
    static func mobileRFC3339() -> JSONDecoder { RFC3339Decoders.rfc3339() }
}
