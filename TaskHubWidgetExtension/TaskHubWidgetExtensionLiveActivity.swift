//
//  TaskHubWidgetExtensionLiveActivity.swift
//  TaskHubWidgetExtension
//
//  Created by tim on 2/26/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct TaskHubWidgetExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct TaskHubWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskHubWidgetExtensionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension TaskHubWidgetExtensionAttributes {
    fileprivate static var preview: TaskHubWidgetExtensionAttributes {
        TaskHubWidgetExtensionAttributes(name: "World")
    }
}

extension TaskHubWidgetExtensionAttributes.ContentState {
    fileprivate static var smiley: TaskHubWidgetExtensionAttributes.ContentState {
        TaskHubWidgetExtensionAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: TaskHubWidgetExtensionAttributes.ContentState {
         TaskHubWidgetExtensionAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: TaskHubWidgetExtensionAttributes.preview) {
   TaskHubWidgetExtensionLiveActivity()
} contentStates: {
    TaskHubWidgetExtensionAttributes.ContentState.smiley
    TaskHubWidgetExtensionAttributes.ContentState.starEyes
}
