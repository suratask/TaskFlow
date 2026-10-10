import AppIntents
import EventKit
import Foundation
import WidgetKit

struct TaskFlowReminderEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder")
    static var defaultQuery = TaskFlowReminderQuery()

    var id: String
    @Property(title: "Title") var title: String
    var listID: String
    @Property(title: "List") var listName: String
    @Property(title: "Due Date") var dueDate: Date?
    @Property(title: "Completed") var isCompleted: Bool
    @Property(title: "Priority") var priority: Int
    @Property(title: "Notes") var notes: String

    init(id: String, title: String, listName: String, dueDate: Date?, isCompleted: Bool, priority: Int, notes: String = "", listID: String = "") {
        self.id = id
        self.listID = listID
        self.title = title
        self.listName = listName
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.priority = priority
        self.notes = notes
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(listName)")
    }
}

struct TaskFlowListEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder List")
    static var defaultQuery = TaskFlowListQuery()

    var id: String
    @Property(title: "Title") var title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct TaskFlowReminderQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskFlowReminderEntity] {
        let tasks = try await TaskFlowIntentDataStore.shared.tasks()
        return identifiers.compactMap { id in tasks.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [TaskFlowReminderEntity] {
        TaskFlowIntentReminderEdits.suggestions(try await TaskFlowIntentDataStore.shared.tasks())
    }

    func entities(matching string: String) async throws -> [TaskFlowReminderEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return Array(try await TaskFlowIntentDataStore.shared.tasks().filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.listName.localizedCaseInsensitiveContains(query)
        }.prefix(30))
    }
}

