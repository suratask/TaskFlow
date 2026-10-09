import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

enum WidgetMaximumItems: String, AppEnum {
    case one, two, three, four, five, six, seven, eight, nine, ten
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Maximum Items")
    static var caseDisplayRepresentations: [WidgetMaximumItems: DisplayRepresentation] = [
        .one: DisplayRepresentation(title: "1"), .two: DisplayRepresentation(title: "2"),
        .three: DisplayRepresentation(title: "3"), .four: DisplayRepresentation(title: "4"),
        .five: DisplayRepresentation(title: "5"), .six: DisplayRepresentation(title: "6"),
        .seven: DisplayRepresentation(title: "7"), .eight: DisplayRepresentation(title: "8"),
        .nine: DisplayRepresentation(title: "9"), .ten: DisplayRepresentation(title: "10")
    ]
    var value: Int { switch self { case .one: 1; case .two: 2; case .three: 3; case .four: 4; case .five: 5; case .six: 6; case .seven: 7; case .eight: 8; case .nine: 9; case .ten: 10 } }
}

enum WidgetCalendarSet: String, AppEnum {
    case selected, all
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Calendar Set")
    static var caseDisplayRepresentations: [WidgetCalendarSet: DisplayRepresentation] = [
        .selected: DisplayRepresentation(title: "Selected Calendars"),
        .all: DisplayRepresentation(title: "All Calendars")
    ]
}

struct TaskFlowTodayWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Today Widget"
    static var description = IntentDescription("Choose reminder lists, calendars, and the number of items to show. Leave Lists empty for all lists.")
    @Parameter(title: "Lists") var lists: [WidgetReminderListEntity]?
    @Parameter(title: "Calendar Set", default: .selected) var calendarSet: WidgetCalendarSet
    @Parameter(title: "Show Events", default: true) var showEvents: Bool
    @Parameter(title: "Show Completed", default: false) var showCompleted: Bool
    @Parameter(title: "Maximum Items", default: .eight) var maximumItems: WidgetMaximumItems
    init() { lists = nil; calendarSet = .selected; showEvents = true; showCompleted = false; maximumItems = .eight }
}

struct TaskFlowNextUpWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Up Next Widget"
    static var description = IntentDescription("Choose reminder lists, calendars, and the number of items to show. Leave Lists empty for all lists.")
    @Parameter(title: "Lists") var lists: [WidgetReminderListEntity]?
    @Parameter(title: "Calendar Set", default: .selected) var calendarSet: WidgetCalendarSet
    @Parameter(title: "Show Events", default: true) var showEvents: Bool
    @Parameter(title: "Show Completed", default: false) var showCompleted: Bool
    @Parameter(title: "Maximum Items", default: .eight) var maximumItems: WidgetMaximumItems
    init() { lists = nil; calendarSet = .selected; showEvents = true; showCompleted = false; maximumItems = .eight }
}

struct TaskFlowTodayWidget: Widget {
    let kind = "TaskFlowTodayWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TaskFlowTodayWidgetConfigurationIntent.self, provider: TaskFlowTodayTimelineProvider()) { entry in
            TodayWidgetFamilyView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today’s date and a focused view of today’s tasks and events.")
        .supportedFamilies(mixedAgendaFamilies)
    }
}

