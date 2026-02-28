import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

// TaskHubWidget.swift
// Core widget components shared by a Widget Extension.
// IMPORTANT:
// - Do NOT include an `@main` widget type in this file. Add a separate file with the
//   `@main` entry point inside your Widget Extension target only.
// - Ensure the Widget Extension target has the App Group entitlement matching
//   the constant below so it can read cached data.

// MARK: - Constants
let taskHubHomeWidgetKind = "com.ie.taskhub.widget.home"
let taskHubHomeWidgetLegacyKind = "com.ie.taskhub.widget"
let taskHubControlWidgetKind = "com.ie.taskhub.widget.control"

private let appGroupIdentifier = "group.com.ie.taskhub"
private let widgetSnapshotFileName = "widget_tasks.json"
private let widgetThemeFileName = "theme.json"
private let widgetDirectoryName = "widget"
private let widgetQuickAddDeepLinkURL = URL(string: "taskhubmobile://open/quickadd")!

func widgetTasksDeepLinkURL(scope: WidgetTaskScope) -> URL {
    URL(string: "taskhubmobile://open/tasks?scope=\(scope.rawValue)")!
}

enum WidgetTaskScope: String, CaseIterable, Codable, Hashable {
    case all
    case work
    case personal

    var displayName: String {
        switch self {
        case .all: return "All"
        case .work: return "Work"
        case .personal: return "Personal"
        }
    }
}

enum WidgetTaskDensity: String, CaseIterable, Codable, Hashable {
    case compact
    case balanced

    func rowLimit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall:
            return 1
        case .systemMedium:
            return self == .compact ? 5 : 3
        case .systemLarge:
            return self == .compact ? 9 : 6
        case .systemExtraLarge:
            return self == .compact ? 13 : 9
        case .accessoryRectangular:
            return self == .compact ? 3 : 2
        default:
            return self == .compact ? 5 : 3
        }
    }
}

// MARK: - Snapshot Models (mirrors app-side snapshot writer)
struct WidgetTaskSnapshotItem: Codable, Hashable {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case isCompleted = "is_completed"
        case dueAt = "due_at"
        case area
        case projectName = "project_name"
        case priority
        case updatedAt = "updated_at"
    }

    let id: String
    let title: String
    let isCompleted: Bool
    let dueAt: Date?
    let area: String?
    let projectName: String?
    let priority: Int?
    let updatedAt: Date?

    init(
        id: String = UUID().uuidString,
        title: String,
        isCompleted: Bool,
        dueAt: Date?,
        area: String? = nil,
        projectName: String? = nil,
        priority: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueAt = dueAt
        self.area = area
        self.projectName = projectName
        self.priority = priority
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decode(String.self, forKey: .title)
        self.isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        self.dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        self.area = try container.decodeIfPresent(String.self, forKey: .area)
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        self.priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct WidgetTasksSnapshot: Codable, Hashable {
    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case count
        case tasks
    }

    let version: Int?
    let generatedAt: Date?
    let count: Int
    let tasks: [WidgetTaskSnapshotItem]

    init(version: Int? = nil, generatedAt: Date? = nil, count: Int, tasks: [WidgetTaskSnapshotItem]) {
        self.version = version
        self.generatedAt = generatedAt
        self.count = count
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
        self.tasks = try container.decodeIfPresent([WidgetTaskSnapshotItem].self, forKey: .tasks) ?? []
        self.count = try container.decodeIfPresent(Int.self, forKey: .count) ?? self.tasks.count
    }
}

struct RGBA: Codable, Hashable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double
}

struct Theme: Codable, Hashable {
    enum CodingKeys: String, CodingKey {
        case enabled
        case work
        case personal
    }

    let enabled: Bool
    let work: RGBA
    let personal: RGBA