struct TaskFlowListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskFlowListEntity] {
        let lists = try await TaskFlowIntentDataStore.shared.lists()
        return identifiers.compactMap { id in lists.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [TaskFlowListEntity] {
        try await TaskFlowIntentDataStore.shared.lists()
    }

    func entities(matching string: String) async throws -> [TaskFlowListEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return try await TaskFlowIntentDataStore.shared.lists().filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor
private final class TaskFlowIntentDataStore {
    static let shared = TaskFlowIntentDataStore()
    private let store = EKEventStore()

    private var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    private func ensureAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try await store.requestFullAccessToReminders()
        }
        guard hasFullAccess else { throw accessError }
    }

    func tasks() async throws -> [TaskFlowReminderEntity] {
        try await ensureAccess()
        let reminders: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) {
                continuation.resume(returning: $0)
            }
        }
        guard let reminders else {
            throw NSError(domain: "TaskFlow.Shortcuts", code: 8, userInfo: [NSLocalizedDescriptionKey: "Reminders could not be loaded. Please try again."])
        }
        let listIDs = availableListIDs
        return reminders.filter { listIDs.contains($0.calendar.calendarIdentifier) }.map(entity).sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            switch ($0.dueDate, $1.dueDate) {
            case let (first?, second?) where first != second: return first < second
            case (.some, nil): return true
            case (nil, .some): return false
            default: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    private func entity(_ reminder: EKReminder) -> TaskFlowReminderEntity {
        TaskFlowReminderEntity(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled Reminder",
            listName: reminder.calendar.title,
            dueDate: reminder.dueDateComponents?.date,
            isCompleted: reminder.isCompleted,
            priority: reminder.priority,
            notes: reminder.notes ?? "",
            listID: reminder.calendar.calendarIdentifier
        )
    }

    private func save(_ reminder: EKReminder) throws -> TaskFlowReminderEntity {
        try store.save(reminder, commit: true)
        WidgetCenter.shared.reloadAllTimelines()
        TaskFlowAppShortcuts.updateAppShortcutParameters()
        return entity(reminder)
    }

    func lists() async throws -> [TaskFlowListEntity] {
        try await ensureAccess()
        return availableLists.map {
            TaskFlowListEntity(id: $0.calendarIdentifier, title: $0.title)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func create(title: String, dueDate: Date?, listID: String?, notes: String?, priority: Int) async throws -> TaskFlowReminderEntity {
        try await ensureAccess()
        let reminder = EKReminder(eventStore: store)
        let list: EKCalendar?
        if let listID {
            guard let match = availableLists.first(where: { $0.calendarIdentifier == listID }) else { throw missingListError }
            guard match.allowsContentModifications else { throw writableListError }
            list = match
        } else {
            // Fall back from TaskFlow's default list to the system default, then any list still turned on.
            let writable = availableLists.filter(\.allowsContentModifications)
            guard !writable.isEmpty else { throw noListsError }
            let preferredID = UserDefaults.standard.string(forKey: "TaskFlow.defaultListID")
            let systemDefaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
            list = writable.first { $0.calendarIdentifier == preferredID }
                ?? writable.first { $0.calendarIdentifier == systemDefaultID }
                ?? writable.first
        }
        guard let list, list.allowsContentModifications else { throw writableListError }
        reminder.calendar = list
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminder.title.isEmpty else { throw emptyTitleError }
        reminder.notes = notes
        reminder.priority = priority
        if let dueDate {
            reminder.startDateComponents = TaskFlowIntentReminderEdits.components(for: dueDate, includeTime: true)
            reminder.dueDateComponents = reminder.startDateComponents
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        return try save(reminder)
    }

    func setCompleted(id: String, completed: Bool) async throws -> TaskFlowReminderEntity {
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        return try save(reminder)
    }

    func reschedule(id: String, to date: Date, includeTime: Bool) async throws -> TaskFlowReminderEntity {
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        TaskFlowIntentReminderEdits.reschedule(reminder, to: date, includeTime: includeTime)
        return try save(reminder)
    }

    func setPriority(id: String, priority: Int) async throws -> TaskFlowReminderEntity {
        guard (0...9).contains(priority) else { throw invalidPriorityError }
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        reminder.priority = priority
        return try save(reminder)
    }

    func rename(id: String, title: String) async throws -> TaskFlowReminderEntity {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw emptyTitleError }
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        reminder.title = title
        return try save(reminder)
    }

    func move(id: String, listID: String) async throws -> TaskFlowReminderEntity {
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        guard let list = availableLists.first(where: { $0.calendarIdentifier == listID }) else { throw missingListError }
        guard list.allowsContentModifications else { throw writableListError }
        reminder.calendar = list
        return try save(reminder)
    }

    func appendNotes(id: String, text: String) async throws -> TaskFlowReminderEntity {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "TaskFlow.Shortcuts", code: 7, userInfo: [NSLocalizedDescriptionKey: "Enter text to append to the reminder's notes."])
        }
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        reminder.notes = [reminder.notes ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return try save(reminder)
    }

    func removeDueDate(id: String) async throws -> TaskFlowReminderEntity {
        try await ensureAccess()
        let reminder = try editableReminder(id: id)
        reminder.dueDateComponents = nil
        reminder.startDateComponents = nil
        reminder.alarms = (reminder.alarms ?? []).filter { $0.structuredLocation != nil }
        return try save(reminder)
    }

    func openTask(id: String) async throws {
        try await ensureAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
              availableListIDs.contains(reminder.calendar.calendarIdentifier) else { throw missingReminderError }
        TaskFlowIntentRoute.open(url: TaskFlowDeepLink.taskURL(id))
    }

    func openList(id: String) async throws {
        try await ensureAccess()
        guard availableListIDs.contains(id) else { throw missingListError }
        TaskFlowIntentRoute.open(url: TaskFlowDeepLink.listURL(id))
    }

    func search(_ phrase: String, listID: String? = nil, completion: TaskFlowCompletionFilter = .all, limit: Int = 100) async throws -> [TaskFlowReminderEntity] {
        TaskFlowIntentReminderEdits.filter(try await tasks(), phrase: phrase, listID: listID, completion: completion, limit: limit)
    }

    private func editableReminder(id: String) throws -> EKReminder {
        guard hasFullAccess else { throw accessError }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
              availableListIDs.contains(reminder.calendar.calendarIdentifier) else { throw missingReminderError }
        guard reminder.calendar.allowsContentModifications else { throw writableListError }
        return reminder
    }

    private var accessError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow full Reminders access for TaskFlow Studio in Settings, then run this shortcut again."]) }
    private var writableListError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 2, userInfo: [NSLocalizedDescriptionKey: "This reminder list is read-only. Choose an editable list and try again."]) }
    private var missingReminderError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 3, userInfo: [NSLocalizedDescriptionKey: "That reminder is no longer available. Refresh the shortcut and try again."]) }
    private var missingListError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 4, userInfo: [NSLocalizedDescriptionKey: "That reminder list is no longer available."]) }
    private var emptyTitleError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 5, userInfo: [NSLocalizedDescriptionKey: "Enter a reminder title."]) }
    private var noListsError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 9, userInfo: [NSLocalizedDescriptionKey: "No editable reminder lists are turned on in TaskFlow Settings."]) }
    /// Lists turned off in TaskFlow Settings are hidden from Shortcuts, like everywhere else in the app.
    private var availableLists: [EKCalendar] { TaskFlowSharedSettings.availableReminderLists(in: store) }
    private var availableListIDs: Set<String> { Set(availableLists.map(\.calendarIdentifier)) }
    private var invalidPriorityError: NSError { NSError(domain: "TaskFlow.Shortcuts", code: 6, userInfo: [NSLocalizedDescriptionKey: "Priority must be a number from 0 through 9."]) }
}

