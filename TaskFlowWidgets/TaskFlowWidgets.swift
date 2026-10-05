import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit

struct WidgetTask: Identifiable, Hashable {
    let id: String
    let externalID: String?
    let title: String
    let listID: String
    let listTitle: String
    let dueDate: Date?
    let priority: Int
    let isCompleted: Bool
    let status: String
    let isFlagged: Bool
    let parentID: String?
    let durationMinutes: Int?
    let tags: [String]
    let blockedByTaskIDs: [String]
    var listColor: Color = .blue
    var hasDueTime = true
    var specializedFields: [String: String] = [:]
    var specializedListType = "Standard"

    var priorityLabel: String? {
        switch priority {
        case 1...4: "High"
        case 5: "Medium"
        case 6...9: "Low"
        default: nil
        }
    }

    var priorityColor: Color {
        switch priority {
        case 1...4: .pink
        case 5: .orange
        case 6...9: .teal
        default: .indigo
        }
    }

    var dueSummary: String {
        guard let dueDate else {
            if specializedListType == "Reading & Watch Later" { return specializedFields["Progress"] ?? "Saved" }
            if let stage = specializedFields["Stage"], !stage.isEmpty { return stage }
            if specializedListType == "Shopping & Groceries", let store = specializedFields["Store"], !store.isEmpty { return store }
            return "No due date"
        }
        if isOverdue {
            return "Overdue \(dueDate.relativeOverdueText)"
        }
        if Calendar.current.isDateInToday(dueDate) {
            return hasDueTime ? dueDate.formatted(date: .omitted, time: .shortened) : "Today"
        }
        if Calendar.current.isDateInTomorrow(dueDate) {
            return "Tomorrow"
        }
        return dueDate.formatted(date: .abbreviated, time: .omitted)
    }
}

struct WidgetEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let calendarTitle: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    var calendarColor: Color = .blue

    var timeSummary: String {
        if isAllDay {
            return "All day"
        }
        if Calendar.current.isDateInToday(startDate) {
            return startDate.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInTomorrow(startDate) {
            return "Tomorrow"
        }
        return startDate.formatted(date: .abbreviated, time: .shortened)
    }
}

enum WidgetAgendaItem: Identifiable, Hashable {
    case task(WidgetTask)
    case event(WidgetEvent)

    var id: String {
        switch self {
        case .task(let task): "task-\(task.id)"
        case .event(let event): "event-\(event.id)-\(event.startDate.timeIntervalSince1970)"
        }
    }

    var startDate: Date {
        switch self {
        case .task(let task): task.dueDate ?? .distantFuture
        case .event(let event): event.startDate
        }
    }

    var title: String {
        switch self {
        case .task(let task): task.title
        case .event(let event): event.title
        }
    }
}

struct TaskFlowWidgetEntry: TimelineEntry {
    let date: Date
    let tasks: [WidgetTask]
    let accessNeeded: Bool
    let theme: TaskFlowSharedTheme
}

struct TaskFlowAgendaEntry: TimelineEntry {
    let date: Date
    let items: [WidgetAgendaItem]
    let accessNeeded: Bool
    let theme: TaskFlowSharedTheme
    var itemLimit: Int = 10
}

struct TaskFlowSmartListEntry: TimelineEntry {
    let date: Date
    let tasks: [WidgetTask]
    let smartListTitle: String
    let smartListIcon: String
    let accessNeeded: Bool
    let theme: TaskFlowSharedTheme
    var itemLimit: Int = 4
}

/// System semantic colors so widgets follow light, dark, and tinted Home Screen modes like Apple's own widgets.
private enum WidgetColors {
    static let backgroundTop = Color(uiColor: .systemBackground)
    static let backgroundBottom = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let elevatedSurface = Color(uiColor: .secondarySystemBackground)
    static let surfaceStroke = Color(uiColor: .separator)
    static let title = Color.primary
    static let muted = Color.secondary
    static let subtle = Color(uiColor: .tertiaryLabel)
    static let taskFlowBlue = Color.accentColor
    static let priorityRed = Color.red
    static let priorityGreen = Color.green
}

private struct WidgetThemeStyle {
    let theme: TaskFlowSharedTheme

    var accent: Color {
        switch theme {
        case .taskflow:
            return WidgetColors.taskFlowBlue
        default:
            return theme.primary
        }
    }

    var title: Color {
        WidgetColors.title
    }

    var secondaryText: Color {
        WidgetColors.muted
    }

    var cardBackground: Color {
        WidgetColors.elevatedSurface
    }

    var cardTitle: Color {
        WidgetColors.title
    }

    var cardSecondary: Color {
        WidgetColors.muted
    }

    var cardShadow: Color {
        .clear
    }

    var chipForeground: Color {
        WidgetColors.title.opacity(0.88)
    }

    var chipBackground: Color {
        WidgetColors.surface
    }

    var backgroundColors: [Color] {
        [
            WidgetColors.backgroundTop,
            WidgetColors.backgroundBottom
        ]
    }
}

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

