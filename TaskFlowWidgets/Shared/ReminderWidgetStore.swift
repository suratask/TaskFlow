import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

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
    private lazy var watchedEpisodeActions = WatchedEpisodeActionStore.pending()
    private lazy var listTypes = TaskFlowSharedSettings.defaults.dictionary(forKey: "TaskFlow.specializedListTypes") as? [String: String] ?? [:]
    private func widgetTask(_ reminder: EKReminder) -> WidgetTask {
        var task = WidgetTask(reminder: reminder, metadata: reminder.calendarItemExternalIdentifier.flatMap { metadata[$0] } ?? metadata[reminder.calendarItemIdentifier] ?? TaskFlowSharedTaskMetadata(), listType: listTypes[reminder.calendar.calendarIdentifier] ?? "Standard")
        task.specializedFields = WatchedEpisodeActionStore.applying(watchedEpisodeActions, fields: task.specializedFields, taskID: task.id, metadataID: task.externalID.flatMap { $0.isEmpty ? nil : $0 } ?? task.id)
        return task
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

    func loadMediaItems(listID: String, watch: Bool) async -> (tasks: [WidgetTask], accessNeeded: Bool) {
        guard hasReminderAccess else { return ([], true) }
        let calendars = store.calendars(for: .reminder).filter { $0.calendarIdentifier == listID }
        guard !calendars.isEmpty else { return ([], false) }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let tasks = await reminders(matching: predicate).map(widgetTask).filter {
            $0.parentID == nil && ReadingMedia.isPending($0.specializedFields, watch: watch)
        }
        return (tasks.sorted {
            let first = $0.specializedFields["Progress"] == "In Progress"
            let second = $1.specializedFields["Progress"] == "In Progress"
            if first != second { return first }
            return WidgetTask.sort($0, $1)
        }, false)
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
