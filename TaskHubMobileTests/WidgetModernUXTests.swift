import Testing
import Foundation
import WidgetKit
@testable import TaskHubMobile

struct WidgetSnapshotCodecTests {

    @Test("Decode legacy v1 widget snapshot")
    func decodeLegacyV1Snapshot() async throws {
        let json = """
        {
          "count": 2,
          "tasks": [
            {"title": "Legacy one", "is_completed": false, "due_at": "2026-02-28T08:00:00Z"},
            {"title": "Legacy done", "is_completed": true, "due_at": null}
          ]
        }
        """.data(using: .utf8)!

        let decoded = try #require(WidgetSnapshotCodec.decode(json))
        #expect(decoded.count == 2)
        #expect(decoded.version == nil)
        #expect(decoded.tasks.count == 2)

        let open = WidgetSnapshotCodec.openTasks(from: decoded)
        #expect(open.count == 1)
        #expect(open.tasks.first?.title == "Legacy one")
    }

    @Test("Decode v2 widget snapshot fields")
    func decodeV2SnapshotFields() async throws {
        let json = """
        {
          "version": 2,
          "generated_at": "2026-02-28T08:00:00Z",
          "count": 1,
          "tasks": [
            {
              "id": "task-1",
              "title": "Modern",
              "is_completed": false,
              "due_at": "2026-03-01T08:00:00Z",
              "area": "work",
              "project_name": "Mobile",
              "priority": 2,
              "updated_at": "2026-02-28T08:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try #require(WidgetSnapshotCodec.decode(json))
        #expect(decoded.version == 2)
        #expect(decoded.generatedAt != nil)
        #expect(decoded.tasks.first?.id == "task-1")
        #expect(decoded.tasks.first?.area == "work")
        #expect(decoded.tasks.first?.projectName == "Mobile")
        #expect(decoded.tasks.first?.priority == 2)
    }

    @Test("Scope filtering uses explicit area")
    func scopeFilteringUsesArea() async throws {
        let snapshot = WidgetTasksSnapshot(
            version: 2,
            generatedAt: .now,
            count: 3,
            tasks: [
                WidgetTaskSnapshotItem(id: "1", title: "A", isCompleted: false, dueAt: nil, area: "work"),
                WidgetTaskSnapshotItem(id: "2", title: "B", isCompleted: false, dueAt: nil, area: "personal"),
                WidgetTaskSnapshotItem(id: "3", title: "C", isCompleted: false, dueAt: nil, area: nil)
            ]
        )

        let work = WidgetSnapshotCodec.tasks(for: .work, in: snapshot)
        let personal = WidgetSnapshotCodec.tasks(for: .personal, in: snapshot)
        let all = WidgetSnapshotCodec.tasks(for: .all, in: snapshot)

        #expect(work.map(\.id) == ["1"])
        #expect(personal.map(\.id) == ["2"])
        #expect(all.count == 3)
    }

    @Test("Density row limits match widget families")
    func densityRowLimits() async throws {
        #expect(WidgetTaskDensity.compact.rowLimit(for: .systemSmall) == 1)
        #expect(WidgetTaskDensity.compact.rowLimit(for: .systemMedium) == 5)
        #expect(WidgetTaskDensity.balanced.rowLimit(for: .systemMedium) == 4)
        #expect(WidgetTaskDensity.compact.rowLimit(for: .systemLarge) == 10)
        #expect(WidgetTaskDensity.balanced.rowLimit(for: .systemExtraLarge) == 12)
    }
}

@MainActor
struct WidgetDeepLinkRoutingTests {

    @Test("Parse tasks deep link scope")
    func parseTasksScope() async throws {
        let url = try #require(URL(string: "taskhubmobile://open/tasks?scope=work"))
        let action = DefaultAppEnvironment.parseDeepLinkAction(from: url)
        #expect(action == .openTasks(scope: .work))
    }

    @Test("Parse quick add deep link")
    func parseQuickAdd() async throws {
        let url = try #require(URL(string: "taskhubmobile://open/quickadd"))
        let action = DefaultAppEnvironment.parseDeepLinkAction(from: url)
        #expect(action == .openQuickAdd(scope: nil))
    }

    @Test("Ignore unsupported deep links")
    func ignoreUnsupported() async throws {
        let url = try #require(URL(string: "taskhubmobile://oauth/callback?code=abc"))
        let action = DefaultAppEnvironment.parseDeepLinkAction(from: url)
        #expect(action == nil)
    }
}

@MainActor
struct LiveActivitySnapshotTests {

    @Test("Progress snapshot counts remaining and completed today")
    func progressSnapshotCounts() async throws {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let tasks = [
            TaskItem(serverID: "1", title: "Open", completed: false, updatedAt: now, dueAt: now, areaRaw: "work"),
            TaskItem(serverID: "2", title: "Done today", completed: true, updatedAt: now, dueAt: nil, areaRaw: "personal"),
            TaskItem(serverID: "3", title: "Done yesterday", completed: true, updatedAt: yesterday, dueAt: nil, areaRaw: "personal")
        ]

        let snapshot = LiveActivityCoordinator.buildProgressSnapshot(tasks: tasks, now: now)

        #expect(snapshot.remainingCount == 1)
        #expect(snapshot.completedToday == 1)
        #expect(snapshot.nextDueText != nil)
    }
}
