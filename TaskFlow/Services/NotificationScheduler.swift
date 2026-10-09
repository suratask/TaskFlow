import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {
    enum AuthorizationStatus: String {
        case unknown = "Unknown"
        case notDetermined = "Not Determined"
        case denied = "Denied"
        case authorized = "Authorized"
        case provisional = "Provisional"
        case ephemeral = "Ephemeral"

        var canSchedule: Bool {
            switch self {
            case .authorized, .provisional, .ephemeral: true
            case .unknown, .notDetermined, .denied: false
            }
        }
    }

    /// A dated list field, such as a bill's cancellation deadline, that should alert on its day.
    struct DeadlineAlert: Equatable {
        var taskID: String
        var listID: String
        var taskTitle: String
        var label: String
        /// Stored `yyyy-MM-dd` day.
        var date: Date
        /// Also alert this many days before; 0 for only the day itself.
        var leadDays: Int = 3
        var customBody: String? = nil
        var hour: Int = 9
        var minute: Int = 0
        var exactFireDate: Date? = nil
        var playsSound: Bool = true
        var episodeShowID: Int? = nil
        var episodeID: Int? = nil
        var episodeLabel: String? = nil
        var episodeRelease: Date? = nil
    }

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "taskflow-due-"
    private var pendingSchedule: ([TaskItem], [DeadlineAlert], Bool)?
    private var isScheduling = false
    private struct Input: Equatable {
        let id: String
        let title: String
        let list: String
        let due: Date?
        let timed: Bool
        let offset: Int?
        let alerts: [ReminderAlert]
        init(_ task: TaskItem) {
            id = task.id; title = task.title; list = task.listID
            due = task.dueDate; timed = task.hasDueTime
            offset = task.alarmOffsetMinutes; alerts = task.additionalAlerts
        }
    }
    private var lastInputs: [Input]?
    private var lastDeadlines: [DeadlineAlert]?
    private var lastLimit: Int?
    private var lastTimeZone: TimeZone?
    private var cachedRequests: [UNNotificationRequest] = []
    private var requestsValidUntil = Date.distantPast

    func authorizationStatus() async -> AuthorizationStatus {
        let settings = await center.notificationSettings()
        return switch settings.authorizationStatus {
        case .notDetermined: AuthorizationStatus.notDetermined
        case .denied: AuthorizationStatus.denied
        case .authorized: AuthorizationStatus.authorized
        case .provisional: AuthorizationStatus.provisional
        case .ephemeral: AuthorizationStatus.ephemeral
        @unknown default: AuthorizationStatus.unknown
        }
    }

    func requestAuthorization() async -> AuthorizationStatus {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return await authorizationStatus()
        }
        return await authorizationStatus()
    }

    func clearTaskNotifications() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) || $0.hasPrefix(EpisodeNotificationActions.snoozePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func rescheduleNotifications(for tasks: [TaskItem], deadlines: [DeadlineAlert] = [], enabled: Bool) async {
        pendingSchedule = (tasks, deadlines, enabled)
        guard !isScheduling else { return }
        isScheduling = true
        defer { isScheduling = false }
        while let (latestTasks, latestDeadlines, latestEnabled) = pendingSchedule {
            pendingSchedule = nil
            await applySchedule(for: latestTasks, deadlines: latestDeadlines, enabled: latestEnabled)
        }
    }

    private func applySchedule(for tasks: [TaskItem], deadlines: [DeadlineAlert], enabled: Bool) async {
        lastSchedulingError = nil
        let existing = await center.pendingNotificationRequests()
        let owned = existing.filter { $0.identifier.hasPrefix(identifierPrefix) }
        let snoozed = existing.filter { $0.identifier.hasPrefix(EpisodeNotificationActions.snoozePrefix) }
        let activeSnoozes = Self.activeEpisodeSnoozeIDs(snoozed, deadlines: deadlines)
        center.removePendingNotificationRequests(withIdentifiers: snoozed.filter { !activeSnoozes.contains($0.identifier) }.map(\.identifier))
        guard enabled, (await authorizationStatus()).canSchedule else {
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier) + snoozed.map(\.identifier))
            return
        }

        // Leave room for notifications owned by other app features.
        let available = max(0, 64 - existing.filter { !$0.identifier.hasPrefix(identifierPrefix) && (!$0.identifier.hasPrefix(EpisodeNotificationActions.snoozePrefix) || activeSnoozes.contains($0.identifier)) }.count)
        let now = Date()
        let inputs = tasks.filter { !$0.isCompleted }.map(Input.init)
        let zone = TimeZone.current
        if lastInputs != inputs || lastDeadlines != deadlines || lastLimit != available || lastTimeZone != zone || now >= requestsValidUntil {
            cachedRequests = Self.requests(for: tasks, deadlines: deadlines, now: now, limit: available)
            lastInputs = inputs; lastDeadlines = deadlines; lastLimit = available; lastTimeZone = zone
            requestsValidUntil = cachedRequests.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }.min() ?? now.addingTimeInterval(60)
            requestsValidUntil = min(requestsValidUntil, now.addingTimeInterval(60))
        }
        let desired = cachedRequests
        let desiredIDs = Set(desired.map(\.identifier))
        let obsolete = owned.filter { !desiredIDs.contains($0.identifier) }.map(\.identifier)
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }
        let byID = Dictionary(owned.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        for request in desired {
            if let old = byID[request.identifier], old.content.isEqual(request.content),
               let oldTrigger = old.trigger, let newTrigger = request.trigger, oldTrigger.isEqual(newTrigger) { continue }
            do { try await center.add(request) }
            catch { lastSchedulingError = error.localizedDescription }
        }
    }

    static func activeEpisodeSnoozeIDs(_ requests: [UNNotificationRequest], deadlines: [DeadlineAlert]) -> Set<String> {
        Set(requests.filter { request in
            deadlines.contains { alert in
                guard let showID = alert.episodeShowID, let episodeID = alert.episodeID else { return false }
                return EpisodeNotificationActions.matches(request.content, taskID: alert.taskID, showID: showID, episodeID: episodeID)
            }
        }.map(\.identifier))
    }
    private(set) var lastSchedulingError: String?

    /// Stable IDs and absolute triggers let edits replace alerts without deleting unrelated requests.
    static func requests(for tasks: [TaskItem], deadlines: [DeadlineAlert] = [], now: Date, limit: Int = 64, calendar: Calendar = .current) -> [UNNotificationRequest] {
        var candidates: [(Date, UNNotificationRequest)] = []
        var seen = Set<String>()
        for task in tasks where !task.isCompleted {
            let due = task.dueDate.flatMap { raw -> Date? in
                guard raw.timeIntervalSince1970.isFinite else { return nil }
                return task.hasDueTime ? raw : (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: raw) ?? raw)
            }
            var dates: [Date] = []
            if let due {
                dates.append(due)
                if let offset = task.alarmOffsetMinutes { dates.append(due.addingTimeInterval(-Double(offset) * 60)) }
            }
            for alert in task.additionalAlerts {
                switch alert {
                case .relative(let minutes):
                    if let due { dates.append(due.addingTimeInterval(-Double(minutes) * 60)) }
                case .absolute(let date): dates.append(date)
                }
            }
            for date in dates where date > now {
                guard let timestamp = Int(exactly: date.timeIntervalSince1970.rounded(.towardZero)) else { continue }
                let identifier = "taskflow-due-" + task.id + "-" + String(timestamp)
                guard seen.insert(identifier).inserted else { continue }
                let content = UNMutableNotificationContent()
                content.title = task.title
                content.body = due.map { date < $0 ? "Due \($0.formatted(date: .abbreviated, time: .shortened))." : "Reminder due in TaskFlow Studio." } ?? "Reminder from TaskFlow Studio."
                content.sound = .default
                content.threadIdentifier = task.listID
                content.userInfo = [TaskFlowNotificationPayload.taskIDKey: task.id, TaskFlowNotificationPayload.listIDKey: task.listID]
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                components.timeZone = calendar.timeZone
                let request = UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                candidates.append((date, request))
            }
        }
        for deadline in deadlines {
            guard deadline.date.timeIntervalSince1970.isFinite,
                  let day = calendar.date(bySettingHour: max(0, min(23, deadline.hour)), minute: max(0, min(59, deadline.minute)), second: 0, of: deadline.date) else { continue }
            let slug = deadline.label.lowercased().replacingOccurrences(of: " ", with: "-")
            for lead in Set([0, max(0, min(deadline.leadDays, 30))]).sorted() {
                guard let date = deadline.exactFireDate ?? calendar.date(byAdding: .day, value: -lead, to: day), date > now,
                      let timestamp = Int(exactly: date.timeIntervalSince1970.rounded(.towardZero)) else { continue }
                let identifier = "taskflow-due-" + deadline.taskID + "-" + slug + "-" + String(timestamp)
                guard seen.insert(identifier).inserted else { continue }
                let content = UNMutableNotificationContent()
                content.title = deadline.label + (deadline.exactFireDate != nil ? " Reminder" : (lead == 0 ? " Today" : " in \(lead) Days"))
                content.body = deadline.customBody ?? (deadline.taskTitle + " · " + deadline.date.formatted(date: .abbreviated, time: .omitted))
                content.sound = deadline.playsSound ? .default : nil
                content.threadIdentifier = deadline.listID
                content.userInfo = [TaskFlowNotificationPayload.taskIDKey: deadline.taskID, TaskFlowNotificationPayload.listIDKey: deadline.listID]
                if let showID = deadline.episodeShowID, let episodeID = deadline.episodeID {
                    content.categoryIdentifier = deadline.episodeRelease.map { $0 <= date } == true ? EpisodeNotificationActions.category : EpisodeNotificationActions.upcomingCategory
                    content.userInfo[EpisodeNotificationActions.showKey] = showID
                    content.userInfo[EpisodeNotificationActions.episodeKey] = episodeID
                    content.userInfo[EpisodeNotificationActions.labelKey] = deadline.episodeLabel ?? "Episode"
                    content.userInfo[EpisodeNotificationActions.titleKey] = deadline.taskTitle
                }
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                components.timeZone = calendar.timeZone
                candidates.append((date, UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))))
            }
        }
        return candidates.sorted {
            $0.0 == $1.0 ? $0.1.identifier < $1.1.identifier : $0.0 < $1.0
        }.prefix(max(0, limit)).map { $0.1 }
    }

    private func notificationBody(for task: TaskItem) -> String {
        if task.isFlagged {
            return "Flagged task due now."
        }
        if let duration = task.durationMinutes {
            return "Due now. Estimated time: \(duration) minutes."
        }
        return "Due now in TaskFlow Studio."
    }
}
