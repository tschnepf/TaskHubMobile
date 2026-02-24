// TaskHubWidgets.swift
// WidgetKit extension scaffold for TaskHub
// NOTE: Add a new Widget Extension target in Xcode and include this file there.

import WidgetKit
import SwiftUI

// MARK: - Snapshot Models (duplicated for the widget target)

struct WidgetTaskSnapshotItem: Codable, Hashable {
    enum CodingKeys: String, CodingKey { case title, isCompleted = "is_completed", dueAt = "due_at" }
    let title: String
    let isCompleted: Bool
    let dueAt: Date?
}

struct WidgetTasksSnapshot: Codable, Hashable {
    let count: Int
    let tasks: [WidgetTaskSnapshotItem]
}

// MARK: - Timeline Entry

struct TasksEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetTasksSnapshot?
}

// MARK: - Provider

struct TasksProvider: TimelineProvider {
    private let appGroupId = "group.com.yourorg.taskhub"
    private let fileName = "widget_tasks.json"

    func placeholder(in context: Context) -> TasksEntry {
        TasksEntry(date: Date(), snapshot: WidgetTasksSnapshot(count: 3, tasks: [
            WidgetTaskSnapshotItem(title: "Sample Task", isCompleted: false, dueAt: nil),
            WidgetTaskSnapshotItem(title: "Another Task", isCompleted: true, dueAt: nil),
            WidgetTaskSnapshotItem(title: "Third Task", isCompleted: false, dueAt: .now.addingTimeInterval(86400))
        ]))
    }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> ()) {
        completion(TasksEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> ()) {
        let entry = TasksEntry(date: Date(), snapshot: loadSnapshot())
        // Refresh periodically; the host app triggers reloads after sync
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadSnapshot() -> WidgetTasksSnapshot? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetTasksSnapshot.self, from: data)
    }
}

// MARK: - Widget View

struct TasksWidgetView: View {
    var entry: TasksProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tasks")
                .font(.headline)
            if let snapshot = entry.snapshot, !snapshot.tasks.isEmpty {
                ForEach(snapshot.tasks.prefix(3), id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                            .imageScale(.small)
                        Text(item.title)
                            .lineLimit(1)
                            .font(.caption)
                    }
                }
                Spacer(minLength: 0)
                Text("\(snapshot.count) total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No tasks")
                    .font(.caption)
                Spacer(minLength: 0)
            }
        }
        .padding()
        .widgetURL(URL(string: "taskhubmobile://open/tasks"))
    }
}

// MARK: - Widget

@main
struct TaskHubWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskHubWidgets", provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("TaskHub")
        .description("See your top tasks at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    TaskHubWidgets()
} timeline: {
    TasksEntry(date: .now, snapshot: WidgetTasksSnapshot(count: 2, tasks: [
        WidgetTaskSnapshotItem(title: "Preview Task 1", isCompleted: false, dueAt: nil),
        WidgetTaskSnapshotItem(title: "Preview Task 2", isCompleted: true, dueAt: nil)
    ]))
}
