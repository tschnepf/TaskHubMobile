import AppIntents
import Foundation

enum SiriTaskArea: String, AppEnum, CaseIterable {
    case work
    case personal

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Area"
    }

    static var caseDisplayRepresentations: [SiriTaskArea: DisplayRepresentation] {
        [
            .work: DisplayRepresentation(title: "Work"),
            .personal: DisplayRepresentation(title: "Personal")
        ]
    }

    var taskArea: TaskArea {
        switch self {
        case .work: return .work
        case .personal: return .personal
        }
    }
}

struct CreateTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Task"
    static let description = IntentDescription("Create a task in Task Hub using title, project, optional area, and optional due date.")
    static let openAppWhenRun = false

    @Parameter(
        title: "Task",
        requestValueDialog: IntentDialog("What task should I create?")
    )
    var title: String

    @Parameter(
        title: "Project",
        requestValueDialog: IntentDialog("Which project should I use?")
    )
    var projectName: String

    @Parameter(title: "Area")
    var area: SiriTaskArea?

    @Parameter(title: "Due Date")
    var dueDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Create task \(\.$title) for project \(\.$projectName)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try await MainActor.run { try SiriTaskServiceFactory.makeService() }
        let baseInput = SiriTaskInput(
            title: title,
            projectSpokenName: projectName,
            area: area?.taskArea,
            dueDate: dueDate
        )

        do {
            let result = try await service.createFromVoice(input: baseInput)
            return .result(dialog: successDialog(for: result))
        } catch SiriTaskCreationError.ambiguousProject(let candidates) {
            let chosenProject = try await $projectName.requestDisambiguation(
                among: candidates,
                dialog: IntentDialog("I found multiple matching projects. Which one did you want?")
            )

            let clarifiedInput = SiriTaskInput(
                title: title,
                projectSpokenName: chosenProject,
                area: area?.taskArea,
                dueDate: dueDate
            )
            let result = try await service.createFromVoice(input: clarifiedInput)
            return .result(dialog: successDialog(for: result))
        } catch let error as SiriTaskCreationError {
            return .result(dialog: "\(error.errorDescription ?? "I couldn't create the task.")")
        } catch let error as APIClientError {
            return .result(dialog: dialog(for: error))
        } catch {
            return .result(dialog: "I couldn't create that task right now. Please try again.")
        }
    }

    private func successDialog(for result: SiriTaskResult) -> IntentDialog {
        let createdProjectNote: String = {
            if case .created = result.projectResolution {
                return "I also created that project."
            }
            return ""
        }()

        if let dueDate = result.dueDate {
            let formattedDueDate = dueDate.formatted(date: .abbreviated, time: .omitted)
            if createdProjectNote.isEmpty {
                return "Created \(result.title) in project \(result.projectName) for \(result.area.rawValue). Due \(formattedDueDate)."
            }
            return "Created \(result.title) in project \(result.projectName) for \(result.area.rawValue). Due \(formattedDueDate). \(createdProjectNote)"
        }

        if createdProjectNote.isEmpty {
            return "Created \(result.title) in project \(result.projectName) for \(result.area.rawValue)."
        }
        return "Created \(result.title) in project \(result.projectName) for \(result.area.rawValue). \(createdProjectNote)"
    }

    private func dialog(for error: APIClientError) -> IntentDialog {
        switch error {
        case .missingBaseURL:
            return "Task Hub server is not configured. Open the app and set the server URL first."
        case .unauthorized:
            return "You're signed out. Open Task Hub and sign in, then try again."
        case .rateLimited:
            return "Task Hub is rate limiting requests right now. Please try again in a moment."
        case .decodingError:
            return "Task Hub returned an unexpected response. Please try again."
        case let .serverError(_, message, _, _):
            return "Task Hub couldn't create the task: \(message)"
        }
    }
}
