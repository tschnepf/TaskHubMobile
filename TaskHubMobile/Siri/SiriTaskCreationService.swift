import Foundation
import SwiftData
import os.log

struct SiriTaskInput {
    let title: String
    let projectSpokenName: String
    let area: TaskArea?
    let dueDate: Date?
}

enum ProjectResolutionResult: Equatable {
    case matched(String)
    case created(String)
    case ambiguous([String])
}

struct SiriTaskResult: Equatable {
    let title: String
    let projectName: String
    let area: TaskArea
    let dueDate: Date?
    let projectResolution: ProjectResolutionResult
}

@MainActor
protocol SiriTaskCreating {
    func createFromVoice(input: SiriTaskInput) async throws -> SiriTaskResult
}

enum SiriTaskCreationError: LocalizedError {
    case missingServerConfiguration
    case notAuthenticated
    case invalidTitle
    case invalidProjectName
    case ambiguousProject(candidates: [String])

    var errorDescription: String? {
        switch self {
        case .missingServerConfiguration:
            return "Task Hub server is not configured. Open the app and set the server URL first."
        case .notAuthenticated:
            return "You need to sign in to Task Hub in the app before using Siri."
        case .invalidTitle:
            return "Task title is required."
        case .invalidProjectName:
            return "Project name is required."
        case let .ambiguousProject(candidates):
            if candidates.isEmpty {
                return "I found multiple matching projects."
            }
            return "I found multiple matching projects: \(candidates.joined(separator: ", "))."
        }
    }
}

@MainActor
protocol SiriProjectServing {
    func listProjects() async throws -> [ProjectNameResolver.ProjectRecord]
    func createProject(named name: String) async throws -> ProjectNameResolver.ProjectRecord
}

@MainActor
protocol SiriTaskSubmitting {
    func createTask(title: String, area: TaskArea, projectName: String, dueAt: Date?) async throws
}

@MainActor
struct APIClientProjectService: SiriProjectServing {
    let api: APIClient

    func listProjects() async throws -> [ProjectNameResolver.ProjectRecord] {
        let projects = try await api.listProjects()
        return projects.map { ProjectNameResolver.ProjectRecord(id: $0.id, name: $0.name) }
    }

    func createProject(named name: String) async throws -> ProjectNameResolver.ProjectRecord {
        let created = try await api.createProject(name: name)
        return ProjectNameResolver.ProjectRecord(id: created.id, name: created.name)
    }
}

@MainActor
final class SyncControllerTaskSubmitter: SiriTaskSubmitting {
    private let syncController: SyncController

    init(syncController: SyncController) {
        self.syncController = syncController
    }

    func createTask(title: String, area: TaskArea, projectName: String, dueAt: Date?) async throws {
        try await syncController.createTask(
            title: title,
            area: area,
            priority: nil,
            projectName: projectName,
            dueAt: dueAt,
            repeatRule: nil
        )
    }
}

@MainActor
final class SiriTaskCreationService: SiriTaskCreating {
    private let projectService: SiriProjectServing
    private let taskSubmitter: SiriTaskSubmitting
    private let resolver: ProjectNameResolver
    private let calendar: Calendar
    private let logger = Logger(subsystem: "com.ie.TaskHubMobile", category: "SiriTaskCreation")

    init(
        projectService: SiriProjectServing,
        taskSubmitter: SiriTaskSubmitting,
        resolver: ProjectNameResolver? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.projectService = projectService
        self.taskSubmitter = taskSubmitter
        self.resolver = resolver ?? ProjectNameResolver()
        self.calendar = calendar
    }

    func createFromVoice(input: SiriTaskInput) async throws -> SiriTaskResult {
        let cleanedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            logger.log("siri_task_create outcome=invalid_title")
            throw SiriTaskCreationError.invalidTitle
        }

        let requestedProject = input.projectSpokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedProject.isEmpty else {
            logger.log("siri_task_create outcome=invalid_project")
            throw SiriTaskCreationError.invalidProjectName
        }

        let taskArea = input.area ?? .work
        let normalizedDueAt = DueDateNormalizer.normalizeToLocalNoon(input.dueDate, calendar: calendar)

        let existingProjects = try await projectService.listProjects()
        let decision = resolver.resolve(spokenName: requestedProject, projects: existingProjects)

        let resolvedProjectName: String
        let resolution: ProjectResolutionResult

        switch decision {
        case let .matched(project):
            resolvedProjectName = project.name
            resolution = .matched(project.name)
            logger.log("siri_task_create outcome=project_matched")
        case let .ambiguous(candidates):
            let names = candidates.map(\.name)
            logger.log("siri_task_create outcome=project_ambiguous")
            throw SiriTaskCreationError.ambiguousProject(candidates: names)
        case .noMatch:
            let createdProject = try await projectService.createProject(named: requestedProject)
            resolvedProjectName = createdProject.name
            resolution = .created(createdProject.name)
            logger.log("siri_task_create outcome=project_created")
        }

        do {
            try await taskSubmitter.createTask(
                title: cleanedTitle,
                area: taskArea,
                projectName: resolvedProjectName,
                dueAt: normalizedDueAt
            )
            logger.log("siri_task_create outcome=task_created")
        } catch {
            logger.log("siri_task_create outcome=task_creation_failed")
            throw error
        }

        return SiriTaskResult(
            title: cleanedTitle,
            projectName: resolvedProjectName,
            area: taskArea,
            dueDate: normalizedDueAt,
            projectResolution: resolution
        )
    }
}

@MainActor
enum SiriTaskServiceFactory {
    static func makeService() throws -> SiriTaskCreationService {
        let appConfig = AppConfig()
        guard appConfig.baseURL != nil else {
            throw SiriTaskCreationError.missingServerConfiguration
        }

        let authStore = AuthStore()
        guard authStore.accessToken != nil else {
            throw SiriTaskCreationError.notAuthenticated
        }

        let modelContainer = try makeModelContainer()
        let syncController = SyncController(container: modelContainer, appConfig: appConfig, authStore: authStore)
        let api = APIClient(baseURLProvider: { appConfig.baseURL }, authStore: authStore)

        let projectService = APIClientProjectService(api: api)
        let taskSubmitter = SyncControllerTaskSubmitter(syncController: syncController)
        return SiriTaskCreationService(projectService: projectService, taskSubmitter: taskSubmitter)
    }

    private static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([TaskItem.self])
        do {
            let config = ModelConfiguration()
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [fallback])
        }
    }
}