/// Persist navigation until the app's content is ready; URL opening can race cold launch.
enum TaskFlowIntentRoute {
    static let pendingURLKey = TaskFlowSharedIntentRoute.pendingURLKey

    @MainActor
    static func open(url: URL, defaults: UserDefaults = TaskFlowSharedSettings.defaults) {
        TaskFlowSharedIntentRoute.open(url: url, defaults: defaults)
    }

    @MainActor
    static func consume(defaults: UserDefaults = TaskFlowSharedSettings.defaults) -> URL? {
        TaskFlowSharedIntentRoute.consume(defaults: defaults)
    }
}

struct CreateReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Reminder"
    static var description = IntentDescription("Create a reminder in one of your lists.")
    static var openAppWhenRun = false

    @Parameter(title: "Title") var title: String
    @Parameter(title: "Due Date") var dueDate: Date?
    @Parameter(title: "List") var list: TaskFlowListEntity?
    @Parameter(title: "Notes") var notes: String?
    @Parameter(title: "Priority", default: TaskFlowPriorityLevel.none) var priority: TaskFlowPriorityLevel

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title)") { \.$list; \.$dueDate; \.$notes; \.$priority }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<TaskFlowReminderEntity> {
        let created = try await TaskFlowIntentDataStore.shared.create(title: title, dueDate: dueDate, listID: list?.id, notes: notes, priority: priority.eventKitValue)
        return .result(value: created, dialog: "Added \(created.title) to \(created.listName).")
    }
}

struct CompleteReminderAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Reminder"
    static var description = IntentDescription("Mark a selected reminder complete.")
    static var openAppWhenRun = false

    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity

    static var parameterSummary: some ParameterSummary { Summary("Complete \(\.$reminder)") }
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<TaskFlowReminderEntity> {
        let updated = try await TaskFlowIntentDataStore.shared.setCompleted(id: reminder.id, completed: true)
        return .result(value: updated, dialog: "Completed \(reminder.title).")
    }
}

struct ReopenReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Reopen Reminder"
    static var description = IntentDescription("Mark a completed reminder as incomplete.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    static var parameterSummary: some ParameterSummary { Summary("Reopen \(\.$reminder)") }
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<TaskFlowReminderEntity> {
        let updated = try await TaskFlowIntentDataStore.shared.setCompleted(id: reminder.id, completed: false)
        return .result(value: updated, dialog: "Reopened \(reminder.title).")
    }
}