struct TaskFlowTodayTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TaskFlowAgendaEntry {
        TaskFlowAgendaEntry(date: Date(), items: WidgetAgendaItem.sample, accessNeeded: false, theme: TaskFlowSharedSettings.theme)
    }
    func snapshot(for configuration: TaskFlowTodayWidgetConfigurationIntent, in context: Context) async -> TaskFlowAgendaEntry {
        if context.isPreview { return placeholder(in: context) }
        return await entry(configuration, family: context.family)
    }
    func timeline(for configuration: TaskFlowTodayWidgetConfigurationIntent, in context: Context) async -> Timeline<TaskFlowAgendaEntry> {
        let current = await entry(configuration, family: context.family)
        let dateOnly = context.family == .systemSmall || context.family == .accessoryInline || context.family == .accessoryCircular || context.family == .accessoryRectangular
        let refreshDate = dateOnly
            ? (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: current.date)) ?? current.date.addingTimeInterval(86400))
            : current.date.addingTimeInterval(900)
        return Timeline(entries: [current], policy: .after(refreshDate))
    }
    private func entry(_ configuration: TaskFlowTodayWidgetConfigurationIntent, family: WidgetFamily) async -> TaskFlowAgendaEntry {
        if family == .systemSmall || family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular {
            return TaskFlowAgendaEntry(date: Date(), items: [], accessNeeded: false, theme: TaskFlowSharedSettings.theme)
        }
        return await agendaEntry(hours: 24, taskLimit: 50, eventLimit: 50, todayOnly: true,
                          lists: configuration.lists, calendarSet: configuration.calendarSet,
                          showEvents: configuration.showEvents, showCompleted: configuration.showCompleted,
                          maximumItems: configuration.maximumItems)
    }
}

struct TaskFlowNextUpWidget: Widget {
    let kind = "TaskFlowNextUpWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TaskFlowNextUpWidgetConfigurationIntent.self, provider: TaskFlowNextUpTimelineProvider()) { entry in
            MixedAgendaWidgetView(entry: entry, title: "Up Next")
        }
        .configurationDisplayName("Up Next")
        .description("The next task or calendar event coming your way.")
        .supportedFamilies(mixedAgendaFamilies)
    }
}

struct TaskFlowNextUpTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TaskFlowAgendaEntry {
        TaskFlowAgendaEntry(date: Date(), items: WidgetAgendaItem.sample, accessNeeded: false, theme: TaskFlowSharedSettings.theme)
    }
    func snapshot(for configuration: TaskFlowNextUpWidgetConfigurationIntent, in context: Context) async -> TaskFlowAgendaEntry {
        if context.isPreview { return placeholder(in: context) }
        return await entry(configuration)
    }
    func timeline(for configuration: TaskFlowNextUpWidgetConfigurationIntent, in context: Context) async -> Timeline<TaskFlowAgendaEntry> {
        let current = await entry(configuration)
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 10, to: Date()) ?? Date().addingTimeInterval(600)
        return Timeline(entries: [current], policy: .after(refreshDate))
    }
    private func entry(_ configuration: TaskFlowNextUpWidgetConfigurationIntent) async -> TaskFlowAgendaEntry {
        await agendaEntry(hours: 24 * 14, taskLimit: 100, eventLimit: 100, todayOnly: false,
                          lists: configuration.lists, calendarSet: configuration.calendarSet,
                          showEvents: configuration.showEvents, showCompleted: configuration.showCompleted,
                          maximumItems: configuration.maximumItems)
    }
}

func agendaEntry(hours: Int, taskLimit: Int, eventLimit: Int, todayOnly: Bool,
                         lists: [WidgetReminderListEntity]?, calendarSet: WidgetCalendarSet,
                         showEvents: Bool, showCompleted: Bool, maximumItems: WidgetMaximumItems) async -> TaskFlowAgendaEntry {
    let selectedIDs = Set((lists ?? []).map(\.id))
    let result = await ReminderWidgetStore().loadAgendaItems(hours: hours, taskLimit: taskLimit, eventLimit: eventLimit,
                                                              todayOnly: todayOnly, includeCompleted: showCompleted,
                                                              includeEvents: showEvents, useAllCalendars: calendarSet == .all,
                                                              taskFilter: { task in
                                                                  return selectedIDs.isEmpty || selectedIDs.contains(task.listID)
                                                              })
    return TaskFlowAgendaEntry(date: Date(), items: result.items, accessNeeded: result.accessNeeded,
                               theme: TaskFlowSharedSettings.theme, itemLimit: maximumItems.value)
}