    init(enabled: Bool = false, work: RGBA, personal: RGBA) {
        self.enabled = enabled
        self.work = work
        self.personal = personal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.work = try container.decode(RGBA.self, forKey: .work)
        self.personal = try container.decode(RGBA.self, forKey: .personal)
    }
}

enum TaskHubLiveSyncState: String, Codable, Hashable {
    case syncing
    case upToDate
    case retrying
    case offline
}

#if canImport(ActivityKit)
@available(iOS 16.2, *)
struct TaskHubProgressAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var remainingCount: Int
        var completedToday: Int
        var nextDueText: String?
        var syncState: TaskHubLiveSyncState
    }

    let date: Date
    let scope: WidgetTaskScope
}
#endif

// MARK: - Snapshot codec utilities

enum WidgetSnapshotCodec {
    static func decode(_ data: Data) -> WidgetTasksSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetTasksSnapshot.self, from: data)
    }

    static func openTasks(from snapshot: WidgetTasksSnapshot) -> WidgetTasksSnapshot {
        let filtered = snapshot.tasks.filter { !$0.isCompleted }
        return WidgetTasksSnapshot(
            version: snapshot.version,
            generatedAt: snapshot.generatedAt,
            count: filtered.count,
            tasks: filtered
        )
    }

    static func tasks(for scope: WidgetTaskScope, in snapshot: WidgetTasksSnapshot) -> [WidgetTaskSnapshotItem] {
        switch scope {
        case .all:
            return snapshot.tasks
        case .work:
            return snapshot.tasks.filter { ($0.area ?? "").lowercased() == WidgetTaskScope.work.rawValue }
        case .personal:
            return snapshot.tasks.filter { ($0.area ?? "").lowercased() == WidgetTaskScope.personal.rawValue }
        }
    }
}

// MARK: - Entry

struct TaskHubWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetTasksSnapshot
    let theme: Theme
    let scope: WidgetTaskScope
    let density: WidgetTaskDensity
}

// MARK: - Loader

enum SnapshotLoader {
    static func loadSnapshot() -> WidgetTasksSnapshot {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return WidgetTasksSnapshot(count: 0, tasks: [])
        }

        let fileURL = containerURL
            .appendingPathComponent(widgetDirectoryName, isDirectory: true)
            .appendingPathComponent(widgetSnapshotFileName)

        guard let data = try? Data(contentsOf: fileURL), let decoded = WidgetSnapshotCodec.decode(data) else {
            return WidgetTasksSnapshot(count: 0, tasks: [])
        }

        return WidgetSnapshotCodec.openTasks(from: decoded)
    }

    static func placeholderSnapshot() -> WidgetTasksSnapshot {
        let sample = [
            WidgetTaskSnapshotItem(
                id: "sample-work-1",
                title: "Review mobile UX polish",
                isCompleted: false,
                dueAt: Calendar.current.date(byAdding: .day, value: 0, to: .now),
                area: WidgetTaskScope.work.rawValue,
                projectName: "Mobile",
                priority: 2,
                updatedAt: .now
            ),
            WidgetTaskSnapshotItem(
                id: "sample-personal-1",
                title: "Plan weekly errands",
                isCompleted: false,
                dueAt: Calendar.current.date(byAdding: .day, value: 1, to: .now),
                area: WidgetTaskScope.personal.rawValue,
                projectName: "Life",
                priority: 4,
                updatedAt: .now
            ),
            WidgetTaskSnapshotItem(
                id: "sample-work-2",
                title: "Draft project update",
                isCompleted: true,
                dueAt: nil,
                area: WidgetTaskScope.work.rawValue,
                projectName: "Ops",
                priority: 3,
                updatedAt: .now
            )
        ]

        let snapshot = WidgetTasksSnapshot(version: 2, generatedAt: .now, count: sample.count, tasks: sample)
        return WidgetSnapshotCodec.openTasks(from: snapshot)
    }

    static func loadTheme() -> Theme {
        let fallback = Theme(
            enabled: false,
            work: RGBA(r: 0.58, g: 0.77, b: 0.99, a: 1.0),
            personal: RGBA(r: 0.52, g: 0.94, b: 0.67, a: 1.0)
        )

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return fallback
        }

        let fileURL = containerURL.appendingPathComponent(widgetThemeFileName)
        guard let data = try? Data(contentsOf: fileURL), let theme = try? JSONDecoder().decode(Theme.self, from: data) else {
            return fallback
        }

        return theme
    }
}

