import Foundation
import BackgroundTasks
import UserNotifications
import UIKit

enum TaskFlowNotificationPayload {
    static let taskIDKey = "taskflowTaskID"
    static let listIDKey = "taskflowListID"
}

extension Notification.Name {
    static let taskFlowNotificationTaskTapped = Notification.Name("TaskFlow.notificationTaskTapped")
}

final class NotificationTapRouter {
    static let shared = NotificationTapRouter()

    private let lock = NSLock()
    private var pendingTaskID: String?

    private init() {}

    func route(taskID: String) {
        lock.lock()
        pendingTaskID = taskID
        lock.unlock()

        NotificationCenter.default.post(
            name: .taskFlowNotificationTaskTapped,
            object: nil,
            userInfo: [TaskFlowNotificationPayload.taskIDKey: taskID]
        )
    }

    func consumePendingTaskID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let taskID = pendingTaskID
        pendingTaskID = nil
        return taskID
    }
}

final class TaskFlowAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var watchRepository: TaskRepository?
    static let watchRefreshID = "com.surratt.TaskFlow.watchRefresh"
    @MainActor static func scheduleWatchRefresh() {
        guard let repository = watchRepository, repository.tasks.contains(where: { !$0.isCompleted && ReadingMedia.tracking(repository.specializedDetails($0).fields) != nil && repository.specializedDetails($0).fields["Progress"] != "Dropped" }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: watchRefreshID)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        TaskFlowMetrics.shared.start() // Daily crash, hang, and launch-time reports from real use.
        UNUserNotificationCenter.current().setNotificationCategories(EpisodeNotificationActions.categories)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.watchRefreshID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                guard let repository = Self.watchRepository else { refresh.setTaskCompleted(success: false); return }
                let success = await repository.refreshWatchInBackground()
                Self.scheduleWatchRefresh()
                refresh.setTaskCompleted(success: success && !Task.isCancelled)
            }
            refresh.expirationHandler = { work.cancel() }
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// iOS calls this off the main actor with objects that aren't Sendable, so copy out plain values
    /// here and do the routing (which mutates UI state) on the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        guard let taskID = request.content.userInfo[TaskFlowNotificationPayload.taskIDKey] as? String else { return }
        let action = response.actionIdentifier
        let showID = request.content.userInfo[EpisodeNotificationActions.showKey] as? Int
        let episodeID = request.content.userInfo[EpisodeNotificationActions.episodeKey] as? Int
        let content = ImmutableNotificationContent(value: request.content)
        await Self.route(taskID: taskID, action: action, showID: showID, episodeID: episodeID, content: content)
    }

    @MainActor
    private static func route(taskID: String, action: String, showID: Int?, episodeID: Int?, content: ImmutableNotificationContent) async {
        switch action {
        case EpisodeNotificationActions.watched, EpisodeNotificationActions.snooze:
            guard let showID, let episodeID, let repository = watchRepository else { return }
            _ = await repository.handleEpisodeNotification(taskID: taskID, showID: showID, episodeID: episodeID,
                snooze: action == EpisodeNotificationActions.snooze, content: content.value)
        case UNNotificationDefaultActionIdentifier:
            NotificationTapRouter.shared.route(taskID: taskID)
        default: break
        }
    }
}


/// UNNotificationContent is immutable (the mutable variant is a separate class), so it is safe to hand
/// from the notification delegate to the main actor.
private struct ImmutableNotificationContent: @unchecked Sendable {
    let value: UNNotificationContent
}
