import ActivityKit
import Foundation

struct TaskFlowDueTodayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var tasks: [TaskFlowDueTodayTaskSnapshot]
        var openCount: Int
        var highPriorityCount: Int
        var nextDueDate: Date?
        var updatedAt: Date

        var completedCount: Int {
            tasks.filter(\.isCompleted).count
        }

        var nextDueSummary: String {
            nextDueDate?.formatted(date: .omitted, time: .shortened) ?? "Clear"
        }
    }

    var title: String
}

struct TaskFlowDueTodayTaskSnapshot: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var listTitle: String
    var dueDate: Date?
    var priority: Int
    var isCompleted: Bool
    var isFlagged: Bool
    var tags: [String]

    var dueSummary: String {
        guard let dueDate else { return "Today" }
        return dueDate.formatted(date: .omitted, time: .shortened)
    }
}


struct TaskFlowEventActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var updatedAt: Date
    }

    var eventID: String
    var title: String
    var calendarTitle: String
    var location: String?
    var startDate: Date
    var endDate: Date
}