// MARK: - Default provider (preview/fallback)

struct TaskHubProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskHubWidgetEntry {
        TaskHubWidgetEntry(
            date: Date(),
            snapshot: SnapshotLoader.placeholderSnapshot(),
            theme: SnapshotLoader.loadTheme(),
            scope: .all,
            density: .compact
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskHubWidgetEntry) -> Void) {
        completion(
            TaskHubWidgetEntry(
                date: Date(),
                snapshot: SnapshotLoader.loadSnapshot(),
                theme: SnapshotLoader.loadTheme(),
                scope: .all,
                density: .compact
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskHubWidgetEntry>) -> Void) {
        let now = Date()
        let entry = TaskHubWidgetEntry(
            date: now,
            snapshot: SnapshotLoader.loadSnapshot(),
            theme: SnapshotLoader.loadTheme(),
            scope: .all,
            density: .compact
        )
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - View

struct TaskHubWidgetEntryView: View {
    var entry: TaskHubWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum WDS {
        static let cornerSmall: CGFloat = 8
        static let cornerMedium: CGFloat = 14
        static let rowGapCompact: CGFloat = 2
        static let rowGapBalanced: CGFloat = 4
        static let rowPaddingVerticalCompact: CGFloat = 2
        static let rowPaddingVerticalBalanced: CGFloat = 5
        static let rowPaddingHorizontal: CGFloat = 6
        static let basePaddingCompact: CGFloat = 4
        static let basePaddingBalanced: CGFloat = 8
    }

    private var scopedTasks: [WidgetTaskSnapshotItem] {
        WidgetSnapshotCodec.tasks(for: entry.scope, in: entry.snapshot)
    }

    private var limitedTasks: [WidgetTaskSnapshotItem] {
        Array(scopedTasks.prefix(entry.density.rowLimit(for: family)))
    }

    private var hiddenCount: Int {
        max(0, scopedTasks.count - limitedTasks.count)
    }

    private var upcomingAccessoryTasks: [WidgetTaskSnapshotItem] {
        let sorted = scopedTasks.sorted { lhs, rhs in
            switch (lhs.dueAt, rhs.dueAt) {
            case let (leftDue?, rightDue?):
                if leftDue != rightDue {
                    return leftDue < rightDue
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            if let leftUpdated = lhs.updatedAt, let rightUpdated = rhs.updatedAt, leftUpdated != rightUpdated {
                return leftUpdated > rightUpdated
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return Array(sorted.prefix(entry.density.rowLimit(for: .accessoryRectangular)))
    }

    private var compactSpacing: CGFloat {
        entry.density == .compact ? WDS.rowGapCompact : WDS.rowGapBalanced
    }

    private var basePadding: CGFloat {
        entry.density == .compact ? WDS.basePaddingCompact : WDS.basePaddingBalanced
    }

    private var titleFont: Font {
        if dynamicTypeSize >= .xLarge {
            return .system(.footnote, design: .rounded).weight(.semibold)
        }
        return entry.density == .compact
            ? .system(.caption, design: .rounded).weight(.semibold)
            : .system(.footnote, design: .rounded).weight(.semibold)
    }

    private var headerFont: Font {
        .system(.caption, design: .rounded).weight(.bold)
    }

    private var metaFont: Font {
        entry.density == .compact
            ? .system(.caption2, design: .rounded).weight(.medium)
            : .system(.caption, design: .rounded).weight(.medium)
    }

    private var dueFont: Font {
        .system(.caption2, design: .rounded).weight(.semibold)
    }

    private var isCompactDensity: Bool {
        entry.density == .compact
    }

    private var headerTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.62)
    }

    private func color(_ rgba: RGBA) -> Color {
        Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    private func areaColor(for item: WidgetTaskSnapshotItem) -> Color {
        let fallbackWork = Color(red: 0.58, green: 0.77, blue: 0.99)
        let fallbackPersonal = Color(red: 0.52, green: 0.94, blue: 0.67)

        let work = entry.theme.enabled ? color(entry.theme.work) : fallbackWork
        let personal = entry.theme.enabled ? color(entry.theme.personal) : fallbackPersonal

        switch (item.area ?? "").lowercased() {
        case WidgetTaskScope.work.rawValue:
            return work
        case WidgetTaskScope.personal.rawValue:
            return personal
        default:
            return Color.accentColor
        }
    }

    private func dueText(for item: WidgetTaskSnapshotItem) -> String? {
        guard let due = item.dueAt else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(due) { return "Today" }
        if calendar.isDateInTomorrow(due) { return "Tomorrow" }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    private func accessoryDueText(for item: WidgetTaskSnapshotItem) -> String? {
        guard let due = item.dueAt else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(due) { return "Today" }
        if calendar.isDateInTomorrow(due) { return "Tomorrow" }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    private func dueTextColor(for item: WidgetTaskSnapshotItem) -> Color {
        guard let due = item.dueAt else { return secondaryTextColor }
        let isOverdue = due < Calendar.current.startOfDay(for: Date()) && !item.isCompleted
        if isOverdue { return .red }
        if Calendar.current.isDateInToday(due) { return .orange }
        return secondaryTextColor
    }

    private var showsFreshnessLabel: Bool {
        !isCompactDensity && (family == .systemLarge || family == .systemExtraLarge)
    }

    private func freshnessLabel(now: Date = Date()) -> String {
        guard let generatedAt = entry.snapshot.generatedAt else {
            return "No recent sync"
        }
        let delta = max(0, Int(now.timeIntervalSince(generatedAt)))
        if delta < 60 { return "Now" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        return "\(delta / 3600)h ago"
    }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessoryRectangularContent
            } else {
                VStack(alignment: .leading, spacing: compactSpacing) {
                    header

                    if limitedTasks.isEmpty {
                        emptyState
                    } else {
                        switch family {
                        case .systemSmall:
                            smallContent
                        default:
                            taskStack
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(family == .accessoryRectangular ? 6 : basePadding)
        .clipped()
        .widgetURL(widgetTasksDeepLinkURL(scope: entry.scope))
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(entry.scope.displayName)
                .font(headerFont)
                .foregroundStyle(headerTextColor)
                .lineLimit(1)

            if !limitedTasks.isEmpty {
                Text("\(scopedTasks.count)")
                    .font(metaFont)
                    .foregroundStyle(secondaryTextColor)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 6)
                    .background(secondaryTextColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 4)

            if showsFreshnessLabel {
                Text(freshnessLabel())
                    .font(metaFont)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    private var taskStack: some View {
        VStack(alignment: .leading, spacing: compactSpacing) {
            ForEach(limitedTasks, id: \.id) { item in
                rowCard(item: item, prominent: false)
            }
            if hiddenCount > 0 {
                if !isCompactDensity {
                    Text("+\(hiddenCount) more")
                        .font(metaFont)
                        .foregroundStyle(secondaryTextColor)
                        .padding(.top, 1)
                }
            }
        }
    }

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: compactSpacing) {
            if let first = limitedTasks.first {
                rowCard(item: first, prominent: true)
            }

            if hiddenCount > 0 && !isCompactDensity {
                Text("+\(hiddenCount) more tasks")
                    .font(metaFont)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: compactSpacing) {
            Label("All caught up", systemImage: "checkmark.circle.fill")
                .font(metaFont)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)

            if family != .systemSmall {
                Link(destination: widgetQuickAddDeepLinkURL) {
                    Label("Quick Add", systemImage: "plus.circle.fill")
                        .font(metaFont)
                        .foregroundStyle(Color.accentColor)
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var accessoryRectangularContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Upcoming")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(entry.scope.displayName)
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if upcomingAccessoryTasks.isEmpty {
                Text("All caught up")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ForEach(upcomingAccessoryTasks, id: \.id) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(areaColor(for: item))
                            .frame(width: 4, height: 4)
                            .accessibilityHidden(true)

                        Text(item.title)
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)

                        if let dueText = accessoryDueText(for: item) {
                            Text(dueText)
                                .font(.system(.caption2, design: .rounded).weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowCard(item: WidgetTaskSnapshotItem, prominent: Bool) -> some View {
        let tint = areaColor(for: item)
        let fillOpacity = (colorScheme == .dark ? 0.22 : 0.18) * 0.5
        let strokeOpacity = colorScheme == .dark ? 0.30 : 0.26
        let rowVertical = entry.density == .compact ? WDS.rowPaddingVerticalCompact : WDS.rowPaddingVerticalBalanced
        let cornerRadius = prominent ? WDS.cornerMedium : WDS.cornerSmall

        let dueText = dueText(for: item)

        return HStack(alignment: .center, spacing: 6) {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(entry.density == .compact ? .caption : .footnote)
                .foregroundStyle(item.isCompleted ? .green : secondaryTextColor)
                .accessibilityHidden(true)

            Text(item.title)
                .font(titleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .strikethrough(item.isCompleted, color: secondaryTextColor)

            Spacer(minLength: 0)

            if let dueText, !item.isCompleted, !isCompactDensity {
                Text(dueText)
                    .font(dueFont)
                    .foregroundStyle(dueTextColor(for: item))
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, rowVertical)
        .padding(.horizontal, WDS.rowPaddingHorizontal)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(fillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tint.opacity(strokeOpacity), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: item))
    }

    private func accessibilityLabel(for item: WidgetTaskSnapshotItem) -> String {
        var pieces: [String] = []
        pieces.append(item.title)
        pieces.append(item.isCompleted ? "Completed" : "Open")
        if let due = item.dueAt {
            pieces.append("Due \(due.formatted(date: .abbreviated, time: .omitted))")
        }
        if let area = item.area, !area.isEmpty {
            pieces.append(area.capitalized)
        }
        return pieces.joined(separator: ", ")
    }
}

#if DEBUG
// MARK: - Preview Widget Wrapper (for #Preview)

struct TaskHubPreviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskHubPreviewWidget", provider: TaskHubProvider()) { entry in
            TaskHubWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Task Hub (Preview)")
        .description("Preview-only widget configuration.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular])
    }
}

#Preview("Small", as: .systemSmall) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(
        date: .now,
        snapshot: SnapshotLoader.placeholderSnapshot(),
        theme: SnapshotLoader.loadTheme(),
        scope: .all,
        density: .compact
    )
}

#Preview("Medium Balanced", as: .systemMedium) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(
        date: .now,
        snapshot: SnapshotLoader.placeholderSnapshot(),
        theme: SnapshotLoader.loadTheme(),
        scope: .work,
        density: .balanced
    )
}

#Preview("Large Compact", as: .systemLarge) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(
        date: .now,
        snapshot: SnapshotLoader.placeholderSnapshot(),
        theme: SnapshotLoader.loadTheme(),
        scope: .personal,
        density: .compact
    )
}

#Preview("Lock Screen Rectangular", as: .accessoryRectangular) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(
        date: .now,
        snapshot: SnapshotLoader.placeholderSnapshot(),
        theme: SnapshotLoader.loadTheme(),
        scope: .all,
        density: .compact
    )
}
#endif