enum WidgetMaximumItems: String, AppEnum {
    case two, three, four, six, eight
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Maximum Items")
    static var caseDisplayRepresentations: [WidgetMaximumItems: DisplayRepresentation] = [
        .two: DisplayRepresentation(title: "2"), .three: DisplayRepresentation(title: "3"),
        .four: DisplayRepresentation(title: "4"), .six: DisplayRepresentation(title: "6"),
        .eight: DisplayRepresentation(title: "8")
    ]
    var value: Int { switch self { case .two: 2; case .three: 3; case .four: 4; case .six: 6; case .eight: 8 } }
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

private func agendaEntry(hours: Int, taskLimit: Int, eventLimit: Int, todayOnly: Bool,
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

struct TaskFlowQuickCaptureWidgetEntry: TimelineEntry { let date: Date }
struct TaskFlowQuickCaptureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskFlowQuickCaptureWidgetEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (TaskFlowQuickCaptureWidgetEntry) -> Void) { completion(.init(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskFlowQuickCaptureWidgetEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: Date())], policy: .never))
    }
}
struct TaskFlowQuickCaptureWidget: Widget {
    let kind = "TaskFlowQuickCaptureWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskFlowQuickCaptureTimelineProvider()) { _ in
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "square.and.pencil").font(.title.weight(.medium)).foregroundStyle(WidgetThemeStyle(theme: TaskFlowSharedSettings.theme).accent)
                Text("Quick Capture").font(.headline.weight(.semibold)).foregroundStyle(.primary)
                Text("Task or event").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(TaskFlowDeepLink.captureURL)
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Quick Capture")
        .description("Open TaskFlow’s natural-language capture.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
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

private struct WidgetRowGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 0) { content } }
}

private struct WidgetBackground: View {
    let theme: TaskFlowSharedTheme
    var body: some View { Color.clear }
}

private var mixedAgendaFamilies: [WidgetFamily] {
    var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular]
    if #available(iOS 27.0, macOS 27.0, *) { families.append(.systemExtraLargePortrait) }
    return families
}

