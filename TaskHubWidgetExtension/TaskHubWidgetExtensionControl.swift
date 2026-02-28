import AppIntents
import SwiftUI
import WidgetKit

struct TaskHubWidgetExtensionControl: ControlWidget {
    static let kind: String = taskHubControlWidgetKind

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: TaskControlConfigurationIntent.self) { configuration in
            ControlWidgetButton(action: OpenTaskHubRouteIntent(action: configuration.action)) {
                Label(configuration.action.title, systemImage: configuration.action.systemImage)
            }
        }
        .displayName("TaskHub Shortcut")
        .description("Open Quick Add or jump directly to task lists.")
    }
}