struct RescheduleReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Reschedule Reminder"
    static var description = IntentDescription("Change the due date of a reminder.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    @Parameter(title: "New Due Date") var dueDate: Date
    @Parameter(title: "Include Time", default: true) var includeTime: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("Reschedule \(\.$reminder) to \(\.$dueDate)") { \.$includeTime }
    }
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<TaskFlowReminderEntity> {
        let updated = try await TaskFlowIntentDataStore.shared.reschedule(id: reminder.id, to: dueDate, includeTime: includeTime)
        return .result(value: updated, dialog: "Rescheduled \(updated.title) to \(dueDate.formatted(date: .abbreviated, time: includeTime ? .shortened : .omitted)).")
    }
}

struct SetReminderPriorityIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Reminder Priority"
    static var description = IntentDescription("Set reminder priority from 0 (none) to 9 (lowest).")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    @Parameter(title: "Priority", description: "Use 0 for none, 1 for highest, and 9 for lowest.", inclusiveRange: (0, 9)) var priority: Int
    static var parameterSummary: some ParameterSummary { Summary("Set priority of \(\.$reminder) to \(\.$priority)") }
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<TaskFlowReminderEntity> {
        let updated = try await TaskFlowIntentDataStore.shared.setPriority(id: reminder.id, priority: priority)
        return .result(value: updated, dialog: "Updated priority for \(reminder.title).")
    }
}

struct SearchRemindersIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Reminders"
    static var description = IntentDescription("Find reminders by title, notes, or list name and return them for use in later Shortcut actions. An empty search returns all matching reminders.")
    static var openAppWhenRun = false
    @Parameter(title: "Search", default: "") var query: String
    @Parameter(title: "List") var list: TaskFlowListEntity?
    @Parameter(title: "Completion", default: .all) var completion: TaskFlowCompletionFilter
    @Parameter(title: "Maximum Results", default: 100, inclusiveRange: (1, 1000)) var limit: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Find reminders matching \(\.$query)") { \.$list; \.$completion; \.$limit }
    }
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[TaskFlowReminderEntity]> {
        let matches = try await TaskFlowIntentDataStore.shared.search(query, listID: list?.id, completion: completion, limit: limit)
        return .result(value: matches, dialog: "Found \(matches.count) reminders.")
    }
}

/// "What's due today?" — answers by voice, including anything overdue, and returns the reminders.
struct GetDueTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "What’s Due Today"
    static var description = IntentDescription("Hear and get the reminders due today, including anything overdue.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[TaskFlowReminderEntity]> {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let due = try await TaskFlowIntentDataStore.shared.tasks().filter { task in
            guard !task.isCompleted, let date = task.dueDate else { return false }
            return date < tomorrow
        }
        let overdue = due.filter { ($0.dueDate ?? .distantFuture) < calendar.startOfDay(for: Date()) }.count
        return .result(value: due, dialog: IntentDialog(stringLiteral: Self.summary(titles: due.map(\.title), overdue: overdue)))
    }

    /// "You have 3 things due today: Pay rent, Call Sam, and Buy milk. 1 is overdue."
    static func summary(titles: [String], overdue: Int) -> String {
        guard !titles.isEmpty else { return "Nothing is due today." }
        let named = Array(titles.prefix(3))
        let list = titles.count > named.count
            ? named.joined(separator: ", ") + ", and \(titles.count - named.count) more"
            : ListFormatter.localizedString(byJoining: named)
        let count = titles.count == 1 ? "1 thing" : "\(titles.count) things"
        let overdueText = overdue == 0 ? "" : (overdue == 1 ? " 1 is overdue." : " \(overdue) are overdue.")
        return "You have \(count) due today: \(list).\(overdueText)"
    }
}

struct OpenReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Reminder in TaskFlow Studio"
    static var description = IntentDescription("Open a reminder's full details in TaskFlow Studio.")
    static var openAppWhenRun = true
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$reminder)") }
    func perform() async throws -> some IntentResult {
        try await TaskFlowIntentDataStore.shared.openTask(id: reminder.id)
        return .result()
    }
}

