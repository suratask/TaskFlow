import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

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
enum WidgetColors {
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

struct WidgetThemeStyle {
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

extension Array where Element == WidgetTask {
    var firstHighPriorityTask: WidgetTask? { first { $0.isOverdue || (1...4).contains($0.priority) } }
    var overdueCount: Int { filter(\.isOverdue).count }
    var beforeNoonCount: Int {
        filter { task in guard let dueDate = task.dueDate else { return false }; return Calendar.current.isDateInToday(dueDate) && Calendar.current.component(.hour, from: dueDate) < 12 }.count
    }
    var highPriorityCount: Int { filter { (1...4).contains($0.priority) }.count }
}

extension WidgetTask {
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

extension WidgetAgendaItem {
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

extension Date {
    var relativeOverdueText: String {
        let minutes = max(1, Int(Date().timeIntervalSince(self) / 60))
        return minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    }
}

extension WidgetFamily {
    var isSystemMedium: Bool { self == .systemMedium }
}

extension TaskFlowSharedSmartListDefinition {
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

extension WidgetTask {
    func isDueWithinNextDays(_ days: Int) -> Bool {
        guard let dueDate else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let limit = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return dueDate >= today && dueDate < limit
    }
}
