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
private let appGroupIdentifier = "group.com.ie.taskhub"
private let widgetSnapshotFileName = "widget_tasks.json"
private let widgetThemeFileName = "theme.json"
private let widgetDirectoryName = "widget"
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

struct RGBA: Codable, Hashable { let r: Double; let g: Double; let b: Double; let a: Double }
struct Theme: Codable, Hashable { let work: RGBA; let personal: RGBA }

// MARK: - Entry
struct TaskHubWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetTasksSnapshot
    let theme: Theme
}

// MARK: - Loader
enum SnapshotLoader {
    static func loadSnapshot() -> WidgetTasksSnapshot {
        // Attempt to read the cached snapshot from the shared App Group container
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return WidgetTasksSnapshot(count: 0, tasks: [])
        }
        let fileURL = containerURL
            .appendingPathComponent(widgetDirectoryName, isDirectory: true)
            .appendingPathComponent(widgetSnapshotFileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return WidgetTasksSnapshot(count: 0, tasks: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(WidgetTasksSnapshot.self, from: data) {
            let filtered = snapshot.tasks.filter { !$0.isCompleted }
            return WidgetTasksSnapshot(count: filtered.count, tasks: filtered)
        }
        return WidgetTasksSnapshot(count: 0, tasks: [])
    }

    static func placeholderSnapshot() -> WidgetTasksSnapshot {
        let sample = [
            WidgetTaskSnapshotItem(title: "Review PR #42", isCompleted: false, dueAt: Calendar.current.date(byAdding: .day, value: 0, to: .now)),
            WidgetTaskSnapshotItem(title: "Plan sprint backlog", isCompleted: false, dueAt: Calendar.current.date(byAdding: .day, value: 1, to: .now)),
            WidgetTaskSnapshotItem(title: "Email status update", isCompleted: true, dueAt: nil)
        ]
        let filtered = sample.filter { !$0.isCompleted }
        return WidgetTasksSnapshot(count: filtered.count, tasks: filtered)
    }

    static func loadTheme() -> Theme {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return Theme(work: RGBA(r: 0.12, g: 0.47, b: 0.95, a: 1.0), personal: RGBA(r: 0.18, g: 0.80, b: 0.44, a: 1.0))
        }
        let fileURL = containerURL.appendingPathComponent(widgetThemeFileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return Theme(work: RGBA(r: 0.12, g: 0.47, b: 0.95, a: 1.0), personal: RGBA(r: 0.18, g: 0.80, b: 0.44, a: 1.0))
        }
        if let theme = try? JSONDecoder().decode(Theme.self, from: data) {
            return theme
        }
        return Theme(work: RGBA(r: 0.12, g: 0.47, b: 0.95, a: 1.0), personal: RGBA(r: 0.18, g: 0.80, b: 0.44, a: 1.0))
    }
}

