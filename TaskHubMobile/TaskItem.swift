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

    init(serverID: String, title: String, completed: Bool, updatedAt: Date, dueAt: Date? = nil, project: String? = nil, projectId: String? = nil, projectName: String? = nil, areaRaw: String? = nil) {
        self.serverID = serverID
        self.title = title
        self.completed = completed
        self.updatedAt = updatedAt
        self.dueAt = dueAt
        self.project = project
        self.projectId = projectId
        self.projectName = projectName
        self.areaRaw = areaRaw
    }
}
