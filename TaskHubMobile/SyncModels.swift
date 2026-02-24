//
//  SyncModels.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation

struct DeltaCursor: Codable, Equatable {
    let value: String
}

struct TaskDelta: Decodable {
    let serverID: String
    let title: String
    let completed: Bool
    let updatedAt: Date
    let deleted: Bool
}

struct DeltaResponse: Decodable {
    let cursor: String
    let tasks: [TaskDelta]
}