struct OpenReminderListIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Reminder List in TaskFlow Studio"
    static var description = IntentDescription("Open a reminder list in TaskFlow Studio.")
    static var openAppWhenRun = true
    @Parameter(title: "List") var list: TaskFlowListEntity
    static var parameterSummary: some ParameterSummary { Summary("Open list \(\.$list)") }
    func perform() async throws -> some IntentResult {
        try await TaskFlowIntentDataStore.shared.openList(id: list.id)
        return .result()
    }
}

struct TaskFlowAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateReminderIntent(), phrases: ["Add a reminder in \(.applicationName)"], shortTitle: "Add Reminder", systemImageName: "plus.circle")
        AppShortcut(intent: CompleteReminderAppIntent(), phrases: ["Complete \(\.$reminder) in \(.applicationName)"], shortTitle: "Complete Reminder", systemImageName: "checkmark.circle")
        AppShortcut(intent: OpenReminderIntent(), phrases: ["Open \(\.$reminder) in \(.applicationName)"], shortTitle: "Open Reminder", systemImageName: "arrow.up.forward.app")
        AppShortcut(intent: SearchRemindersIntent(), phrases: ["Find reminders in \(.applicationName)"], shortTitle: "Find Reminders", systemImageName: "magnifyingglass")
        AppShortcut(intent: RescheduleReminderIntent(), phrases: ["Reschedule \(\.$reminder) in \(.applicationName)"], shortTitle: "Reschedule", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: ReopenReminderIntent(), phrases: ["Reopen \(\.$reminder) in \(.applicationName)"], shortTitle: "Reopen Reminder", systemImageName: "arrow.uturn.backward.circle")
        AppShortcut(intent: OpenReminderListIntent(), phrases: ["Open the \(\.$list) list in \(.applicationName)"], shortTitle: "Open List", systemImageName: "list.bullet")
        // iOS allows ten App Shortcuts; Get Lists remains available as a Shortcuts action.
        AppShortcut(intent: GetDueTodayIntent(), phrases: ["What’s due today in \(.applicationName)", "What's due today in \(.applicationName)", "What do I have today in \(.applicationName)"], shortTitle: "Due Today", systemImageName: "sun.max")
        AppShortcut(intent: MoveReminderIntent(), phrases: ["Move \(\.$reminder) in \(.applicationName)"], shortTitle: "Move Reminder", systemImageName: "folder")
        AppShortcut(intent: SetReminderPriorityIntent(), phrases: ["Set priority for \(\.$reminder) in \(.applicationName)"], shortTitle: "Set Priority", systemImageName: "flag")
    }
}

extension Notification.Name {
    static let taskFlowIntentRouteChanged = TaskFlowSharedIntentRoute.notification
    static let taskFlowFocusFilterChanged = Notification.Name("TaskFlow.focusFilterChanged")
}

/// Focus filter: while a Focus (for example, Work) is on, TaskFlow shows only the chosen lists.
struct TaskFlowFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Set TaskFlow Lists"
    static var description: IntentDescription? = IntentDescription("Show only the reminder lists you choose while this Focus is on.")

    @Parameter(title: "Lists")
    var lists: [TaskFlowListEntity]?

    var displayRepresentation: DisplayRepresentation {
        let names = (lists ?? []).map(\.title)
        return DisplayRepresentation(title: "TaskFlow Lists", subtitle: "\(names.isEmpty ? "All Lists" : names.joined(separator: ", "))")
    }

    func perform() async throws -> some IntentResult {
        TaskFlowSharedSettings.defaults.set((lists ?? []).map(\.id), forKey: TaskFlowSharedSettings.focusListIDsKey)
        await MainActor.run {
            NotificationCenter.default.post(name: .taskFlowFocusFilterChanged, object: nil)
        }
        return .result()
    }
}