// MARK: - Provider
struct TaskHubProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskHubWidgetEntry {
        TaskHubWidgetEntry(date: Date(), snapshot: SnapshotLoader.placeholderSnapshot(), theme: SnapshotLoader.loadTheme())
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskHubWidgetEntry) -> Void) {
        let entry = TaskHubWidgetEntry(date: Date(), snapshot: SnapshotLoader.loadSnapshot(), theme: SnapshotLoader.loadTheme())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskHubWidgetEntry>) -> Void) {
        let snapshot = SnapshotLoader.loadSnapshot()
        let theme = SnapshotLoader.loadTheme()
        let now = Date()
        let entry = TaskHubWidgetEntry(date: now, snapshot: snapshot, theme: theme)
        // Refresh periodically; the main app also calls WidgetCenter.shared.reloadAllTimelines()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - View
struct TaskHubWidgetEntryView: View {
    var entry: TaskHubWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    // Blend two colors in sRGB to improve contrast on light backgrounds
    private func blend(_ c1: Color, with c2: Color, amount t: Double) -> Color {
        #if canImport(UIKit)
        func rgba(_ c: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let ui = UIColor(c)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if ui.getRed(&r, green: &g, blue: &b, alpha: &a) { return (r,g,b,a) }
            return (0,0,0,1)
        }
        let a = max(0, min(1, t))
        let c1r = rgba(c1); let c2r = rgba(c2)
        let r = (1 - a) * c1r.r + a * c2r.r
        let g = (1 - a) * c1r.g + a * c2r.g
        let b = (1 - a) * c1r.b + a * c2r.b
        return Color(uiColor: UIColor(red: r, green: g, blue: b, alpha: 1))
        #else
        return c1
        #endif
    }

    private func adaptedAreaColor(_ base: Color) -> Color {
        if colorScheme == .light {
            // Pull toward primary 40% to improve legibility on light backgrounds
            return blend(base, with: .primary, amount: 0.4)
        } else {
            return base
        }
    }

    private func adaptedSecondary() -> Color {
        // Slightly dark in light mode, slightly light in dark mode
        return colorScheme == .light ? Color.black.opacity(0.6) : Color.white.opacity(0.7)
    }

    private func color(_ rgba: RGBA) -> Color { Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a) }

    // MARK: - Contrast-based legibility adjustment for light mode
    private func relativeLuminance(_ ui: UIColor) -> CGFloat {
        func adjust(_ c: CGFloat) -> CGFloat { return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let R = adjust(r), G = adjust(g), B = adjust(b)
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }

    private func ensureContrastOnLight(_ base: Color, minRatio: CGFloat = 4.5) -> Color {
        #if canImport(UIKit)
        let ui = UIColor(base)
        // If we can get HSB, reduce brightness only (preserve hue/sat) until contrast vs white meets threshold
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            let lum = relativeLuminance(ui)
            let ratio = (1.0 + 0.05) / (lum + 0.05)
            if ratio >= minRatio { return base }
            var low: CGFloat = 0.0
            var high: CGFloat = b
            var best: CGFloat = b
            for _ in 0..<12 {
                let mid = (low + high) / 2
                let test = UIColor(hue: h, saturation: s, brightness: mid, alpha: a)
                let r = (1.0 + 0.05) / (relativeLuminance(test) + 0.05)
                if r >= minRatio {
                    best = mid
                    high = mid - 0.0001
                } else {
                    low = mid + 0.0001
                }
            }
            return Color(uiColor: UIColor(hue: h, saturation: s, brightness: best, alpha: a))
        } else {
            // Fallback: blend toward black
            return blend(base, with: .black, amount: 0.4)
        }
        #else
        return base
        #endif
    }

    private func adaptedAreaLegibleColor(_ base: Color) -> Color {
        return colorScheme == .light ? ensureContrastOnLight(base, minRatio: 4.5) : base
    }

    var body: some View {
        ZStack {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .systemLarge:
                largeView()
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
        .containerBackground(.background, for: .widget)
    }

    private func row(_ item: WidgetTaskSnapshotItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let isWork = item.title.localizedCaseInsensitiveContains("work")
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isCompleted ? Color.green : adaptedSecondary())
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .strikethrough(item.isCompleted, color: .secondary)
                    .foregroundStyle(adaptedAreaLegibleColor(isWork ? color(entry.theme.work) : color(entry.theme.personal)))
                if let due = item.dueAt {
                    Text(due, style: .date)
                        .font(.system(size: 10))
                        .foregroundStyle(adaptedSecondary())
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
                .foregroundStyle(colorScheme == .light ? Color.black : Color.white)
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

#if DEBUG
// MARK: - Preview Widget Wrapper (for #Preview)
struct TaskHubPreviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskHubPreviewWidget", provider: TaskHubProvider()) { entry in
            TaskHubWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Task Hub (Preview)")
        .description("Preview-only widget configuration.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

#Preview("Small", as: .systemSmall) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(date: .now, snapshot: SnapshotLoader.placeholderSnapshot(), theme: SnapshotLoader.loadTheme())
}

#Preview("Medium", as: .systemMedium) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(date: .now, snapshot: SnapshotLoader.placeholderSnapshot(), theme: SnapshotLoader.loadTheme())
}
#Preview("Large", as: .systemLarge) {
    TaskHubPreviewWidget()
} timeline: {
    TaskHubWidgetEntry(date: .now, snapshot: SnapshotLoader.placeholderSnapshot(), theme: SnapshotLoader.loadTheme())
}
#endif
