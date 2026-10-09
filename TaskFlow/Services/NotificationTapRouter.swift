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

    // Routing posts a notification that SwiftUI observers handle by mutating UI state, so it must run on the main actor.
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let taskID = response.notification.request.content.userInfo[TaskFlowNotificationPayload.taskIDKey] as? String else {
            return
        }
        switch response.actionIdentifier {
        case EpisodeNotificationActions.watched, EpisodeNotificationActions.snooze:
            let payload = response.notification.request.content.userInfo
            guard let showID = payload[EpisodeNotificationActions.showKey] as? Int,
                  let episodeID = payload[EpisodeNotificationActions.episodeKey] as? Int,
                  let repository = Self.watchRepository else { return }
            _ = await repository.handleEpisodeNotification(taskID: taskID, showID: showID, episodeID: episodeID,
                snooze: response.actionIdentifier == EpisodeNotificationActions.snooze, content: response.notification.request.content)
        case UNNotificationDefaultActionIdentifier:
            NotificationTapRouter.shared.route(taskID: taskID)
        default: break
        }
    }
}
