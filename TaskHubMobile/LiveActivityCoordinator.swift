import Foundation
import SwiftData
#if canImport(ActivityKit)
import ActivityKit
#endif

struct TaskHubProgressSnapshot: Equatable {
    let day: Date
    let remainingCount: Int
    let completedToday: Int
    let nextDueText: String?
}

@MainActor
final class LiveActivityCoordinator {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func refresh(syncState: TaskHubLiveSyncState) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        Task {
            await self.refreshActivity(syncState: syncState)
        }
        #endif
    }

    static func buildProgressSnapshot(tasks: [TaskItem], now: Date = Date()) -> TaskHubProgressSnapshot {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)

        let remaining = tasks.filter { !$0.completed }
        let completedToday = tasks.filter {
            guard $0.completed else { return false }
            return calendar.isDate($0.updatedAt, inSameDayAs: now)
        }

        let nextDueDate = remaining
            .compactMap { $0.dueAt }
            .sorted()
            .first

        return TaskHubProgressSnapshot(
            day: dayStart,
            remainingCount: remaining.count,
            completedToday: completedToday.count,
            nextDueText: nextDueDate?.formatted(date: .abbreviated, time: .omitted)
        )
    }

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private func refreshActivity(syncState: TaskHubLiveSyncState) async {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let tasks: [TaskItem]
        do {
            tasks = try context.fetch(FetchDescriptor<TaskItem>())
        } catch {
            return
        }

        let snapshot = Self.buildProgressSnapshot(tasks: tasks)
        let activities = Activity<TaskHubProgressAttributes>.activities

        if let active = activities.first,
           !Calendar.current.isDate(active.attributes.date, inSameDayAs: snapshot.day) {
            await active.end(nil, dismissalPolicy: .immediate)
        }

        if snapshot.remainingCount == 0 && snapshot.completedToday == 0 {
            for activity in Activity<TaskHubProgressAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let state = TaskHubProgressAttributes.ContentState(
            remainingCount: snapshot.remainingCount,
            completedToday: snapshot.completedToday,
            nextDueText: snapshot.nextDueText,
            syncState: syncState
        )

        if let current = Activity<TaskHubProgressAttributes>.activities.first {
            let content = ActivityContent(state: state, staleDate: nil)
            await current.update(content)
            return
        }

        let attributes = TaskHubProgressAttributes(date: snapshot.day, scope: .all)
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            _ = try Activity<TaskHubProgressAttributes>.request(attributes: attributes, content: content)
        } catch {
            // Ignore unsupported or denied activity launches.
        }
    }
    #endif
}