// Keep the numeric priority action for existing saved Shortcuts; offer named levels too.
enum TaskFlowPriorityLevel: String, AppEnum {
    case none, low, medium, high
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Priority")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .none: "None", .low: "Low", .medium: "Medium", .high: "High"
    ]
    var eventKitValue: Int {
        switch self { case .none: 0; case .low: 9; case .medium: 5; case .high: 1 }
    }
}

enum TaskFlowCompletionFilter: String, AppEnum {
    case all, incomplete, completed
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Completion")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "All", .incomplete: "Incomplete", .completed: "Completed"
    ]
}

enum TaskFlowIntentReminderEdits {
    static func suggestions(_ reminders: [TaskFlowReminderEntity]) -> [TaskFlowReminderEntity] {
        // Completed items must remain selectable for Reopen, even with a large inbox.
        Array(reminders.filter { !$0.isCompleted }.prefix(30)) + Array(reminders.filter { $0.isCompleted }.prefix(20))
    }

    static func components(for date: Date, includeTime: Bool, calendar: Calendar = .current) -> DateComponents {
        var fields: Set<Calendar.Component> = [.calendar, .timeZone, .year, .month, .day]
        if includeTime { fields.formUnion([.hour, .minute]) }
        return calendar.dateComponents(fields, from: date)
    }

    static func reschedule(_ reminder: EKReminder, to date: Date, includeTime: Bool, calendar: Calendar = .current) {
        let oldDue = reminder.dueDateComponents?.date
        let newDue = components(for: date, includeTime: includeTime, calendar: calendar)
        reminder.dueDateComponents = newDue
        if reminder.startDateComponents == nil || (reminder.startDateComponents?.date ?? date) > (newDue.date ?? date) {
            reminder.startDateComponents = newDue
        }
        // Creation uses absolute alarms. Move those with the due date, preserving offsets.
        // Relative alarms already follow the due date; location alarms are independent.
        if let oldDue, let newDate = newDue.date {
            let alarms = reminder.alarms ?? []
            for alarm in alarms where alarm.structuredLocation == nil {
                if let absolute = alarm.absoluteDate {
                    alarm.absoluteDate = absolute.addingTimeInterval(newDate.timeIntervalSince(oldDue))
                }
            }
            reminder.alarms = alarms
        }
    }

    static func filter(_ reminders: [TaskFlowReminderEntity], phrase: String, listID: String?, completion: TaskFlowCompletionFilter, limit: Int) -> [TaskFlowReminderEntity] {
        let terms = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return Array(reminders.lazy.filter { task in
            (listID == nil || task.listID == listID) &&
            (completion == .all || task.isCompleted == (completion == .completed)) &&
            terms.allSatisfy { term in
                [task.title, task.listName, task.notes].contains { $0.localizedCaseInsensitiveContains(term) }
            }
        }.prefix(max(1, min(limit, 1000))))
    }
}

struct GetReminderListsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Reminder Lists"
    static var description = IntentDescription("Return all reminder lists for use in other Shortcut actions.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult & ReturnsValue<[TaskFlowListEntity]> {
        .result(value: try await TaskFlowIntentDataStore.shared.lists())
    }
}

struct RenameReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Rename Reminder"
    static var description = IntentDescription("Change a reminder's title and return the updated reminder.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    @Parameter(title: "New Title") var title: String
    static var parameterSummary: some ParameterSummary { Summary("Rename \(\.$reminder) to \(\.$title)") }
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowReminderEntity> {
        .result(value: try await TaskFlowIntentDataStore.shared.rename(id: reminder.id, title: title))
    }
}

struct MoveReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Move Reminder to List"
    static var description = IntentDescription("Move a reminder to an editable list and return the updated reminder.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    @Parameter(title: "List") var list: TaskFlowListEntity
    static var parameterSummary: some ParameterSummary { Summary("Move \(\.$reminder) to \(\.$list)") }
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowReminderEntity> {
        .result(value: try await TaskFlowIntentDataStore.shared.move(id: reminder.id, listID: list.id))
    }
}

