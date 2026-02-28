import Foundation
import Testing
@testable import TaskHubMobile

struct ProjectNameResolverTests {

    @Test("Resolves exact normalized project name")
    func resolvesExactMatch() {
        let resolver = ProjectNameResolver()
        let projects = [
            ProjectNameResolver.ProjectRecord(id: "1", name: "Home"),
            ProjectNameResolver.ProjectRecord(id: "2", name: "Operations")
        ]

        let decision = resolver.resolve(spokenName: " home ", projects: projects)
        switch decision {
        case let .matched(project):
            #expect(project.name == "Home")
        default:
            #expect(Bool(false), "Expected exact match")
        }
    }

    @Test("Returns ambiguous for conservative prefix collisions")
    func resolvesAmbiguousPrefix() {
        let resolver = ProjectNameResolver()
        let projects = [
            ProjectNameResolver.ProjectRecord(id: "1", name: "Ops"),
            ProjectNameResolver.ProjectRecord(id: "2", name: "Operations")
        ]

        let decision = resolver.resolve(spokenName: "op", projects: projects)
        switch decision {
        case let .ambiguous(candidates):
            #expect(candidates.count == 2)
        default:
            #expect(Bool(false), "Expected ambiguous result")
        }
    }

    @Test("Returns noMatch when nothing is close")
    func resolvesNoMatch() {
        let resolver = ProjectNameResolver()
        let projects = [
            ProjectNameResolver.ProjectRecord(id: "1", name: "Home"),
            ProjectNameResolver.ProjectRecord(id: "2", name: "Ops")
        ]

        let decision = resolver.resolve(spokenName: "Finance", projects: projects)
        #expect(decision == .noMatch)
    }
}

struct DueDateNormalizerTests {

    @Test("Normalizes date input to local noon")
    func normalizesToNoon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 3600))

        let source = try #require(ISO8601DateFormatter().date(from: "2026-03-14T23:30:00Z"))
        let normalized = try #require(DueDateNormalizer.normalizeToLocalNoon(source, calendar: calendar))

        let day = calendar.component(.day, from: normalized)
        let hour = calendar.component(.hour, from: normalized)
        let expectedDay = calendar.component(.day, from: source)

        #expect(day == expectedDay)
        #expect(hour == 12)
    }
}

@MainActor
private final class MockProjectService: SiriProjectServing {
    var projects: [ProjectNameResolver.ProjectRecord]
    var createCalls: [String] = []

    init(projects: [ProjectNameResolver.ProjectRecord]) {
        self.projects = projects
    }

    func listProjects() async throws -> [ProjectNameResolver.ProjectRecord] {
        projects
    }

    func createProject(named name: String) async throws -> ProjectNameResolver.ProjectRecord {
        createCalls.append(name)
        let created = ProjectNameResolver.ProjectRecord(id: "new-\(createCalls.count)", name: name)
        projects.append(created)
        return created
    }
}

@MainActor
private final class MockTaskSubmitter: SiriTaskSubmitting {
    struct Call {
        let title: String
        let area: TaskArea
        let projectName: String
        let dueAt: Date?
    }

    var calls: [Call] = []

    func createTask(title: String, area: TaskArea, projectName: String, dueAt: Date?) async throws {
        calls.append(Call(title: title, area: area, projectName: projectName, dueAt: dueAt))
    }
}

struct SiriTaskCreationServiceTests {

    @MainActor
    @Test("Defaults area to work and uses matched project")
    func defaultsAreaToWork() async throws {
        let projectService = MockProjectService(projects: [
            .init(id: "1", name: "Home")
        ])
        let taskSubmitter = MockTaskSubmitter()
        let service = SiriTaskCreationService(projectService: projectService, taskSubmitter: taskSubmitter)

        let result = try await service.createFromVoice(input: SiriTaskInput(
            title: "Buy milk",
            projectSpokenName: "home",
            area: nil,
            dueDate: nil
        ))

        #expect(result.area == .work)
        #expect(result.projectResolution == .matched("Home"))
        #expect(taskSubmitter.calls.count == 1)
        #expect(taskSubmitter.calls[0].projectName == "Home")
        #expect(projectService.createCalls.isEmpty)
    }

    @MainActor
    @Test("Creates project when there is no match")
    func createsProjectOnNoMatch() async throws {
        let projectService = MockProjectService(projects: [
            .init(id: "1", name: "Home")
        ])
        let taskSubmitter = MockTaskSubmitter()
        let service = SiriTaskCreationService(projectService: projectService, taskSubmitter: taskSubmitter)

        let result = try await service.createFromVoice(input: SiriTaskInput(
            title: "Pay rent",
            projectSpokenName: "Finance",
            area: .personal,
            dueDate: nil
        ))

        #expect(projectService.createCalls == ["Finance"])
        #expect(result.projectResolution == .created("Finance"))
        #expect(taskSubmitter.calls.count == 1)
        #expect(taskSubmitter.calls[0].projectName == "Finance")
    }

    @MainActor
    @Test("Returns ambiguous error and does not create task")
    func throwsAmbiguousError() async {
        let projectService = MockProjectService(projects: [
            .init(id: "1", name: "Ops"),
            .init(id: "2", name: "Operations")
        ])
        let taskSubmitter = MockTaskSubmitter()
        let service = SiriTaskCreationService(projectService: projectService, taskSubmitter: taskSubmitter)

        var caughtAmbiguous = false
        do {
            _ = try await service.createFromVoice(input: SiriTaskInput(
                title: "Plan sprint",
                projectSpokenName: "op",
                area: nil,
                dueDate: nil
            ))
        } catch let error as SiriTaskCreationError {
            if case let .ambiguousProject(candidates) = error {
                caughtAmbiguous = true
                #expect(candidates.count == 2)
            }
        } catch {
            #expect(Bool(false), "Expected SiriTaskCreationError")
        }

        #expect(caughtAmbiguous)
        #expect(taskSubmitter.calls.isEmpty)
    }

    @MainActor
    @Test("Normalizes due date to noon before submission")
    func normalizesDueDateForCreate() async throws {
        let projectService = MockProjectService(projects: [
            .init(id: "1", name: "Home")
        ])
        let taskSubmitter = MockTaskSubmitter()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600) ?? .autoupdatingCurrent

        let service = SiriTaskCreationService(
            projectService: projectService,
            taskSubmitter: taskSubmitter,
            calendar: calendar
        )

        let sourceDue = ISO8601DateFormatter().date(from: "2026-03-14T23:30:00Z")
        _ = try await service.createFromVoice(input: SiriTaskInput(
            title: "Call plumber",
            projectSpokenName: "Home",
            area: .work,
            dueDate: sourceDue
        ))

        let submittedDue = try #require(taskSubmitter.calls.first?.dueAt)
        let hour = calendar.component(.hour, from: submittedDue)
        #expect(hour == 12)
    }
}