struct TaskFlowAgendaWidget: Widget {
    let kind = "TaskFlowAgendaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskFlowAgendaTimelineProvider()) { entry in
            AgendaWidgetView(entry: entry)
        }
        .configurationDisplayName("Agenda")
        .description("Upcoming calendar events and due tasks in one timeline.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct TaskFlowHighPriorityWidget: Widget {
    let kind = "TaskFlowHighPriorityWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskFlowHighPriorityTimelineProvider()) { entry in
            HighPriorityWidgetView(entry: entry)
        }
        .configurationDisplayName("High Priority")
        .description("Only the critical TaskFlow Studio tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TaskFlowDayFlowWidget: Widget {
    let kind = "TaskFlowDayFlowWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskFlowDayFlowTimelineProvider()) { entry in
            DayFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("Day Flow")
        .description("A compact timeline of today’s events, tasks, and useful gaps.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct WidgetReminderListEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder List")
    static var defaultQuery = WidgetReminderListQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", image: .init(systemName: "checklist")) }
}

struct WidgetReminderListQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetReminderListEntity] {
        lists.filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetReminderListEntity] { lists }
    private var lists: [WidgetReminderListEntity] {
        guard hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder)) else { return [] }
        return EKEventStore().calendars(for: .reminder).map {
            WidgetReminderListEntity(id: $0.calendarIdentifier, title: $0.title)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct TaskFlowAgendaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskFlowAgendaEntry {
        TaskFlowAgendaEntry(
            date: Date(),
            items: WidgetAgendaItem.sample,
            accessNeeded: false,
            theme: TaskFlowSharedSettings.theme
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskFlowAgendaEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskFlowAgendaEntry>) -> Void) {
        Task {
            let current = await entry()
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 10, to: Date()) ?? Date().addingTimeInterval(600)
            completion(Timeline(entries: [current], policy: .after(refreshDate)))
        }
    }

    private func entry() async -> TaskFlowAgendaEntry {
        let result = await ReminderWidgetStore().loadAgendaItems(hours: 12, taskLimit: 16, eventLimit: 24)
        return TaskFlowAgendaEntry(
            date: Date(),
            items: result.items,
            accessNeeded: result.accessNeeded,
            theme: TaskFlowSharedSettings.theme
        )
    }
}

struct TaskFlowHighPriorityTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskFlowWidgetEntry {
        TaskFlowWidgetEntry(
            date: Date(),
            tasks: WidgetTask.sampleHighPriority,
            accessNeeded: false,
            theme: TaskFlowSharedSettings.theme
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskFlowWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskFlowWidgetEntry>) -> Void) {
        Task {
            let current = await entry()
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [current], policy: .after(refreshDate)))
        }
    }

    private func entry() async -> TaskFlowWidgetEntry {
        let result = await ReminderWidgetStore().loadHighPriorityTasks(limit: 12)
        return TaskFlowWidgetEntry(
            date: Date(),
            tasks: result.tasks,
            accessNeeded: result.accessNeeded,
            theme: TaskFlowSharedSettings.theme
        )
    }
}

struct TaskFlowDayFlowTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskFlowAgendaEntry {
        TaskFlowAgendaEntry(
            date: Date(),
            items: WidgetAgendaItem.sample,
            accessNeeded: false,
            theme: TaskFlowSharedSettings.theme
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskFlowAgendaEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskFlowAgendaEntry>) -> Void) {
        Task {
            let current = await entry()
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 10, to: Date()) ?? Date().addingTimeInterval(600)
            completion(Timeline(entries: [current], policy: .after(refreshDate)))
        }
    }

    private func entry() async -> TaskFlowAgendaEntry {
        let result = await ReminderWidgetStore().loadAgendaItems(hours: 14, taskLimit: 20, eventLimit: 28)
        return TaskFlowAgendaEntry(
            date: Date(),
            items: result.items,
            accessNeeded: result.accessNeeded,
            theme: TaskFlowSharedSettings.theme
        )
    }
}

var mixedAgendaFamilies: [WidgetFamily] {
    var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular]
    if #available(iOS 27.0, macOS 27.0, *) { families.append(.systemExtraLargePortrait) }
    return families
}

