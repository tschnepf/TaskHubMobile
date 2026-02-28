import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.2, *)
struct TaskHubWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskHubProgressAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.86))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.scope.displayName)
                        .font(WidgetDS.Typography.meta)
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.remainingCount) left")
                        .font(WidgetDS.Typography.title)
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: WidgetDS.Spacing.xxs) {
                        Text("Completed today: \(context.state.completedToday)")
                            .font(WidgetDS.Typography.body)
                            .foregroundStyle(.white)

                        if let nextDue = context.state.nextDueText {
                            Text("Next due: \(nextDue)")
                                .font(WidgetDS.Typography.meta)
                                .foregroundStyle(.secondary)
                        }

                        syncStateLabel(context.state.syncState)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Text("\(min(99, context.state.remainingCount))")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
            } compactTrailing: {
                Image(systemName: stateSymbol(context.state.syncState))
                    .font(.system(size: 11, weight: .semibold))
            } minimal: {
                Text("\(min(99, context.state.remainingCount))")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
            }
            .widgetURL(widgetTasksDeepLinkURL(scope: context.attributes.scope))
            .keylineTint(.blue)
        }
    }

    private func lockScreenView(context: ActivityViewContext<TaskHubProgressAttributes>) -> some View {
        VStack(alignment: .leading, spacing: WidgetDS.Spacing.xs) {
            HStack(spacing: WidgetDS.Spacing.xs) {
                Text("Task Hub")
                    .font(WidgetDS.Typography.title)
                    .foregroundStyle(.white)

                Text(context.attributes.scope.displayName)
                    .font(WidgetDS.Typography.meta)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())

                Spacer(minLength: 0)

                syncStateLabel(context.state.syncState)
            }

            Text("\(context.state.remainingCount) tasks remaining")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: WidgetDS.Spacing.md) {
                Text("Done today \(context.state.completedToday)")
                    .font(WidgetDS.Typography.body)
                    .foregroundStyle(.secondary)

                if let nextDue = context.state.nextDueText {
                    Text("Next due \(nextDue)")
                        .font(WidgetDS.Typography.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(WidgetDS.Spacing.md)
        .widgetURL(widgetTasksDeepLinkURL(scope: context.attributes.scope))
    }

    private func syncStateLabel(_ state: TaskHubLiveSyncState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: stateSymbol(state))
                .font(.system(size: 10, weight: .semibold))
            Text(stateText(state))
                .font(WidgetDS.Typography.meta)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }

    private func stateText(_ state: TaskHubLiveSyncState) -> String {
        switch state {
        case .syncing: return "Syncing"
        case .upToDate: return "Updated"
        case .retrying: return "Retrying"
        case .offline: return "Offline"
        }
    }

    private func stateSymbol(_ state: TaskHubLiveSyncState) -> String {
        switch state {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle"
        case .retrying: return "clock.badge.exclamationmark"
        case .offline: return "wifi.slash"
        }
    }
}

@available(iOS 16.2, *)
extension TaskHubProgressAttributes {
    fileprivate static var preview: TaskHubProgressAttributes {
        TaskHubProgressAttributes(date: Calendar.current.startOfDay(for: .now), scope: .all)
    }
}

@available(iOS 16.2, *)
extension TaskHubProgressAttributes.ContentState {
    fileprivate static var compactPreview: TaskHubProgressAttributes.ContentState {
        TaskHubProgressAttributes.ContentState(
            remainingCount: 6,
            completedToday: 3,
            nextDueText: Date().formatted(date: .abbreviated, time: .omitted),
            syncState: .upToDate
        )
    }

    fileprivate static var syncingPreview: TaskHubProgressAttributes.ContentState {
        TaskHubProgressAttributes.ContentState(
            remainingCount: 4,
            completedToday: 5,
            nextDueText: nil,
            syncState: .syncing
        )
    }
}

@available(iOS 16.2, *)
#Preview("Notification", as: .content, using: TaskHubProgressAttributes.preview) {
    TaskHubWidgetExtensionLiveActivity()
} contentStates: {
    TaskHubProgressAttributes.ContentState.compactPreview
    TaskHubProgressAttributes.ContentState.syncingPreview
}
