import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct TaskFlowSmartListWidget: Widget {
    let kind = "TaskFlowSmartListWidget"

    private var taskFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, macOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        return families
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SmartListWidgetConfigurationIntent.self, provider: TaskFlowSmartListTimelineProvider()) { entry in
            SmartListWidgetView(entry: entry)
        }
        .configurationDisplayName("Tasks")
        .description("Choose multiple reminder lists and complete tasks directly.")
        .supportedFamilies(taskFamilies)
    }
}

struct SmartListWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Tasks"
    static var description = IntentDescription("Choose reminder lists. Leave the selection empty to show all lists.")
    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$lists)") {
            \.$maximumItems
            \.$showCompleted
        }
    }
    @Parameter(title: "Lists") var lists: [WidgetReminderListEntity]?
    @Parameter(title: "Maximum Items", default: .eight) var maximumItems: WidgetMaximumItems
    @Parameter(title: "Show Completed", default: false) var showCompleted: Bool
    init() { lists = nil; maximumItems = .eight; showCompleted = false }
}

struct TaskFlowSmartListTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TaskFlowSmartListEntry {
        TaskFlowSmartListEntry(
            date: Date(),
            tasks: WidgetTask.sampleHighPriority,
            smartListTitle: "High Priority",
            smartListIcon: "exclamationmark.triangle.fill",
            accessNeeded: false,
            theme: TaskFlowSharedSettings.theme
        )
    }

    func snapshot(for configuration: SmartListWidgetConfigurationIntent, in context: Context) async -> TaskFlowSmartListEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await entry(for: configuration)
    }

    func timeline(for configuration: SmartListWidgetConfigurationIntent, in context: Context) async -> Timeline<TaskFlowSmartListEntry> {
        let current = await entry(for: configuration)
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [current], policy: .after(refreshDate))
    }

    private func entry(for configuration: SmartListWidgetConfigurationIntent) async -> TaskFlowSmartListEntry {
        let lists = configuration.lists ?? []
        let result = await ReminderWidgetStore().loadConfiguredTasks(listIDs: Set(lists.map(\.id)), includeCompleted: configuration.showCompleted, limit: 20)
        return TaskFlowSmartListEntry(
            date: Date(),
            tasks: result.tasks,
            smartListTitle: lists.count == 1 ? lists[0].title : (lists.isEmpty ? "All Tasks" : "Tasks · \(lists.count) Lists"),
            smartListIcon: "checklist",
            accessNeeded: result.accessNeeded,
            theme: TaskFlowSharedSettings.theme,
            itemLimit: configuration.maximumItems.value
        )
    }
}

struct SmartListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowSmartListEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 10) {
            HStack {
                Label(entry.smartListTitle, systemImage: entry.smartListIcon)
                    .font(.headline).foregroundStyle(WidgetThemeStyle(theme: entry.theme).accent).lineLimit(1)
                Spacer(minLength: 0)
            }

            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if entry.tasks.isEmpty {
                EmptySmartListView(theme: entry.theme)
            } else if isExtraLarge {
                if family == .systemExtraLarge {
                    HStack(alignment: .top, spacing: 24) {
                        groupedRows(Array(entry.tasks.prefix(limit).prefix(4)))
                        groupedRows(Array(entry.tasks.prefix(limit).dropFirst(4)))
                    }
                } else {
                    groupedRows(Array(entry.tasks.prefix(limit)))
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(entry.tasks.prefix(limit)) { task in
                        WidgetTaskRow(task: task, theme: entry.theme, compact: family == .systemMedium)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }

    private var isExtraLarge: Bool {
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait { return true }
        return family == .systemExtraLarge
    }

    private func dateSection(_ task: WidgetTask) -> String {
        guard let due = task.dueDate else { return "No Due Date" }
        let calendar = Calendar.current
        if calendar.startOfDay(for: due) < calendar.startOfDay(for: entry.date) { return "Overdue" }
        if calendar.isDate(due, inSameDayAs: entry.date) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: entry.date), calendar.isDate(due, inSameDayAs: tomorrow) { return "Tomorrow" }
        return due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func groupedRows(_ tasks: [WidgetTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                if index == 0 || dateSection(tasks[index - 1]) != dateSection(task) {
                    Text(dateSection(task)).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).padding(.top, index == 0 ? 2 : 8)
                }
                HStack(spacing: 10) {
                    Button(intent: CompleteReminderIntent(reminderID: task.id, title: task.title)) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(task.listColor).widgetAccentable()
                            .frame(width: 32, height: 36)
                    }
                    .buttonStyle(.plain).disabled(task.isCompleted)
                    .accessibilityLabel(task.isCompleted ? "Completed \(task.title)" : "Complete \(task.title)")
                    Link(destination: TaskFlowDeepLink.taskURL(task.id)) {
                        Text(task.displayTitle).font(.body).foregroundStyle(.primary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(task.title), \(task.listTitle), \(task.dueSummary)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var limit: Int {
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait { return min(8, entry.itemLimit) }
        let familyLimit = switch family {
        case .systemMedium: 2
        case .systemExtraLarge: 8
        case .systemLarge: 3
        default: 3
        }
        return min(familyLimit, entry.itemLimit)
    }
}

struct EmptySmartListView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("Nothing matches this smart list.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