struct TodayWidgetFamilyView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowAgendaEntry

    var body: some View {
        if family == .systemSmall {
            TodayDateWidgetView(date: entry.date, theme: entry.theme)
        } else if family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular {
            TodayAccessoryDateView(date: entry.date)
        } else {
            MixedAgendaWidgetView(entry: entry, title: "Today")
        }
    }
}

struct TodayDateWidgetView: View {
    let date: Date
    let theme: TaskFlowSharedTheme

    private var accent: Color { WidgetThemeStyle(theme: theme).accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 72, weight: .regular))
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.65)
                .lineLimit(1)

            Text(date.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "taskflow://"))
        .containerBackground(.background, for: .widget)
    }
}

struct TodayAccessoryDateView: View {
    @Environment(\.widgetFamily) private var family
    let date: Date
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9, weight: .bold))
                    Text(date.formatted(.dateTime.day())).font(.system(size: 22, weight: .bold, design: .rounded))
                }
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Text(date.formatted(.dateTime.weekday(.wide))).font(.caption.weight(.semibold))
                    Text(date.formatted(.dateTime.month(.abbreviated).day())).font(.title3.bold())
                }
            }
        }
        .widgetURL(TaskFlowDeepLink.calendarURL)
        .containerBackground(.background, for: .widget)
    }
}