struct AppendReminderNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Append Text to Reminder Notes"
    static var description = IntentDescription("Append text without replacing existing reminder notes.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    @Parameter(title: "Text") var text: String
    static var parameterSummary: some ParameterSummary { Summary("Append \(\.$text) to notes of \(\.$reminder)") }
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowReminderEntity> {
        .result(value: try await TaskFlowIntentDataStore.shared.appendNotes(id: reminder.id, text: text))
    }
}

struct RemoveReminderDueDateIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove Reminder Due Date"
    static var description = IntentDescription("Clear a reminder's dates and time alerts, preserving location alerts.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    static var parameterSummary: some ParameterSummary { Summary("Remove due date from \(\.$reminder)") }
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowReminderEntity> {
        .result(value: try await TaskFlowIntentDataStore.shared.removeDueDate(id: reminder.id))
    }
}

struct SetReminderPriorityLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Reminder Priority Level"
    static var description = IntentDescription("Choose None, Low, Medium, or High priority.")
    static var openAppWhenRun = false
    @Parameter(title: "Reminder") var reminder: TaskFlowReminderEntity
    @Parameter(title: "Priority", default: TaskFlowPriorityLevel.none) var priority: TaskFlowPriorityLevel
    static var parameterSummary: some ParameterSummary { Summary("Set priority of \(\.$reminder) to \(\.$priority)") }
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowReminderEntity> {
        .result(value: try await TaskFlowIntentDataStore.shared.setPriority(id: reminder.id, priority: priority.eventKitValue))
    }
}

extension TaskFlowSharedNote {
    init(note: QuickNote) {
        self.init(id: note.id, title: note.title, text: note.text, folder: note.folder, tags: note.tags, isPinned: note.isPinned, format: note.format.rawValue, updatedAt: note.updatedAt ?? note.createdAt)
    }
}

@MainActor
final class RepositoryNoteIntentHandler: TaskFlowNoteIntentHandling {
    private let repository: TaskRepository
    init(repository: TaskRepository) { self.repository = repository }
    func notes() -> [TaskFlowSharedNote] { repository.quickNotes.map(TaskFlowSharedNote.init(note:)) }
    func create(title: String, text: String, folder: String, format: String, pinned: Bool) throws -> TaskFlowSharedNote {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Enter a note title or text.") }
        var note = QuickNote(title: title, text: text, format: QuickNoteFormat(rawValue: format) ?? .plain)
        note.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        note.isPinned = pinned
        guard repository.saveNoteSnapshot(note) else { throw failure("The note could not be saved.") }
        return TaskFlowSharedNote(note: note)
    }
    func append(noteID: UUID, text: String) throws -> TaskFlowSharedNote {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Enter text to append.") }
        guard var note = repository.quickNotes.first(where: { $0.id == noteID }) else { throw failure("This note was deleted. Select another note.") }
        note.text += (note.text.isEmpty ? "" : "\n\n") + text
        guard repository.saveNoteSnapshot(note) else { throw failure("The note could not be saved.") }
        return TaskFlowSharedNote(note: note)
    }
    func setChecked(noteID: UUID, itemID: Int, expectedSource: String, checked: Bool) throws {
        guard var note = repository.quickNotes.first(where: { $0.id == noteID }), [.checklist, .markdown].contains(note.format) else { throw failure("Open TaskFlow to refresh this checklist.") }
        let lines = note.text.components(separatedBy: "\n")
        guard lines.indices.contains(itemID), lines[itemID] == expectedSource else { throw failure("This checklist changed. Open the note or refresh the widget before checking this item.") }
        note.text = NoteChecklist.replacing(note.text, itemID: itemID, checked: checked)
        guard repository.saveNoteSnapshot(note) else { throw failure("The checklist could not be saved.") }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "TaskFlow.Notes", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
}

struct TaskFlowNoteEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note")
    static var defaultQuery = TaskFlowNoteQuery()
    var id: String
    @Property(title: "Title") var title: String
    @Property(title: "Text") var text: String
    @Property(title: "Folder") var folder: String
    @Property(title: "Pinned") var isPinned: Bool
    init(_ note: TaskFlowSharedNote) {
        id = note.id.uuidString
        title = note.title
        text = note.text
        folder = note.folder
        isPinned = note.isPinned
    }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title.isEmpty ? "Untitled note" : title)", subtitle: "\(folder)") }
}

