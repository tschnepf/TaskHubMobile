import WidgetKit
import SwiftUI

struct TaskHubWidgetExtension: Widget {
    let kind: String = "com.ie.taskhub.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskHubProvider()) { entry in
            TaskHubWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Task Hub")
        .description("See your top tasks at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

