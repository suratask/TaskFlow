import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct TaskFlowTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskFlowWidgetEntry {
        TaskFlowWidgetEntry(
            date: Date(),
            tasks: WidgetTask.sample,
            accessNeeded: false,
            theme: TaskFlowSharedSettings.theme
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskFlowWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            completion(await entry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskFlowWidgetEntry>) -> Void) {
        Task {
            let current = await entry()
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [current], policy: .after(refreshDate)))
        }
    }

    private func entry() async -> TaskFlowWidgetEntry {
        let store = ReminderWidgetStore()
        let result = await store.loadIncompleteTasks(limit: 12)
        return TaskFlowWidgetEntry(
            date: Date(),
            tasks: result.tasks,
            accessNeeded: result.accessNeeded,
            theme: TaskFlowSharedSettings.theme
        )
    }
}

struct TaskFlowTasksWidget: Widget {
    let kind = "TaskFlowTasksWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskFlowTimelineProvider()) { entry in
            TaskFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("TaskFlow Studio")
        .description("Your upcoming tasks in a compact, grouped list.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct TaskFlowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: stackSpacing) {
            HeaderView(count: entry.tasks.count, theme: entry.theme, compact: usesCompactRows)

            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if entry.tasks.isEmpty {
                EmptyTasksView(theme: entry.theme)
            } else {
                VStack(spacing: 0) {
                    ForEach(entry.tasks.prefix(limit)) { task in
                        WidgetTaskRow(
                            task: task,
                            theme: entry.theme,
                            compact: usesCompactRows
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }

    private var limit: Int {
        switch family {
        case .systemMedium: 2
        case .systemLarge: 3
        case .systemExtraLarge: 4
        default: 3
        }
    }

    private var rowSpacing: CGFloat {
        switch family {
        case .systemMedium, .systemExtraLarge: 6
        default: 7
        }
    }

    private var stackSpacing: CGFloat {
        switch family {
        case .systemMedium, .systemExtraLarge: 6
        default: 8
        }
    }

    private var usesCompactRows: Bool {
        family == .systemMedium || family == .systemExtraLarge
    }

    private var widgetPadding: (horizontal: CGFloat, vertical: CGFloat) {
        switch family {
        case .systemMedium:
            (12, 10)
        case .systemExtraLarge:
            (14, 10)
        default:
            (16, 16)
        }
    }
}

struct WidgetRowGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 0) { content } }
}

struct WidgetBackground: View {
    let theme: TaskFlowSharedTheme
    var body: some View { Color.clear }
}

struct HeaderView: View {
    let count: Int
    let theme: TaskFlowSharedTheme
    let compact: Bool
    var body: some View {
        HStack {
            Text("Tasks").font(.headline.weight(.semibold)).foregroundStyle(.primary)
            Spacer()
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct WidgetTaskRow: View {
    let task: WidgetTask
    let theme: TaskFlowSharedTheme
    let compact: Bool
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: CompleteReminderIntent(reminderID: task.id, title: task.title)) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(task.listColor).widgetAccentable().frame(width: 30, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Completed \(task.title)" : "Complete \(task.title)")
            .disabled(task.isCompleted)
            Link(destination: TaskFlowDeepLink.taskURL(task.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text("\(task.listTitle) · \(task.dueSummary)").font(.caption).foregroundStyle(task.rowAccent(theme: theme)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, compact ? 6 : 8)
        .overlay(alignment: .bottom) { Rectangle().fill(WidgetColors.surfaceStroke).frame(height: 0.5).padding(.leading, 38) }
    }
}

struct WidgetTagChips: View {
    let tags: [String]
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        let style = WidgetThemeStyle(theme: theme)
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(compact ? 2 : 3), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(style.chipForeground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(style.chipBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if tags.count > (compact ? 2 : 3) {
                    Text("+\(tags.count - (compact ? 2 : 3))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(style.chipForeground.opacity(0.85))
                }
            }
            .lineLimit(1)
        }
    }
}

struct AccessNeededView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("Allow Reminders access in TaskFlow to show tasks here.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyTasksView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("All clear · No incomplete reminders are waiting.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
