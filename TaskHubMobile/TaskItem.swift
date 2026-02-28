//
//  TaskItem.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import SwiftData

@Model
final class TaskItem {
    @Attribute(.unique) var serverID: String
    var title: String
    var completed: Bool
    var updatedAt: Date
    var dueAt: Date?
    var project: String?
    var projectId: String?
    var projectName: String?
    var areaRaw: String?
    var priority: Int?
    var recurrenceRaw: String?

    init(
        serverID: String,
        title: String,
        completed: Bool,
        updatedAt: Date,
        dueAt: Date? = nil,
        project: String? = nil,
        projectId: String? = nil,
        projectName: String? = nil,
        areaRaw: String? = nil,
        priority: Int? = nil,
        recurrenceRaw: String? = nil
    ) {
        self.serverID = serverID
        self.title = title
        self.completed = completed
        self.updatedAt = updatedAt
        self.dueAt = dueAt
        self.project = project
        self.projectId = projectId
        self.projectName = projectName
        self.areaRaw = areaRaw
        self.priority = priority
        self.recurrenceRaw = recurrenceRaw
    }
}

extension TaskItem {
    var normalizedArea: TaskArea? {
        switch (areaRaw ?? "").lowercased() {
        case TaskArea.work.rawValue:
            return .work
        case TaskArea.personal.rawValue:
            return .personal
        default:
            return nil
        }
    }

    var repeatRule: RepeatRule? {
        guard let recurrenceRaw else { return nil }
        return RepeatRule(rawValue: recurrenceRaw.lowercased())
    }

    var priorityLabel: String? {
        guard let priority, (1...5).contains(priority) else { return nil }
        return "P\(priority)"
    }
}
