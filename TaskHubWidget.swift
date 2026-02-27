import SwiftUI
import WidgetKit

// TaskHubWidget.swift
// Core widget components shared by a Widget Extension.
// IMPORTANT:
// - Do NOT include an `@main` widget type in this file. Add a separate file with the
//   `@main` entry point inside your Widget Extension target only.
// - Ensure the Widget Extension target has the App Group entitlement matching
//   the constant below (group.com.yourorg.taskhub) so it can read cached data.
// - The main app is already writing a snapshot for the widget via WidgetCache.

// MARK: - Constants
private let appGroupIdentifier = "group.com.yourorg.taskhub"
private let widgetSnapshotFileName = "widget_tasks.json"
private let widgetDeepLinkURL = URL(string: "taskhubmobile://open/tasks")!

// MARK: - Snapshot Models (mirrors app-side WidgetCache models)
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

// MARK: - Entry
struct TaskHubWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetTasksSnapshot
}

// MARK: - Loader
enum SnapshotLoader {
    static func loadSnapshot() -> WidgetTasksSnapshot {
        // Attempt to read the cached snapshot from the shared App Group container
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return WidgetTasksSnapshot(count: 0, tasks: [])
        }
        let fileURL = containerURL.appendingPathComponent(widgetSnapshotFileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return WidgetTasksSnapshot(count: 0, tasks: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(WidgetTasksSnapshot.self, from: data) {
            return snapshot
        }
        return WidgetTasksSnapshot(count: 0, tasks: [])
    }

    static func placeholderSnapshot() -> WidgetTasksSnapshot {
        let sample = [
            WidgetTaskSnapshotItem(title: "Review PR #42", isCompleted: false, dueAt: Calendar.current.date(byAdding: .day, value: 0, to: .now)),
            WidgetTaskSnapshotItem(title: "Plan sprint backlog", isCompleted: false, dueAt: Calendar.current.date(byAdding: .day, value: 1, to: .now)),
            WidgetTaskSnapshotItem(title: "Email status update", isCompleted: true, dueAt: nil)
        ]
        return WidgetTasksSnapshot(count: sample.count, tasks: sample)
    }
}

// MARK: - Provider
struct TaskHubProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskHubWidgetEntry {
        TaskHubWidgetEntry(date: Date(), snapshot: SnapshotLoader.placeholderSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskHubWidgetEntry) -> Void) {
        let entry = TaskHubWidgetEntry(date: Date(), snapshot: SnapshotLoader.loadSnapshot())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskHubWidgetEntry>) -> Void) {
        let snapshot = SnapshotLoader.loadSnapshot()
        let now = Date()
        let entry = TaskHubWidgetEntry(date: now, snapshot: snapshot)
        // Refresh periodically; the main app also calls WidgetCenter.shared.reloadAllTimelines()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - View
struct TaskHubWidgetEntryView: View {
    var entry: TaskHubWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .systemLarge:
                largeView
            case .systemExtraLarge:
                // Render similar to large but allow more rows
                largeView(maxRows: 8)
            default:
                // Fallback for any future families
                mediumView
            }
        }
        // Entire widget opens the app's task list
        .widgetURL(widgetDeepLinkURL)
    }

    private func row(_ item: WidgetTaskSnapshotItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isCompleted ? .green : .secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .strikethrough(item.isCompleted, color: .secondary)
                if let due = item.dueAt {
                    Text(due, style: .date)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack {
            Text("Task Hub")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            if entry.snapshot.count > 0 {
                Text("\(entry.snapshot.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            if let first = entry.snapshot.tasks.first {
                row(first)
            } else {
                ContentUnavailableView("No Tasks", systemImage: "checkmark.circle")
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            if entry.snapshot.tasks.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checkmark.circle")
            } else {
                ForEach(entry.snapshot.tasks.prefix(4), id: \.self) { item in
                    row(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private func largeView(maxRows: Int = 7) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            if entry.snapshot.tasks.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checkmark.circle")
            } else {
                ForEach(entry.snapshot.tasks.prefix(maxRows), id: \.self) { item in
                    row(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

// MARK: - Previews
#Preview("Small") {
    TaskHubWidgetEntryView(entry: TaskHubWidgetEntry(date: .now, snapshot: SnapshotLoader.placeholderSnapshot()))
        .previewContext(WidgetPreviewContext(family: .systemSmall))
}

#Preview("Medium") {
    TaskHubWidgetEntryView(entry: TaskHubWidgetEntry(date: .now, snapshot: SnapshotLoader.placeholderSnapshot()))
        .previewContext(WidgetPreviewContext(family: .systemMedium))
}

#Preview("Large") {
    TaskHubWidgetEntryView(entry: TaskHubWidgetEntry(date: .now, snapshot: SnapshotLoader.placeholderSnapshot()))
        .previewContext(WidgetPreviewContext(family: .systemLarge))
}
