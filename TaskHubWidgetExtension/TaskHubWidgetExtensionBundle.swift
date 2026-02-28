//
//  TaskHubWidgetExtensionBundle.swift
//  TaskHubWidgetExtension
//
//  Created by tim on 2/26/26.
//

import WidgetKit
import SwiftUI

@main
struct TaskHubWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        TaskHubWidgetExtension()
#if DEBUG
        TaskHubWidgetLegacyDebugExtension()
#endif
        TaskHubWidgetExtensionControl()
        TaskHubWidgetExtensionLiveActivity()
    }
}