struct NextUpAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowAgendaEntry
    var body: some View {
        if let first = entry.items.first {
            Link(destination: first.destinationURL) {
                switch family {
                case .accessoryInline:
                    Text("\(first.title) · \(first.timeText)")
                case .accessoryCircular:
                    VStack(spacing: 1) {
                        Image(systemName: first.isEvent ? "calendar" : "checkmark.circle")
                        Text(first.shortTimeText).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    }
                default:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(first.isEvent ? "NEXT EVENT" : "NEXT TASK").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text(first.title).font(.headline).lineLimit(1)
                        Text(first.timeText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Text("Nothing next").font(.caption)
        }
    }
}

struct MixedAgendaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowAgendaEntry
    let title: String

    private var limit: Int {
        let familyLimit: Int
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait { familyLimit = 8 }
        else {
            switch family {
            case .systemSmall: familyLimit = 1
            case .systemMedium: familyLimit = 2
            case .systemLarge: familyLimit = 4
            case .systemExtraLarge: familyLimit = 8
            default: familyLimit = 4
            }
        }
        return min(familyLimit, entry.itemLimit)
    }

    var body: some View {
        if family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular {
            NextUpAccessoryView(entry: entry)
                .containerBackground(.background, for: .widget)
        } else {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            HStack {
                Text(title).font(.headline).foregroundStyle(WidgetThemeStyle(theme: entry.theme).accent).lineLimit(1)
                Spacer(minLength: 0)
                if family != .systemSmall {
                    Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if entry.accessNeeded {
                Text("Allow Calendar and Reminders access in TaskFlow.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if entry.items.isEmpty {
                Text("No events or reminders").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(entry.items.prefix(limit)) { item in
                        AgendaTimelineRow(item: item, theme: entry.theme,
                                          compact: family == .systemSmall || family == .systemMedium)
                    }
                }
                if entry.items.count > limit && family != .systemSmall && family != .systemMedium {
                    Text("+\(entry.items.count - limit) more")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .widgetURL(TaskFlowDeepLink.calendarURL)
        .containerBackground(.background, for: .widget)
        }
    }
}

struct NextUpWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowAgendaEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next Up").font(.headline.weight(.semibold))
            if entry.accessNeeded {
                Text("Allow Calendar and Reminders access in TaskFlow.").font(.caption).foregroundStyle(.secondary)
            } else if let item = entry.items.first {
                AgendaTimelineRow(item: item, theme: entry.theme, compact: family == .systemSmall)
            } else {
                Text("Nothing coming up").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }
}

struct AgendaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowAgendaEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Agenda").font(.headline).foregroundStyle(.primary)
                Spacer()
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if entry.items.isEmpty {
                TodayEmptyView(theme: entry.theme)
            } else {
                let visibleItems = Array(entry.items.prefix(limit))
                VStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        if shouldShowGap(before: index, in: visibleItems) {
                            AgendaGapRow(
                                text: gapText(before: index, in: visibleItems),
                                theme: entry.theme,
                                compact: family == .systemMedium
                            )
                        }
                        AgendaTimelineRow(item: item, theme: entry.theme, compact: family == .systemMedium)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }

    private var limit: Int {
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait { return min(8, entry.itemLimit) }
        let familyLimit = switch family {
        case .systemMedium: 2
        case .systemExtraLarge: 4
        case .systemLarge: 3
        default: 3
        }
        return min(familyLimit, entry.itemLimit)
    }

    private func shouldShowGap(before index: Int, in items: [WidgetAgendaItem]) -> Bool {
        guard !family.isSystemMedium, items.count <= 3, index > 0 else { return false }
        return false
    }

    private func gapText(before index: Int, in items: [WidgetAgendaItem]) -> String {
        let minutes = gapMinutes(before: index, in: items)
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            if remainder == 0 {
                return "\(hours)h free"
            }
            return "\(hours)h \(remainder)m free"
        }
        return "\(minutes)m free"
    }

    private func gapMinutes(before index: Int, in items: [WidgetAgendaItem]) -> Int {
        guard index > 0 else { return 0 }
        let previousEnd = items[index - 1].endDate
        let nextStart = items[index].startDate
        return max(0, Int(nextStart.timeIntervalSince(previousEnd) / 60))
    }
}

struct AgendaTimelineRow: View {
    let item: WidgetAgendaItem
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if case .task(let task) = item {
                    Button(intent: CompleteReminderIntent(reminderID: task.id, title: task.title)) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(compact ? .body : .title3)
                            .foregroundStyle(item.accent(theme: theme))
                            .widgetAccentable()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(task.isCompleted ? "Completed \(task.title)" : "Complete \(task.title)")
            .disabled(task.isCompleted)
                } else {
                    Circle()
                        .fill(item.accent(theme: theme))
                        .widgetAccentable()
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 28, height: compact ? 32 : 36)

            Link(destination: item.destinationURL) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(compact ? item.timeText : "\(item.timeText) · \(sourceTitle)")
                        .font(.caption)
                        .foregroundStyle(isOverdueTask ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, compact ? 6 : 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WidgetColors.surfaceStroke).frame(height: 0.5).padding(.leading, compact ? 28 : 32)
        }
    }

    private var sourceTitle: String {
        switch item {
        case .task(let task): task.listTitle
        case .event(let event): event.calendarTitle
        }
    }

    private var rowTitle: String {
        if case .task(let task) = item { return task.displayTitle }
        return item.title
    }

    private var isOverdueTask: Bool {
        if case .task(let task) = item { return task.isOverdue }
        return false
    }
}

