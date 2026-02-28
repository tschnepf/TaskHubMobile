import WidgetKit
import SwiftUI

struct TaskHubIntentProvider: AppIntentTimelineProvider {
    typealias Intent = TaskWidgetConfigurationIntent
    typealias Entry = TaskHubWidgetEntry

    func placeholder(in context: Context) -> TaskHubWidgetEntry {
        TaskHubWidgetEntry(
            date: Date(),
            snapshot: SnapshotLoader.placeholderSnapshot(),
            theme: SnapshotLoader.loadTheme(),
            scope: .all,
            density: .compact
        )
    }

    func snapshot(for configuration: TaskWidgetConfigurationIntent, in context: Context) async -> TaskHubWidgetEntry {
        makeEntry(configuration: configuration, at: Date())
    }

    func timeline(for configuration: TaskWidgetConfigurationIntent, in context: Context) async -> Timeline<TaskHubWidgetEntry> {
        let now = Date()
        let entry = makeEntry(configuration: configuration, at: now)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func makeEntry(configuration: TaskWidgetConfigurationIntent, at date: Date) -> TaskHubWidgetEntry {
        TaskHubWidgetEntry(
            date: date,
            snapshot: SnapshotLoader.loadSnapshot(),
            theme: SnapshotLoader.loadTheme(),
            scope: configuration.scope.widgetScope,
            density: configuration.density.widgetDensity
        )
    }
}

struct TaskHubWidgetExtension: Widget {
    let kind: String = taskHubHomeWidgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TaskWidgetConfigurationIntent.self, provider: TaskHubIntentProvider()) { entry in
            TaskHubWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Task Hub")
        .description("Stay on top of your tasks with a compact modern view.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular])
    }
}

#if DEBUG
struct TaskHubWidgetLegacyDebugExtension: Widget {
    let kind: String = taskHubHomeWidgetLegacyKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TaskWidgetConfigurationIntent.self, provider: TaskHubIntentProvider()) { entry in
            TaskHubWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Task Hub")
        .description("Debug-only legacy widget kind for local Xcode launch compatibility.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular])
    }
}
#endif
