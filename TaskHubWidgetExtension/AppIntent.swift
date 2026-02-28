import AppIntents
import WidgetKit

enum WidgetScopeOption: String, AppEnum, CaseIterable {
    case all
    case work
    case personal

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Task Scope"
    }

    static var caseDisplayRepresentations: [WidgetScopeOption: DisplayRepresentation] {
        [
            .all: DisplayRepresentation(title: "All"),
            .work: DisplayRepresentation(title: "Work"),
            .personal: DisplayRepresentation(title: "Personal")
        ]
    }

    var widgetScope: WidgetTaskScope {
        switch self {
        case .all: return .all
        case .work: return .work
        case .personal: return .personal
        }
    }
}

enum WidgetDensityOption: String, AppEnum, CaseIterable {
    case compact
    case balanced

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Density"
    }

    static var caseDisplayRepresentations: [WidgetDensityOption: DisplayRepresentation] {
        [
            .compact: DisplayRepresentation(title: "Compact"),
            .balanced: DisplayRepresentation(title: "Balanced")
        ]
    }

    var widgetDensity: WidgetTaskDensity {
        switch self {
        case .compact: return .compact
        case .balanced: return .balanced
        }
    }
}

struct TaskWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Task Widget" }
    static var description: IntentDescription { "Choose the scope and density for your task widget." }

    @Parameter(title: "Scope", default: .all)
    var scope: WidgetScopeOption

    @Parameter(title: "Density", default: .compact)
    var density: WidgetDensityOption
}

enum TaskControlActionOption: String, AppEnum, CaseIterable {
    case quickAdd
    case openAllTasks
    case openWorkTasks
    case openPersonalTasks

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Shortcut Action"
    }

    static var caseDisplayRepresentations: [TaskControlActionOption: DisplayRepresentation] {
        [
            .quickAdd: DisplayRepresentation(title: "Quick Add"),
            .openAllTasks: DisplayRepresentation(title: "All Tasks"),
            .openWorkTasks: DisplayRepresentation(title: "Work Tasks"),
            .openPersonalTasks: DisplayRepresentation(title: "Personal Tasks")
        ]
    }

    var title: String {
        switch self {
        case .quickAdd: return "Quick Add"
        case .openAllTasks: return "Open Tasks"
        case .openWorkTasks: return "Open Work"
        case .openPersonalTasks: return "Open Personal"
        }
    }

    var systemImage: String {
        switch self {
        case .quickAdd: return "plus.circle.fill"
        case .openAllTasks: return "checklist"
        case .openWorkTasks: return "briefcase.fill"
        case .openPersonalTasks: return "person.fill"
        }
    }

    var targetURL: URL {
        switch self {
        case .quickAdd:
            return URL(string: "taskhubmobile://open/quickadd")!
        case .openAllTasks:
            return widgetTasksDeepLinkURL(scope: .all)
        case .openWorkTasks:
            return widgetTasksDeepLinkURL(scope: .work)
        case .openPersonalTasks:
            return widgetTasksDeepLinkURL(scope: .personal)
        }
    }
}

struct TaskControlConfigurationIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "TaskHub Shortcut"

    @Parameter(title: "Action", default: .quickAdd)
    var action: TaskControlActionOption
}

struct OpenTaskHubRouteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open TaskHub Route"
    static var openAppWhenRun = true

    @Parameter(title: "Action", default: .quickAdd)
    var action: TaskControlActionOption

    init() {}

    init(action: TaskControlActionOption) {
        self.action = action
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(action.targetURL))
    }
}