struct AgendaGapRow: View {
    let text: String
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        let style = WidgetThemeStyle(theme: theme)
        HStack(spacing: compact ? 8 : 10) {
            Spacer()
                .frame(width: compact ? 48 : 54)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(WidgetColors.subtle.opacity(0.5))
                .frame(width: 4, height: 16)
                .frame(width: 8)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(style.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

struct HighPriorityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowWidgetEntry

    var body: some View {
        content.containerBackground(.background, for: .widget)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            WidgetSectionHeader(
                title: "High Priority",
                subtitle: entry.tasks.isEmpty ? "Nothing critical" : "\(entry.tasks.count) critical",
                icon: "exclamationmark.triangle.fill",
                count: entry.tasks.count,
                theme: entry.theme,
                accent: WidgetColors.priorityRed,
                compact: family == .systemSmall
            )

            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if entry.tasks.isEmpty {
                HighPriorityEmptyView(theme: entry.theme)
            } else {
                VStack(spacing: 0) {
                    ForEach(entry.tasks.prefix(limit)) { task in
                        HighPriorityTaskRow(task: task, theme: entry.theme, compact: family == .systemSmall || family == .systemMedium)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var limit: Int {
        switch family {
        case .systemSmall: 2
        case .systemMedium: 2
        case .systemLarge: 4
        default: 4
        }
    }
}

struct HighPriorityCountWidgetView: View {
    let entry: TaskFlowWidgetEntry

    var body: some View {
        let count = entry.accessNeeded ? 0 : entry.tasks.count
        // Same layout as Reminders' smart-list tile: colored icon circle, large count, gray title.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(WidgetColors.priorityRed, in: Circle())
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("High Priority")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(entry.accessNeeded ? "Open app to allow access" : (count == 0 ? "Nothing critical" : "Need attention"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
    }
}

struct DayFlowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowAgendaEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 10) {
            WidgetSectionHeader(
                title: "Day Flow",
                subtitle: "Today timeline",
                icon: "timeline.selection",
                count: entry.items.count,
                theme: entry.theme,
                accent: WidgetThemeStyle(theme: entry.theme).accent,
                compact: family == .systemMedium
            )

            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if visibleItems.isEmpty {
                TodayEmptyView(theme: entry.theme)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        if let gap = gapText(before: index) {
                            AgendaGapRow(text: gap, theme: entry.theme, compact: family == .systemMedium)
                        }
                        DayFlowTimelineRow(item: item, theme: entry.theme, compact: family == .systemMedium)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }

    private var visibleItems: [WidgetAgendaItem] {
        Array(entry.items.prefix(limit))
    }

    private var limit: Int {
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait { return min(8, entry.itemLimit) }
        return switch family {
        case .systemMedium: 2
        case .systemExtraLarge: 4
        case .systemLarge: 3
        default: 4
        }
    }

    private func gapText(before index: Int) -> String? {
        guard false, index > 0 else { return nil }
        let minutes = max(0, Int(visibleItems[index].startDate.timeIntervalSince(visibleItems[index - 1].endDate) / 60))
        guard minutes >= 30 else { return nil }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h free" : "\(hours)h \(remainder)m free"
        }
        return "\(minutes)m free"
    }
}

struct WidgetSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let count: Int
    let theme: TaskFlowSharedTheme
    let accent: Color
    let compact: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct HighPriorityTaskRow: View {
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
            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text("\(task.dueSummary) · \(task.listTitle)").font(.caption).foregroundStyle(task.rowAccent(theme: theme)).lineLimit(1)
            }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, compact ? 6 : 10)
        .overlay(alignment: .bottom) { Rectangle().fill(WidgetColors.surfaceStroke).frame(height: 0.5).padding(.leading, 38) }
    }
}

struct DayFlowTimelineRow: View {
    let item: WidgetAgendaItem
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        AgendaTimelineRow(item: item, theme: theme, compact: compact)
    }
}

struct HighPriorityEmptyView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("No critical tasks.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyStateCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let theme: TaskFlowSharedTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskFlowWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetSectionHeader(title: "Today", subtitle: Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), icon: "", count: entry.tasks.count, theme: entry.theme, accent: .secondary, compact: family == .systemMedium)
            if entry.accessNeeded {
                Text("Allow Reminders access in TaskFlow.").font(.caption).foregroundStyle(.secondary)
            } else if entry.tasks.isEmpty {
                Text("Nothing due today").font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entry.tasks.prefix(limit))) { task in
                        TodayTaskRow(task: task, theme: entry.theme, compact: family != .systemLarge)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .containerBackground(.background, for: .widget)
    }

    private var limit: Int {
        switch family {
        case .systemMedium:
            return 2
        case .systemLarge: return 5
        case .systemExtraLarge: return 7
        default: return 2
        }
    }

    private var highlightedTask: WidgetTask? {
        guard !family.isSystemMedium else { return nil }
        return entry.tasks.firstHighPriorityTask
    }

    private var visibleTasks: [WidgetTask] {
        let tasks = entry.tasks.filter { task in
            guard let highlightedTask else { return true }
            return task.id != highlightedTask.id
        }
        return Array(tasks.prefix(limit))
    }

    private var hiddenTaskCount: Int {
        let highlightedOffset = highlightedTask == nil ? 0 : 1
        return max(0, entry.tasks.count - highlightedOffset - visibleTasks.count)
    }
}

struct TodayWidgetBackground: View {
    let theme: TaskFlowSharedTheme
    var body: some View { Color.clear }
}

struct TodaySmallWidgetView: View {
    let entry: TaskFlowWidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today").font(.headline.weight(.semibold))
            if entry.accessNeeded {
                Text("Allow Reminders access in TaskFlow.").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if entry.tasks.isEmpty {
                Text("Nothing due today").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.tasks.prefix(2))) { task in
                    TodayTaskRow(task: task, theme: entry.theme, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .widgetURL(TaskFlowDeepLink.calendarURL)
    }
}

struct TodaySmallWidgetBackground: View {
    var body: some View { Color.clear }
}

struct TodayWidgetHeader: View {
    let tasks: [WidgetTask]
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        let style = WidgetThemeStyle(theme: theme)
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                Text("Today")
                    .font(.system(size: compact ? 15 : 18, weight: .bold))
                    .foregroundStyle(style.title)
                Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(style.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(tasks.count) \(tasks.count == 1 ? "Task" : "Tasks") Due")
                    .font(.system(size: compact ? 11 : 13, weight: .bold))
                    .foregroundStyle(style.title)
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 4 : 6)
            .background(style.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style.accent.opacity(0.28), lineWidth: 1)
            }
        }
    }

    private var summary: String {
        let overdue = tasks.overdueCount
        let beforeNoon = tasks.beforeNoonCount
        let high = tasks.highPriorityCount

        var parts: [String] = []
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if beforeNoon > 0 { parts.append("\(beforeNoon) before noon") }
        if high > 0 { parts.append("\(high) high") }
        return parts.isEmpty ? "No urgent flags" : parts.joined(separator: " • ")
    }
}

