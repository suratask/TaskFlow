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

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "taskflow-due-"
    private var pendingSchedule: ([TaskItem], Bool)?
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
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func rescheduleNotifications(for tasks: [TaskItem], enabled: Bool) async {
        pendingSchedule = (tasks, enabled)
        guard !isScheduling else { return }
        isScheduling = true
        defer { isScheduling = false }
        while let (latestTasks, latestEnabled) = pendingSchedule {
            pendingSchedule = nil
            await applySchedule(for: latestTasks, enabled: latestEnabled)
        }
    }

    private func applySchedule(for tasks: [TaskItem], enabled: Bool) async {
        lastSchedulingError = nil
        let existing = await center.pendingNotificationRequests()
        let owned = existing.filter { $0.identifier.hasPrefix(identifierPrefix) }
        guard enabled, (await authorizationStatus()).canSchedule else {
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier))
            return
        }

        // Leave room for notifications owned by other app features.
        let available = max(0, 64 - existing.filter { !$0.identifier.hasPrefix(identifierPrefix) }.count)
        let now = Date()
        let inputs = tasks.filter { !$0.isCompleted }.map(Input.init)
        let zone = TimeZone.current
        if lastInputs != inputs || lastLimit != available || lastTimeZone != zone || now >= requestsValidUntil {
            cachedRequests = Self.requests(for: tasks, now: now, limit: available)
            lastInputs = inputs; lastLimit = available; lastTimeZone = zone
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

    private(set) var lastSchedulingError: String?

    /// Stable IDs and absolute triggers let edits replace alerts without deleting unrelated requests.
    static func requests(for tasks: [TaskItem], now: Date, limit: Int = 64, calendar: Calendar = .current) -> [UNNotificationRequest] {
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
