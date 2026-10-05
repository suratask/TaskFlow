import ActivityKit
import Foundation

@MainActor
final class DueTodayLiveActivityCoordinator {
    private var calendar: Calendar { Calendar.current }
    private var pendingSync: ([TaskItem], [TaskList])?
    private var isSyncing = false

    func sync(tasks: [TaskItem], lists: [TaskList]) async {
        pendingSync = (tasks, lists)
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while let (latestTasks, latestLists) = pendingSync {
            pendingSync = nil
            await apply(tasks: latestTasks, lists: latestLists)
        }
    }

    private func apply(tasks: [TaskItem], lists: [TaskList]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endActivities()
            return
        }

        let todayTasks = tasks
            .filter(isIncompleteAndDueToday)
            .sorted(by: sortTasks)

        guard !todayTasks.isEmpty else {
            await endActivities()
            return
        }

        let snapshots = todayTasks
            .prefix(3)
            .map { Self.snapshot(from: $0, lists: lists) }

        let state = TaskFlowDueTodayActivityAttributes.ContentState(
            tasks: Array(snapshots),
            openCount: todayTasks.count,
            highPriorityCount: todayTasks.filter { $0.priority == .high }.count,
            nextDueDate: todayTasks.first?.dueDate,
            updatedAt: Date()
        )
        let content = ActivityContent(state: state, staleDate: nextRefreshDate())

        let activities = Activity<TaskFlowDueTodayActivityAttributes>.activities
        if let activity = activities.first {
            for duplicate in activities.dropFirst() { await duplicate.end(nil, dismissalPolicy: .immediate) }
            await activity.update(content)
            return
        }

        do {
            _ = try Activity.request(
                attributes: TaskFlowDueTodayActivityAttributes(title: "Today's Tasks"),
                content: content,
                pushType: nil
            )
        } catch {
            // Live Activities can be unavailable on some devices or user settings.
        }
    }

    func endCurrentActivity() async {
        await sync(tasks: [], lists: [])
    }

    private func endActivities() async {
        for activity in Activity<TaskFlowDueTodayActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func isIncompleteAndDueToday(_ task: TaskItem) -> Bool {
        guard !task.isCompleted, let dueDate = task.dueDate else { return false }
        return calendar.isDateInToday(dueDate)
    }

    private func sortTasks(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?):
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func snapshot(from task: TaskItem, lists: [TaskList]) -> TaskFlowDueTodayTaskSnapshot {
        TaskFlowDueTodayTaskSnapshot(
            id: task.id,
            title: String(task.title.prefix(160)),
            listTitle: lists.first { $0.id == task.listID }?.title ?? "TaskFlow Studio",
            dueDate: task.dueDate,
            priority: task.priority.eventKitValue,
            isCompleted: task.isCompleted,
            isFlagged: task.isFlagged,
            tags: Array(task.tags.prefix(3)).map { String($0.prefix(40)) }
        )
    }

    private func nextRefreshDate() -> Date? {
        let now = Date()
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        return min(now.addingTimeInterval(15 * 60), midnight)
    }
}


@MainActor
final class EventLiveActivityCoordinator {
    static func isActive(eventID: String) -> Bool {
        Activity<TaskFlowEventActivityAttributes>.activities.contains { $0.attributes.eventID == eventID }
    }

    static func start(eventID: String, title: String, calendarTitle: String, location: String?, startDate: Date, endDate: Date) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw NSError(domain: "TaskFlow.LiveActivity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Live Activities are turned off in Settings."])
        }
        guard !eventID.isEmpty, !title.isEmpty, endDate > Date(), startDate < Date().addingTimeInterval(8 * 60 * 60), endDate > startDate else {
            throw NSError(domain: "TaskFlow.LiveActivity", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose an event that is happening now or starts within the next 8 hours."])
        }
        for activity in Activity<TaskFlowEventActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = TaskFlowEventActivityAttributes(eventID: eventID, title: title, calendarTitle: calendarTitle,
                                                         location: location, startDate: startDate, endDate: endDate)
        let content = ActivityContent<TaskFlowEventActivityAttributes.ContentState>(state: TaskFlowEventActivityAttributes.ContentState(updatedAt: Date()), staleDate: endDate)
        let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        Task {
            let remaining = max(0, endDate.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard let stillActive = Activity<TaskFlowEventActivityAttributes>.activities.first(where: { $0.id == activity.id }) else { return }
            await stillActive.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func end(eventID: String, matching deletion: EventDeletion? = nil) async {
        for activity in Activity<TaskFlowEventActivityAttributes>.activities where activity.attributes.eventID == eventID {
            if let deletion {
                let start = activity.attributes.startDate
                if deletion.scope == .thisEvent && start != deletion.startDate { continue }
                if deletion.scope == .thisAndFuture && start < deletion.startDate { continue }
            }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func reconcile(events: [CalendarEvent]) async {
        let byOccurrence = Dictionary(events.map { ($0.occurrenceKey, $0) }, uniquingKeysWith: { first, _ in first })
        for activity in Activity<TaskFlowEventActivityAttributes>.activities {
            let attributes = activity.attributes
            guard let event = byOccurrence["\(attributes.eventID)-\(attributes.startDate.timeIntervalSince1970)"], event.endDate > Date(), event.startDate == attributes.startDate,
                  event.endDate == attributes.endDate, event.title == attributes.title,
                  event.location == attributes.location else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
        }
    }
}