private struct TodayWidgetFamilyView: View {
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

private struct TodayDateWidgetView: View {
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

private struct TodayAccessoryDateView: View {
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

private struct NextUpAccessoryView: View {
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

private struct MixedAgendaWidgetView: View {
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

private struct NextUpWidgetView: View {
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

private struct AgendaWidgetView: View {
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

private struct AgendaTimelineRow: View {
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

private struct AgendaGapRow: View {
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

private struct HighPriorityWidgetView: View {
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

private struct HighPriorityCountWidgetView: View {
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

private struct DayFlowWidgetView: View {
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

private struct SmartListWidgetView: View {
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

private struct WidgetSectionHeader: View {
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

private struct HighPriorityTaskRow: View {
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

private struct DayFlowTimelineRow: View {
    let item: WidgetAgendaItem
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        AgendaTimelineRow(item: item, theme: theme, compact: compact)
    }
}

private struct HighPriorityEmptyView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("No critical tasks.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptySmartListView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("Nothing matches this smart list.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyStateCard: View {
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

private struct TodayWidgetView: View {
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

private struct TodayWidgetBackground: View {
    let theme: TaskFlowSharedTheme
    var body: some View { Color.clear }
}

private struct TodaySmallWidgetView: View {
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

private struct TodaySmallWidgetBackground: View {
    var body: some View { Color.clear }
}

private struct TodayWidgetHeader: View {
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

private struct TodayPriorityCallout: View {
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

private struct TodayMoreTasksFooter: View {
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

private struct TodayTaskRow: View {
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

private struct TodayEmptyView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("Nothing due today.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodayAccessNeededView: View {
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

private struct HeaderView: View {
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

private struct WidgetTaskRow: View {
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

private struct WidgetTagChips: View {
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

private struct AccessNeededView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("Allow Reminders access in TaskFlow to show tasks here.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyTasksView: View {
    let theme: TaskFlowSharedTheme
    var body: some View {
        Text("All clear · No incomplete reminders are waiting.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DueTodayActivityLockView: View {
    let state: TaskFlowDueTodayActivityAttributes.ContentState
    private var theme: TaskFlowSharedTheme { TaskFlowSharedSettings.theme }
    private var style: WidgetThemeStyle { WidgetThemeStyle(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TaskFlow Studio")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Today Summary")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(spacing: 0) {
                    Text("\(state.openCount)")
                        .font(.title2.weight(.black))
                    Text("open")
                        .font(.caption2.weight(.bold))
                }
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 44)
                    .background(style.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(style.accent.opacity(0.34), lineWidth: 1)
                    }
            }

            DueTodayActivitySummaryRow(state: state, theme: theme, compact: false)
        }
        .padding(16)
    }
}

private struct DueTodayActivitySummaryRow: View {
    let state: TaskFlowDueTodayActivityAttributes.ContentState
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            DueTodaySummaryMetric(
                title: "Open",
                value: "\(state.openCount)",
                icon: "checklist",
                color: theme.secondary,
                compact: compact
            )

            DueTodaySummaryMetric(
                title: "High",
                value: "\(state.highPriorityCount)",
                icon: "flag.fill",
                color: theme.tertiary,
                compact: compact
            )

            DueTodaySummaryMetric(
                title: "Next",
                value: state.nextDueSummary,
                icon: "clock.fill",
                color: .white.opacity(0.82),
                compact: compact
            )
        }
    }
}

private struct DueTodaySummaryMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Image(systemName: icon)
                .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                .foregroundStyle(color)
                .frame(width: compact ? 14 : 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(value)
                    .font((compact ? Font.caption : Font.subheadline).weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}


struct CompleteReminderIntent: AppIntent {
    static var isDiscoverable = false
    static var title: LocalizedStringResource = "Complete Reminder"
    static var description = IntentDescription("Mark a reminder complete.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder ID") var reminderID: String
    @Parameter(title: "Title") var title: String
    init() { reminderID = ""; title = "" }
    init(reminderID: String, title: String) { self.reminderID = reminderID; self.title = title }
    func perform() async throws -> some IntentResult {
        try ReminderWidgetStore().completeReminder(id: reminderID)
        TaskFlowSharedWidgetActions.recordCompletedReminder(id: reminderID)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

final class ReminderWidgetStore {
    private let store = EKEventStore()
    private lazy var metadata = TaskFlowSharedWidgetMetadata.load()
    private lazy var listTypes = TaskFlowSharedSettings.defaults.dictionary(forKey: "TaskFlow.specializedListTypes") as? [String: String] ?? [:]
    private func widgetTask(_ reminder: EKReminder) -> WidgetTask {
        WidgetTask(reminder: reminder, metadata: reminder.calendarItemExternalIdentifier.flatMap { metadata[$0] } ?? metadata[reminder.calendarItemIdentifier] ?? TaskFlowSharedTaskMetadata(), listType: listTypes[reminder.calendar.calendarIdentifier] ?? "Standard")
    }
    private var hasReminderAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return hasEventKitAccess(status)
    }

    func loadIncompleteTasks(limit: Int) async -> (tasks: [WidgetTask], accessNeeded: Bool) {
        guard hasReminderAccess else { return ([], true) }
        let reminders = await reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        return (Array(reminders.map(widgetTask).sorted(by: WidgetTask.sort).prefix(limit)), false)
    }

    func loadTodayTasks(limit: Int) async -> (tasks: [WidgetTask], accessNeeded: Bool) {
        guard hasReminderAccess else { return ([], true) }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let items = await reminders(matching: predicate).map(widgetTask).filter { $0.dueDate.map { $0 < end } ?? false }
        return (Array(items.sorted(by: WidgetTask.sort).prefix(limit)), false)
    }

    func loadAgendaItems(hours: Int, taskLimit: Int, eventLimit: Int, todayOnly: Bool = false,
                         includeCompleted: Bool = false, includeEvents: Bool = true,
                         useAllCalendars: Bool = false, taskFilter: (WidgetTask) -> Bool = { _ in true }) async -> (items: [WidgetAgendaItem], accessNeeded: Bool) {
        let now = Date()
        let start = todayOnly ? Calendar.current.startOfDay(for: now) : now
        let end = todayOnly
            ? (Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
            : now.addingTimeInterval(TimeInterval(hours * 3600))
        var items: [WidgetAgendaItem] = []
        var needsAccess = false
        if hasReminderAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
            let dueReminders = await reminders(matching: predicate).map(widgetTask).filter { $0.dueDate.map { $0 < end } ?? false }
            items += dueReminders.filter(taskFilter).sorted(by: WidgetTask.sort).prefix(taskLimit).map(WidgetAgendaItem.task)
            if includeCompleted {
                let todayStart = Calendar.current.startOfDay(for: now)
                let completedStart = todayOnly ? todayStart : (Calendar.current.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart)
                let completedEnd = Calendar.current.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86400)
                let completedPredicate = store.predicateForCompletedReminders(withCompletionDateStarting: completedStart, ending: completedEnd, calendars: nil)
                let completed = await reminders(matching: completedPredicate).map(widgetTask)
                items += completed.filter(taskFilter).sorted(by: WidgetTask.sort).prefix(taskLimit).map(WidgetAgendaItem.task)
            }
        } else { needsAccess = true }
        let status = EKEventStore.authorizationStatus(for: .event)
        let eventAuthorized = hasEventKitAccess(status)
        if includeEvents && eventAuthorized {
            let selectedIDs = Set(TaskFlowSharedSettings.defaults.stringArray(forKey: TaskFlowSharedSettings.selectedEventCalendarIDsKey) ?? [])
            let allCalendars = store.calendars(for: .event)
            let calendars = useAllCalendars || selectedIDs.isEmpty ? allCalendars : allCalendars.filter { selectedIDs.contains($0.calendarIdentifier) }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            items += store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(eventLimit).map { event in
                .event(WidgetEvent(id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "Untitled Event", calendarTitle: event.calendar.title, startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay, location: event.location, calendarColor: event.calendar.cgColor.map { Color(cgColor: $0) } ?? .blue))
            }
        }
        return (items.sorted { $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate }, (needsAccess || (includeEvents && !eventAuthorized)) && items.isEmpty)
    }

    func loadHighPriorityTasks(limit: Int) async -> (tasks: [WidgetTask], accessNeeded: Bool) {
        let result = await loadIncompleteTasks(limit: 100)
        return (Array(result.tasks.filter { (1...4).contains($0.priority) || $0.isOverdue }.prefix(limit)), result.accessNeeded)
    }

    func loadConfiguredTasks(listIDs: Set<String>, includeCompleted: Bool, limit: Int) async -> (tasks: [WidgetTask], accessNeeded: Bool) {
        guard hasReminderAccess else { return ([], true) }
        let calendars: [EKCalendar]? = listIDs.isEmpty ? nil : store.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        if let calendars, calendars.isEmpty { return ([], false) }
        let predicate = includeCompleted ? store.predicateForReminders(in: calendars) : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let tasks = await reminders(matching: predicate).map(widgetTask)
        return (Array(tasks.sorted(by: WidgetTask.sort).prefix(limit)), false)
    }

    func loadShoppingItems(listID: String, includeCompleted: Bool = false) async -> (tasks: [WidgetTask], accessNeeded: Bool) {
        guard hasReminderAccess else { return ([], true) }
        let calendars = store.calendars(for: .reminder).filter { $0.calendarIdentifier == listID }
        guard !calendars.isEmpty else { return ([], false) }
        let predicate = includeCompleted ? store.predicateForReminders(in: calendars) : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let tasks = await reminders(matching: predicate).map(widgetTask).filter { $0.parentID == nil }
        return (tasks.sorted {
            let first = $0.specializedFields["Category"] ?? ""
            let second = $1.specializedFields["Category"] ?? ""
            if first != second { return first.localizedStandardCompare(second) == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }, false)
    }

    func completeReminder(id: String) throws {
        guard hasReminderAccess, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NSError(domain: "TaskFlow.Widget", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open TaskFlow to check reminder access or refresh this task."])
        }
        if reminder.isCompleted { return }
        let shared = ShoppingReminderNotes.decode(reminder.notes ?? "")
        if var details = shared.details {
            let name = TaskFlowSharedSettings.shoppingShopperName.trimmingCharacters(in: .whitespacesAndNewlines)
            details.fields["Purchased By"] = name.isEmpty ? "Unnamed shopper" : String(name.prefix(80))
            details.fields["Purchased At"] = Date().ISO8601Format()
            reminder.notes = ShoppingReminderNotes.encode(shared.text, details: details)
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
    }

    private func reminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
    }
}

private extension Array where Element == WidgetTask {
    var firstHighPriorityTask: WidgetTask? { first { $0.isOverdue || (1...4).contains($0.priority) } }
    var overdueCount: Int { filter(\.isOverdue).count }
    var beforeNoonCount: Int {
        filter { task in guard let dueDate = task.dueDate else { return false }; return Calendar.current.isDateInToday(dueDate) && Calendar.current.component(.hour, from: dueDate) < 12 }.count
    }
    var highPriorityCount: Int { filter { (1...4).contains($0.priority) }.count }
}

private extension WidgetTask {
    init(reminder: EKReminder, metadata: TaskFlowSharedTaskMetadata, listType: String) {
        id = reminder.calendarItemIdentifier
        externalID = reminder.calendarItemExternalIdentifier
        title = reminder.title ?? "Untitled Task"
        listID = reminder.calendar.calendarIdentifier
        listTitle = reminder.calendar.title
        dueDate = reminder.dueDateComponents?.date
        priority = reminder.priority
        isCompleted = reminder.isCompleted
        status = metadata.status
        isFlagged = metadata.isFlagged
        parentID = metadata.parentID
        durationMinutes = metadata.durationMinutes
        tags = metadata.tags
        blockedByTaskIDs = metadata.blockedByTaskIDs
        let shopping = ShoppingReminderNotes.decode(reminder.notes ?? "").details
        specializedFields = shopping?.fields ?? metadata.specializedFields ?? [:]
        specializedListType = shopping == nil ? listType : "Shopping & Groceries"
        listColor = reminder.calendar.cgColor.map { Color(cgColor: $0) } ?? .blue
        hasDueTime = reminder.dueDateComponents?.hour != nil
    }

    // All-day reminders are due at midnight; they only become overdue once that day has passed.
    var isOverdue: Bool {
        guard let dueDate else { return false }
        if hasDueTime { return dueDate < Date() }
        let calendar = Calendar.current
        return calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: Date())
    }
    /// Matches the app's task rows: secondary text, red only when overdue.
    func rowAccent(theme: TaskFlowSharedTheme) -> Color {
        isOverdue ? WidgetColors.priorityRed : .secondary
    }

    /// High-priority reminders read "!!! Title", the same convention as Apple Reminders.
    var displayTitle: String {
        if specializedListType == "Shopping & Groceries", let quantity = specializedFields["Quantity"], !quantity.isEmpty {
            return quantity + " × " + title
        }
        return (1...4).contains(priority) ? "!!! \(title)" : title
    }

    static func sort(_ lhs: WidgetTask, _ rhs: WidgetTask) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?): return left == right ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
    static let sample: [WidgetTask] = sampleToday + sampleHighPriority
    static let sampleToday: [WidgetTask] = [sampleTask("Review proposal", due: Date().addingTimeInterval(3600)), sampleTask("Send update", due: Date().addingTimeInterval(10800))]
    static let sampleHighPriority: [WidgetTask] = [sampleTask("Resolve launch issue", due: Date().addingTimeInterval(1800), priority: 1), sampleTask("Review contract", due: Date().addingTimeInterval(7200), priority: 2)]
    private static func sampleTask(_ title: String, due: Date, priority: Int = 0) -> WidgetTask {
        WidgetTask(id: UUID().uuidString, externalID: nil, title: title, listID: "work", listTitle: "Work", dueDate: due, priority: priority, isCompleted: false, status: "Not Started", isFlagged: false, parentID: nil, durationMinutes: nil, tags: [], blockedByTaskIDs: [], listColor: .blue)
    }
}

private extension WidgetAgendaItem {
    static var sample: [WidgetAgendaItem] {
        [.task(WidgetTask.sampleToday[0]), .event(WidgetEvent(id: "sample-event", title: "Team meeting", calendarTitle: "Work", startDate: Date().addingTimeInterval(5400), endDate: Date().addingTimeInterval(7200), isAllDay: false, location: nil))]
    }
    var endDate: Date {
        switch self { case .task(let task): task.dueDate ?? .distantFuture; case .event(let event): event.endDate }
    }
    var destinationURL: URL {
        switch self {
        case .task(let task): TaskFlowDeepLink.taskURL(task.id)
        case .event(let event): TaskFlowDeepLink.eventURL(event.id)
        }
    }
    var timeText: String {
        switch self { case .task(let task): task.dueSummary; case .event(let event): event.timeSummary }
    }
    var shortTimeText: String {
        switch self {
        case .task(let task): task.dueDate?.formatted(date: .omitted, time: .shortened) ?? "Today"
        case .event(let event): event.startDate.formatted(date: .omitted, time: .shortened)
        }
    }
    var isEvent: Bool { if case .event = self { true } else { false } }
    func accent(theme: TaskFlowSharedTheme) -> Color {
        switch self { case .task(let task): task.listColor; case .event(let event): event.calendarColor }
    }
}

private extension Date {
    var relativeOverdueText: String {
        let minutes = max(1, Int(Date().timeIntervalSince(self) / 60))
        return minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    }
}

private extension WidgetFamily {
    var isSystemMedium: Bool { self == .systemMedium }
}

private extension TaskFlowSharedSmartListDefinition {
    func matches(_ task: WidgetTask) -> Bool {
        if !includeCompleted && task.isCompleted { return false }
        if let listID, task.listID != listID { return false }
        if flaggedOnly && !task.isFlagged { return false }
        if let requiredTag, !task.tags.contains(where: { $0.caseInsensitiveCompare(requiredTag) == .orderedSame }) { return false }
        if let priority {
            let value = task.priorityLabel ?? ""
            if value.caseInsensitiveCompare(priority) != .orderedSame { return false }
        }
        if let status, task.status.caseInsensitiveCompare(status) != .orderedSame { return false }
        if blockedOnly && task.blockedByTaskIDs.isEmpty { return false }
        guard let rules, !rules.isEmpty else { return true }
        let results = rules.map { rule -> Bool in
            switch rule.field {
            case "Status": return task.status.caseInsensitiveCompare(rule.value) == .orderedSame
            case "Priority": return (task.priorityLabel ?? "None").caseInsensitiveCompare(rule.value) == .orderedSame
            case "Tag": return task.tags.contains { $0.caseInsensitiveCompare(rule.value) == .orderedSame }
            case "List": return task.listID == rule.value
            case "Due date":
                guard let dueDate = task.dueDate else { return rule.value == "No date" }
                switch rule.value {
                case "Overdue": return dueDate < Date() && !Calendar.current.isDateInToday(dueDate)
                case "Today": return Calendar.current.isDateInToday(dueDate)
                case "Tomorrow": return Calendar.current.isDateInTomorrow(dueDate)
                case "Next 7 days": return task.isDueWithinNextDays(7)
                case "Next 14 days": return task.isDueWithinNextDays(14)
                case "Next 30 days": return task.isDueWithinNextDays(30)
                case "No date": return false
                default: return true
                }
            default: return true
            }
        }
        return matchMode == "Any rule (OR)" ? results.contains(true) : results.allSatisfy { $0 }
    }
}

private extension WidgetTask {
    func isDueWithinNextDays(_ days: Int) -> Bool {
        guard let dueDate else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let limit = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return dueDate >= today && dueDate < limit
    }
}

struct TaskFlowEventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskFlowEventActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "calendar").font(.title2.weight(.semibold)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    Text(context.attributes.calendarTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let location = context.attributes.location, !location.isEmpty {
                        Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    eventCountdown(context.attributes)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(TaskFlowDeepLink.eventURL(context.attributes.eventID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "calendar").foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startDate, style: .relative).font(.caption.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        HStack {
                            Text(context.attributes.calendarTitle).font(.caption).foregroundStyle(.secondary)
                            if let location = context.attributes.location, !location.isEmpty {
                                Text("·").foregroundStyle(.secondary)
                                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text("Ends \(context.attributes.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "calendar")
            } compactTrailing: {
                Text(context.attributes.startDate, style: .relative).monospacedDigit()
            } minimal: {
                Image(systemName: "calendar")
            }
            .widgetURL(TaskFlowDeepLink.eventURL(context.attributes.eventID))
        }
    }

    @ViewBuilder
    private func eventCountdown(_ attributes: TaskFlowEventActivityAttributes) -> some View {
        if Date.now < attributes.startDate {
            Text("Starts \(attributes.startDate, style: .relative)").font(.subheadline.weight(.semibold)).monospacedDigit()
        } else if Date.now < attributes.endDate {
            Text(timerInterval: attributes.startDate...attributes.endDate, countsDown: false).font(.subheadline.weight(.semibold)).monospacedDigit()
        } else {
            Text("Event ended").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

struct TaskFlowRoutineTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskFlowRoutineTimerActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "timer").font(.title2.weight(.semibold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.stepTitle.isEmpty ? context.attributes.listTitle : context.attributes.stepTitle).font(.headline).lineLimit(1)
                    Text(context.attributes.listTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                routineCountdown(context.attributes, end: context.state.endDate).font(.title2.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(TaskFlowDeepLink.listURL(context.attributes.listID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    routineCountdown(context.attributes, end: context.state.endDate).font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.stepTitle.isEmpty ? context.attributes.listTitle : context.attributes.stepTitle).font(.headline).lineLimit(1)
                        Text(context.attributes.listTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.orange)
            } compactTrailing: {
                routineCountdown(context.attributes, end: context.state.endDate).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
            .widgetURL(TaskFlowDeepLink.listURL(context.attributes.listID))
        }
    }

    @ViewBuilder
    private func routineCountdown(_ attributes: TaskFlowRoutineTimerActivityAttributes, end: Date) -> some View {
        if Date.now < end, attributes.startDate < end {
            Text(timerInterval: attributes.startDate...end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
        } else {
            Text("Done").foregroundStyle(.secondary)
        }
    }
}

struct TaskFlowDueTodayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskFlowDueTodayActivityAttributes.self) { context in
            // Uses the system Live Activity background so it adapts to light and dark Lock Screens.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Today", systemImage: "checklist")
                        .font(.headline)
                    Spacer()
                    Text("\(context.state.openCount) open")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(context.state.tasks.prefix(3)) { task in
                    DueTodayActivityTaskRow(task: task)
                }
                if context.isStale {
                    Text("Open TaskFlow to refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .widgetURL(TaskFlowDeepLink.calendarURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Today", systemImage: "checklist")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.openCount) open")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(context.state.tasks.prefix(3)) { task in
                            DueTodayActivityTaskRow(task: task)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "checklist")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text("\(context.state.openCount)")
                    .monospacedDigit()
            } minimal: {
                Text("\(context.state.openCount)")
                    .monospacedDigit()
            }
            .widgetURL(TaskFlowDeepLink.calendarURL)
        }
    }
}

/// One task line in the Due Today Live Activity, styled like the app's task rows.
private struct DueTodayActivityTaskRow: View {
    let task: TaskFlowDueTodayTaskSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.isCompleted ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
            Text((1...4).contains(task.priority) ? "!!! \(task.title)" : task.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if task.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let dueDate = task.dueDate {
                Text(dueDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(dueDate < Date() ? Color.red : Color.secondary)
            }
        }
    }
}

private func hasEventKitAccess(_ status: EKAuthorizationStatus) -> Bool {
    if #available(iOS 17.0, *) {
        return status == .fullAccess
    }
    // Before iOS 17, the authorized status has the same raw value as fullAccess.
    return status.rawValue == 3
}

/// Control Center, Lock Screen, and Action button control that opens Quick Capture.
@available(iOS 18.0, *)
struct QuickCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.surratt.TaskFlow.quickCaptureControl") {
            ControlWidgetButton(action: OpenQuickCaptureControlIntent()) {
                Label("Quick Capture", systemImage: "plus.circle")
            }
        }
        .displayName("Quick Capture")
        .description("Add a task in TaskFlow Studio.")
    }
}

@available(iOS 18.0, *)
struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.surratt.TaskFlow.newNoteControl") {
            ControlWidgetButton(action: NewNoteControlIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Write a new note in TaskFlow Studio.")
    }
}

@available(iOS 18.0, *)
struct DictateNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.surratt.TaskFlow.dictateNoteControl") {
            ControlWidgetButton(action: DictateNoteControlIntent()) {
                Label("Dictate Note", systemImage: "mic.fill")
            }
        }
        .displayName("Dictate Note")
        .description("Speak a new note and review its transcription.")
    }
}

@main
struct TaskFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskFlowTodayWidget()
        TaskFlowNextUpWidget()
        TaskFlowQuickCaptureWidget()
        TaskFlowSmartListWidget()
        TaskFlowShoppingListWidget()
        TaskFlowPinnedNoteWidget()
        TaskFlowDueTodayLiveActivity()
        TaskFlowEventLiveActivity()
        TaskFlowRoutineTimerLiveActivity()
        if #available(iOS 18.0, *) {
            QuickCaptureControl()
            NewNoteControl()
            DictateNoteControl()
        }
    }
}


struct ShoppingWidgetListEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Shopping List")
    static var defaultQuery = ShoppingWidgetListQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "cart"))
    }
}

struct ShoppingWidgetListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShoppingWidgetListEntity] {
        let available = availableLists()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [ShoppingWidgetListEntity] { availableLists() }
    func entities(matching string: String) async throws -> [ShoppingWidgetListEntity] {
        availableLists().filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
    }
    func availableLists() -> [ShoppingWidgetListEntity] {
        guard hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder)) else { return [] }
        let types = TaskFlowSharedSettings.defaults.dictionary(forKey: "TaskFlow.specializedListTypes") as? [String: String] ?? [:]
        return EKEventStore().calendars(for: .reminder)
            .filter { $0.allowsContentModifications && types[$0.calendarIdentifier] == "Shopping & Groceries" }
            .map { ShoppingWidgetListEntity(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct ShoppingWidgetStoreOptions: DynamicOptionsProvider {
    static let allStores = "All Stores"
    @IntentParameterDependency<ShoppingListWidgetConfigurationIntent>(\.$list)
    var configuration

    func results() async throws -> [String] {
        let available = ShoppingWidgetListQuery().availableLists()
        let selected = (configuration?.list).flatMap { chosen in available.first { $0.id == chosen.id } }
            ?? (configuration?.list == nil ? available.first : nil)
        guard let selected else { return [Self.allStores] }
        let result = await ReminderWidgetStore().loadShoppingItems(listID: selected.id, includeCompleted: true)
        var names: [String: String] = [:]
        for task in result.tasks {
            let name = (task.specializedFields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            names[name.lowercased()] = names[name.lowercased()] ?? name
        }
        return [Self.allStores] + names.values.filter { $0 != Self.allStores }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct ShoppingListWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Shopping List"
    static var description = IntentDescription("Choose a Shopping & Groceries list created in TaskFlow. Leave blank to use the first shopping list.")
    @Parameter(title: "Shopping List") var list: ShoppingWidgetListEntity?
    @Parameter(title: "Store", description: "Choose a store from the selected shopping list, or show every store.", optionsProvider: ShoppingWidgetStoreOptions()) var store: String?
    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$list)") { \.$store } }
}

struct ShoppingListWidgetEntry: TimelineEntry {
    let date: Date
    var listID: String?
    var title: String
    var tasks: [WidgetTask]
    var store: String
    var accessNeeded: Bool
    var listUnavailable: Bool
    var theme: TaskFlowSharedTheme
}

struct ShoppingListWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShoppingListWidgetEntry {
        let samples = [("Apples", "4", "", "Produce"), ("Oat milk", "2", "cartons", "Dairy"), ("Sourdough bread", "1", "loaf", "Bakery"), ("Eggs", "1", "dozen", "Dairy"), ("Spinach", "1", "bag", "Produce"), ("Pasta", "2", "packs", "Pantry")]
        let tasks = samples.enumerated().map { index, item in
            WidgetTask(id: "shopping-preview-\(index)", externalID: nil, title: item.0, listID: "shopping-preview", listTitle: "Groceries", dueDate: nil, priority: 0, isCompleted: false, status: "Not Started", isFlagged: false, parentID: nil, durationMinutes: nil, tags: [], blockedByTaskIDs: [], listColor: .green, specializedFields: ["Quantity": item.1, "Unit": item.2, "Category": item.3, "Store": "Market"], specializedListType: "Shopping & Groceries")
        }
        return ShoppingListWidgetEntry(date: Date(), listID: nil, title: "Groceries", tasks: tasks, store: "", accessNeeded: false, listUnavailable: false, theme: TaskFlowSharedSettings.theme)
    }
    func snapshot(for configuration: ShoppingListWidgetConfigurationIntent, in context: Context) async -> ShoppingListWidgetEntry {
        context.isPreview ? placeholder(in: context) : await entry(configuration)
    }
    func timeline(for configuration: ShoppingListWidgetConfigurationIntent, in context: Context) async -> Timeline<ShoppingListWidgetEntry> {
        Timeline(entries: [await entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func entry(_ configuration: ShoppingListWidgetConfigurationIntent) async -> ShoppingListWidgetEntry {
        let available = ShoppingWidgetListQuery().availableLists()
        let selected = configuration.list.flatMap { chosen in available.first { $0.id == chosen.id } } ?? (configuration.list == nil ? available.first : nil)
        let chosenStore = (configuration.store ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let storeFilter = chosenStore == ShoppingWidgetStoreOptions.allStores ? "" : chosenStore
        let hasAccess = hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder))
        guard let selected else {
            return ShoppingListWidgetEntry(date: Date(), listID: nil, title: "Shopping List", tasks: [], store: storeFilter, accessNeeded: !hasAccess, listUnavailable: configuration.list != nil, theme: TaskFlowSharedSettings.theme)
        }
        let result = await ReminderWidgetStore().loadShoppingItems(listID: selected.id)
        let tasks = result.tasks.filter { storeFilter.isEmpty || ($0.specializedFields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(storeFilter) == .orderedSame }
        return ShoppingListWidgetEntry(date: Date(), listID: selected.id, title: selected.title, tasks: tasks, store: storeFilter, accessNeeded: result.accessNeeded, listUnavailable: false, theme: TaskFlowSharedSettings.theme)
    }
}

struct TaskFlowShoppingListWidget: Widget {
    private var families: [WidgetFamily] {
        var result: [WidgetFamily] = [.systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { result.append(.systemExtraLargePortrait) }
        return result
    }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskFlowShoppingListWidget", intent: ShoppingListWidgetConfigurationIntent.self, provider: ShoppingListWidgetProvider()) { entry in
            ShoppingListWidgetView(entry: entry)
        }
        .configurationDisplayName("Shopping List")
        .description("Check off groceries, see quantities and stores, and open your shopping list.")
        .supportedFamilies(families)
    }
}

struct ShoppingListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: ShoppingListWidgetEntry
    private var rowLimit: Int {
        if dynamicTypeSize.isAccessibilitySize { return family == .systemLarge ? 3 : 6 }
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return 11 }
        return family == .systemExtraLarge ? 10 : 5
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cart.fill").foregroundStyle(entry.theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text(entry.store.isEmpty ? "Shopping & Groceries" : entry.store).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(entry.tasks.count)").font(.headline.monospacedDigit())
                    .padding(8).background(entry.theme.primary.opacity(0.12), in: Circle())
                    .accessibilityLabel("\(entry.tasks.count) items remaining")
            }
            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if entry.listID == nil && !entry.tasks.isEmpty {
                rows
            } else if entry.listID == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.listUnavailable ? "Shopping list unavailable" : "Choose a shopping list").font(.headline)
                    Text(entry.listUnavailable ? "Edit this widget to select another shopping list." : "Set a list’s type to Shopping & Groceries in TaskFlow, then select it in Edit Widget.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else if entry.tasks.isEmpty {
                Label(entry.store.isEmpty ? "Shopping complete" : "No items for this store", systemImage: "checkmark.circle")
                    .font(.headline).foregroundStyle(entry.theme.primary)
                Spacer(minLength: 0)
            } else {
                rows
            }
            Spacer(minLength: 0)
            HStack {
                if entry.tasks.count > rowLimit {
                    Text("+\(entry.tasks.count - rowLimit) more").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Link(destination: entry.listID.map(TaskFlowDeepLink.listURL) ?? TaskFlowDeepLink.captureURL) {
                    Label(entry.listID == nil ? "Open TaskFlow" : "Open List", systemImage: "arrow.up.forward")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.listID.map(TaskFlowDeepLink.listURL) ?? TaskFlowDeepLink.captureURL)
    }
    @ViewBuilder
    private var rows: some View {
        let visible = Array(entry.tasks.prefix(rowLimit))
        if family == .systemExtraLarge {
            let split = (visible.count + 1) / 2
            HStack(alignment: .top, spacing: 16) {
                shoppingRows(Array(visible.prefix(split)))
                shoppingRows(Array(visible.dropFirst(split)))
            }
        } else {
            shoppingRows(visible)
        }
    }

    private func shoppingRows(_ tasks: [WidgetTask]) -> some View {
        VStack(spacing: 0) {
            ForEach(tasks) { task in
                HStack(spacing: 10) {
                    Button(intent: CompleteReminderIntent(reminderID: task.id, title: task.title)) {
                        Image(systemName: "circle").font(.title3).foregroundStyle(entry.theme.primary)
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bought \(task.title)")
                    Link(destination: TaskFlowDeepLink.taskURL(task.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            let details = [task.specializedFields["Category"], task.specializedFields["Store"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                            if !details.isEmpty { Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let quantity = [task.specializedFields["Quantity"], task.specializedFields["Unit"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                    if !quantity.isEmpty {
                        Text("×" + quantity).font(.caption.weight(.semibold))
                            .foregroundStyle((Double(task.specializedFields["Quantity"] ?? "") ?? 0) > 1 ? Color.accentColor : Color.secondary)
                            .lineLimit(1).frame(maxWidth: 75, alignment: .trailing)
                    }
                }
                .padding(.vertical, 5)
                if task.id != tasks.last?.id { Divider() }
            }
        }
    }
}

struct PinnedNoteWidgetEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pinned Note")
    static var defaultQuery = PinnedNoteWidgetQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title.isEmpty ? "Untitled note" : title)", image: .init(systemName: "note.text")) }
}

struct PinnedNoteWidgetQuery: EntityStringQuery {
    private var notes: [PinnedNoteWidgetEntity] {
        TaskFlowSharedNotes.load().filter(\.isPinned).map { PinnedNoteWidgetEntity(id: $0.id.uuidString, title: $0.title) }
    }
    func entities(for identifiers: [String]) async throws -> [PinnedNoteWidgetEntity] {
        let available = notes
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [PinnedNoteWidgetEntity] { notes }
    func entities(matching string: String) async throws -> [PinnedNoteWidgetEntity] {
        notes.filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
    }
}

struct PinnedNoteWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pinned Note"
    static var description = IntentDescription("Choose a note pinned in TaskFlow. Leave blank to use your first pinned note.")
    @Parameter(title: "Note") var note: PinnedNoteWidgetEntity?
    @Parameter(title: "Hide Completed", default: false) var hideCompleted: Bool
    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$note)") { \.$hideCompleted } }
}

struct PinnedNoteWidgetEntry: TimelineEntry {
    let date: Date
    let note: TaskFlowSharedNote?
    let missingSelection: Bool
    let hideCompleted: Bool
    let theme: TaskFlowSharedTheme
}

struct PinnedNoteWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PinnedNoteWidgetEntry {
        PinnedNoteWidgetEntry(date: Date(), note: TaskFlowSharedNote(id: UUID(), title: "Weekend plans", text: "- [x] Book a table\n- [ ] Pack a picnic\n- [ ] Pick up groceries\n- [ ] Charge the camera", folder: "Personal", tags: [], isPinned: true, format: "checklist", updatedAt: Date()), missingSelection: false, hideCompleted: false, theme: TaskFlowSharedSettings.theme)
    }
    func snapshot(for configuration: PinnedNoteWidgetConfigurationIntent, in context: Context) async -> PinnedNoteWidgetEntry {
        context.isPreview ? placeholder(in: context) : entry(configuration)
    }
    func timeline(for configuration: PinnedNoteWidgetConfigurationIntent, in context: Context) async -> Timeline<PinnedNoteWidgetEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func entry(_ configuration: PinnedNoteWidgetConfigurationIntent) -> PinnedNoteWidgetEntry {
        let notes = TaskFlowSharedNotes.load().filter(\.isPinned)
        let chosen = configuration.note.flatMap { selected in notes.first { $0.id.uuidString == selected.id } } ?? (configuration.note == nil ? notes.first : nil)
        return PinnedNoteWidgetEntry(date: Date(), note: chosen, missingSelection: configuration.note != nil && chosen == nil, hideCompleted: configuration.hideCompleted, theme: TaskFlowSharedSettings.theme)
    }
}

struct TaskFlowPinnedNoteWidget: Widget {
    private var families: [WidgetFamily] {
        var result: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { result.append(.systemExtraLargePortrait) }
        return result
    }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskFlowPinnedNoteWidget", intent: PinnedNoteWidgetConfigurationIntent.self, provider: PinnedNoteWidgetProvider()) { entry in
            PinnedNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Pinned Note & Checklist")
        .description("Keep a pinned note nearby and check or uncheck its items.")
        .supportedFamilies(families)
    }
}

struct PinnedNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PinnedNoteWidgetEntry
    private var rowLimit: Int {
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return 10 }
        switch family { case .systemSmall: return 1; case .systemMedium: return 2; default: return 4 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").foregroundStyle(entry.theme.primary)
                Text(entry.note?.title.isEmpty == false ? entry.note!.title : "Pinned Note").font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let note = entry.note {
                let items = note.checklistItems.filter { !entry.hideCompleted || !$0.isChecked }
                if note.format == "checklist" || note.format == "markdown" && !note.checklistItems.isEmpty {
                    if items.isEmpty {
                        Text("All items complete").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(items.prefix(rowLimit))) { item in
                        HStack(spacing: 6) {
                            Button(intent: ToggleNoteChecklistWidgetIntent(noteID: note.id, itemID: item.id, expectedSource: note.text.components(separatedBy: "\n")[item.id], checked: !item.isChecked)) {
                                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(item.isChecked ? entry.theme.primary : .secondary)
                                    .frame(width: 32, height: family == .systemMedium ? 32 : 40)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(item.isChecked ? "Uncheck \(item.title)" : "Check \(item.title)")
                            Text(item.title).font(.subheadline).strikethrough(item.isChecked).foregroundStyle(item.isChecked ? .secondary : .primary).lineLimit(1)
                        }
                    }
                    if items.count > rowLimit { Text("+\(items.count - rowLimit) more").font(.caption2).foregroundStyle(.secondary) }
                } else {
                    Text(.init(note.text)).font(.subheadline).lineLimit(family == .systemSmall ? 4 : 8)
                }
                Spacer(minLength: 0)
                Link("Open Note", destination: TaskFlowDeepLink.noteURL(note.id)).font(.caption.weight(.semibold))
            } else {
                Text(entry.missingSelection ? "This note was deleted or unpinned. Edit the widget to choose another." : "Pin a note in TaskFlow, then select it in Edit Widget.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.note.map { TaskFlowDeepLink.noteURL($0.id) } ?? TaskFlowDeepLink.newNoteURL)
    }
}