struct TodayPriorityCallout: View {
    let task: WidgetTask
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        let style = WidgetThemeStyle(theme: theme)
        HStack(spacing: 7) {
            Text(task.isOverdue ? "Overdue" : "High")
                .font(.system(size: compact ? 10 : 11, weight: .bold))
                .foregroundStyle(WidgetColors.priorityRed)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(WidgetColors.priorityRed.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(task.title)
                .font(.system(size: compact ? 12 : 13, weight: .bold))
                .foregroundStyle(style.cardTitle)
                .lineLimit(1)

            Spacer(minLength: 0)

            if task.dueDate != nil {
                Text(task.dueSummary)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(style.cardSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 9 : 10)
        .padding(.vertical, compact ? 6 : 7)
        .background(style.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(WidgetColors.priorityRed.opacity(0.22), lineWidth: 1)
        }
    }
}

struct TodayMoreTasksFooter: View {
    let count: Int
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        let style = WidgetThemeStyle(theme: theme)
        Text("+ \(count) more due")
            .font(.system(size: compact ? 11 : 12, weight: .bold))
            .foregroundStyle(style.cardSecondary)
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 5)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(WidgetColors.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TodayTaskRow: View {
    let task: WidgetTask
    let theme: TaskFlowSharedTheme
    let compact: Bool
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: CompleteReminderIntent(reminderID: task.id, title: task.title)) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(task.listColor).widgetAccentable().frame(width: 30, height: 36)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text("\(task.listTitle) · \(task.dueSummary)").font(.caption).foregroundStyle(task.rowAccent(theme: theme)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, compact ? 2 : 4)
        .overlay(alignment: .bottom) { Rectangle().fill(WidgetColors.surfaceStroke).frame(height: 0.5).padding(.leading, 38) }
    }
}

struct TodayEmptyView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("Nothing due today.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodayAccessNeededView: View {
    let theme: TaskFlowSharedTheme

    var body: some View {
        let style = WidgetThemeStyle(theme: theme)
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(style.accent)
            Text("Reminders access needed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.cardTitle)
            Text("Open TaskFlow Studio and allow Reminders access.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(style.cardSecondary)
        }
        .padding(10)
        

    }
}