struct TaskFlowNoteQuery: EntityStringQuery {
    @Dependency(key: "TaskFlowNotes") private var handler: any TaskFlowNoteIntentHandling
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskFlowNoteEntity] {
        let notes = handler.notes().map(TaskFlowNoteEntity.init)
        return identifiers.compactMap { id in notes.first { $0.id == id } }
    }
    @MainActor
    func suggestedEntities() async throws -> [TaskFlowNoteEntity] { Array(handler.notes().prefix(50)).map(TaskFlowNoteEntity.init) }
    @MainActor
    func entities(matching string: String) async throws -> [TaskFlowNoteEntity] {
        handler.notes().filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) || $0.text.localizedCaseInsensitiveContains(string) || $0.folder.localizedCaseInsensitiveContains(string) }.map(TaskFlowNoteEntity.init)
    }
}

enum NoteShortcutFormat: String, AppEnum {
    case plain, checklist, markdown
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note Format")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.plain: "Plain", .checklist: "Checklist", .markdown: "Rich Text"]
}

struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Note"
    static var openAppWhenRun = false
    @Dependency(key: "TaskFlowNotes") private var handler: any TaskFlowNoteIntentHandling
    @Parameter(title: "Title", default: "") var title: String
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Folder", default: "") var folder: String
    @Parameter(title: "Format", default: .plain) var format: NoteShortcutFormat
    @Parameter(title: "Pin Note", default: false) var pin: Bool
    static var parameterSummary: some ParameterSummary { Summary("Create note with \(\.$text)") { \.$title; \.$folder; \.$format; \.$pin } }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowNoteEntity> {
        .result(value: TaskFlowNoteEntity(try handler.create(title: title, text: text, folder: folder, format: format.rawValue, pinned: pin)))
    }
}

struct FindNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Notes"
    static var openAppWhenRun = false
    @Dependency(key: "TaskFlowNotes") private var handler: any TaskFlowNoteIntentHandling
    @Parameter(title: "Search", default: "") var query: String
    @Parameter(title: "Folder", default: "") var folder: String
    @Parameter(title: "Pinned Only", default: false) var pinnedOnly: Bool
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TaskFlowNoteEntity]> {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let notes = handler.notes().filter { note in
            (folder.isEmpty || note.folder.localizedCaseInsensitiveCompare(folder) == .orderedSame) && (!pinnedOnly || note.isPinned) &&
            terms.allSatisfy { term in [note.title, note.text, note.folder, note.tags.joined(separator: " ")].contains { $0.localizedCaseInsensitiveContains(term) } }
        }
        return .result(value: notes.map(TaskFlowNoteEntity.init))
    }
}

struct AppendToNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Append to Note"
    static var openAppWhenRun = false
    @Dependency(key: "TaskFlowNotes") private var handler: any TaskFlowNoteIntentHandling
    @Parameter(title: "Note") var note: TaskFlowNoteEntity
    @Parameter(title: "Text") var text: String
    static var parameterSummary: some ParameterSummary { Summary("Append \(\.$text) to \(\.$note)") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TaskFlowNoteEntity> {
        guard let id = UUID(uuidString: note.id) else { throw NSError(domain: "TaskFlow.Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a valid note."]) }
        return .result(value: TaskFlowNoteEntity(try handler.append(noteID: id, text: text)))
    }
}

struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Note"
    static var openAppWhenRun = true
    @Parameter(title: "Note") var note: TaskFlowNoteEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$note)") }
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: note.id) else { throw NSError(domain: "TaskFlow.Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a valid note."]) }
        TaskFlowSharedIntentRoute.open(url: TaskFlowDeepLink.noteURL(id))
        return .result()
    }
}
