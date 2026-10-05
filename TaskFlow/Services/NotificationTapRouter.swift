import Foundation
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
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        NotificationTapRouter.shared.route(taskID: taskID)
    }
}
