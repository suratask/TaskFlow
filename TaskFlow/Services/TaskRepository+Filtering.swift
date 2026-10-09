import Foundation
import UserNotifications
import CloudKit
import EventKit
import Observation
import SwiftUI
import WidgetKit
import LinkPresentation
import UIKit

extension TaskRepository {
    /// List or Board for a scope: a list keeps it in its profile (synced); other views keep it on this device.
    func viewMode(for scope: TaskScope) -> TaskViewMode {
        let raw: String?
        if case .list(let id) = scope { raw = listProfile(id).settings["View Mode"] }
        else { raw = preferences.string(forKey: "TaskFlow.viewMode." + scope.id) }
        if let raw, let mode = TaskViewMode(rawValue: raw) { return mode.normalized == .board ? .board : .list }
        return taskViewMode == .board ? .board : .list // Earlier app-wide choice.
    }
    func setViewMode(_ mode: TaskViewMode, for scope: TaskScope) {
        let value = mode.normalized == .board ? TaskViewMode.board : .list
        if case .list(let id) = scope {
            var profile = listProfile(id)
            profile.settings["View Mode"] = value.rawValue
            setListProfile(profile, for: id)
        } else {
            preferences.set(value.rawValue, forKey: "TaskFlow.viewMode." + scope.id)
        }
    }
    func isActionableToday(_ task: TaskItem) -> Bool {
        !task.isCompleted && task.status != .blocked && task.status != .waiting
            && !task.blockedByTaskIDs.contains { id in tasks.first { $0.id == id }?.isCompleted != true }
    }
    var todayPriorityIDs: [String] {
        _ = todayPlanningRevision
        guard preferences.string(forKey: "TaskFlow.todayPriorityDay") == TodayPlanning.dayKey(Date()) else { return [] }
        let known = Set(tasks.map(\.metadataID))
        return Array((preferences.stringArray(forKey: "TaskFlow.todayPriorityIDs") ?? []).filter { known.contains($0) }.prefix(3))
    }
    var todayPriorityTasks: [TaskItem] {
        todayPriorityIDs.compactMap { id in tasks.first { $0.metadataID == id } }
    }
    func isTodayPriority(_ task: TaskItem) -> Bool { todayPriorityIDs.contains(task.metadataID) }
    func toggleTodayPriority(_ task: TaskItem) {
        var ids = todayPriorityIDs
        if ids.contains(task.metadataID) { ids.removeAll { $0 == task.metadataID } }
        else {
            guard ids.count < 3 else { errorMessage = "Choose up to three priorities. Remove one before adding another."; return }
            ids.append(task.metadataID)
        }
        persistTodayPriorities(ids)
    }
    func moveTodayPriorities(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var ids = todayPriorityIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        persistTodayPriorities(ids)
    }
    func persistTodayPriorities(_ ids: [String]) {
        preferences.set(TodayPlanning.dayKey(Date()), forKey: "TaskFlow.todayPriorityDay")
        preferences.set(ids, forKey: "TaskFlow.todayPriorityIDs")
        todayPlanningRevision &+= 1
    }
    func isFocusNextList(_ listID: String) -> Bool {
        if let focusNextExcludedListIDs { return !focusNextExcludedListIDs.contains(listID) }
        return ![.shopping, .reading].contains(listProfile(listID).type)
    }
    func setFocusNextList(_ listID: String, included: Bool) {
        // The first choice turns the defaults into an explicit list.
        var excluded = focusNextExcludedListIDs ?? Set(lists.map(\.id).filter { !isFocusNextList($0) })
        if included { excluded.remove(listID) } else { excluded.insert(listID) }
        focusNextExcludedListIDs = excluded
    }
    /// List IDs allowed by the active Focus filter; empty when no filter applies.
    var focusListIDs: Set<String> {
        Set(TaskFlowSharedSettings.defaults.stringArray(forKey: TaskFlowSharedSettings.focusListIDsKey) ?? [])
    }
    var isFocusFilterActive: Bool { !focusListIDs.isEmpty }
    var pinnedLists: [TaskList] {
        let byID = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = pinnedItemOrder.compactMap { byID[$0] }
        let seen = Set(ordered.map(\.id))
        return ordered + lists.filter { pinnedListIDs.contains($0.id) && !seen.contains($0.id) }
    }
    var unpinnedLists: [TaskList] { lists.filter { !pinnedListIDs.contains($0.id) } }
    var pinnedItemIDs: [String] {
        let validListIDs = Set(lists.map(\.id))
        var ids = pinnedItemOrder.filter { Self.isBuiltInPinnedID($0) || (validListIDs.contains($0) && pinnedListIDs.contains($0)) }
        for list in lists where pinnedListIDs.contains(list.id) && !ids.contains(list.id) { ids.append(list.id) }
        return ids
    }
    func togglePinnedList(_ list: TaskList) {
        if !pinnedListIDs.insert(list.id).inserted {
            pinnedListIDs.remove(list.id)
            pinnedItemOrder.removeAll { $0 == list.id }
        } else if !pinnedItemOrder.contains(list.id) {
            pinnedItemOrder.append(list.id)
        }
        metadataStore.pinnedListIDs = pinnedItemOrder
    }
    func movePinnedItems(fromOffsets: IndexSet, toOffset: Int) {
        selectionFeedbackSequence &+= 1
        var ids = pinnedItemIDs
        let moving = fromOffsets.sorted().map { ids[$0] }
        for index in fromOffsets.sorted(by: >) { ids.remove(at: index) }
        let insertion = max(0, min(ids.count, toOffset - fromOffsets.filter { $0 < toOffset }.count))
        ids.insert(contentsOf: moving, at: insertion)
        pinnedItemOrder = ids
        metadataStore.pinnedListIDs = ids
    }
    static func seededPinnedOrder(_ stored: [String]) -> [String] {
        var order = stored
        if !order.contains(PinnedTaskIdentifier.allTasks) { order.insert(PinnedTaskIdentifier.allTasks, at: 0) }
        if !order.contains(PinnedTaskIdentifier.upNext) { order.insert(PinnedTaskIdentifier.upNext, at: min(1, order.count)) }
        return order
    }
    static func isBuiltInPinnedID(_ id: String) -> Bool {
        id == PinnedTaskIdentifier.allTasks || id == PinnedTaskIdentifier.upNext
    }
    /// The tag name when the search text is a complete "#tag" token.
    var searchTagToken: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#"), trimmed.count > 1, !trimmed.contains(" ") else { return nil }
        return String(trimmed.dropFirst())
    }
    /// Completed tasks in the current list, for the Reminders-style "N Completed" row.
    var completedTasksInSelectedScope: [TaskItem] {
        filteredTaskItems(includeCompleted: true, completedOnly: true)
    }
    func taskCount(for scope: TaskScope) -> Int {
        applyScope(tasks.filter { includeCompletedTasks || !$0.isCompleted || scope == .completed }, scope: scope).count
    }
    var selectedTask: TaskItem? {
        guard let selectedTaskID else { return nil }
        return currentTask(id: selectedTaskID)
    }
    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var rootTasks: [TaskItem] {
        filteredTasks.filter { $0.parentID == nil }
    }
    var focusTasks: [TaskItem] {
        tasks.filter { !$0.isCompleted && ($0.priority == .high || $0.isOverdue() || $0.isFlagged) }
    }
    var allTags: [String] {
        let tagsInTasks = Set(tasks.flatMap(\.tags))
        let tagsInSaved = Set(savedTags.map(\.name))
        let tagsInNotes = Set(quickNotes.flatMap(\.tags))
        let tagsInEvents = Set(eventTags.values.flatMap { $0 })
        return Array(tagsInTasks.union(tagsInSaved).union(tagsInNotes).union(tagsInEvents)).sorted()
    }
    func tagUsageCount(_ name: String) -> Int {
        tasks.reduce(0) { $0 + ($1.tags.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ? 1 : 0) }
            + quickNotes.reduce(0) { $0 + ($1.tags.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ? 1 : 0) }
            + eventTags.values.reduce(0) { $0 + ($1.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ? 1 : 0) }
    }
    var overdueTasks: [TaskItem] {
        tasks.filter { $0.isOverdue() }
    }
    var dueTodayTasks: [TaskItem] {
        let cal = Calendar.current
        return tasks.filter { task in
            guard !task.isCompleted, let dueDate = task.dueDate else { return false }
            return cal.isDateInToday(dueDate) || task.isOverdue()
        }
    }
    var readyTasks: [TaskItem] {
        tasks.filter { !$0.isCompleted && $0.blockedByTaskIDs.isEmpty && $0.status != .blocked }
    }
    var flaggedTasks: [TaskItem] {
        tasks.filter { $0.isFlagged }
    }
    var upcomingTasks: [TaskItem] {
        let cal = Calendar.current
        return tasks.filter { task in
            guard !task.isCompleted, let dueDate = task.dueDate else { return false }
            return dueDate > Date() && !cal.isDateInToday(dueDate)
        }
    }
    var filteredTasks: [TaskItem] { filteredTaskItems(includeCompleted: includeCompletedTasks) }
    func calculateFilteredTaskItems(includeCompleted: Bool, completedOnly: Bool) -> [TaskItem] {
        var result = applyScope(completedOnly ? tasks.filter(\.isCompleted) : tasks)
        if case .list(let id) = selectedScope, listProfile(id).type == .shopping, let store = listProfile(id).settings["Store Filter"] {
            result = result.filter { shoppingTask($0, matchesStore: store) }
        }
        if !includeCompleted && selectedScope != .completed {
            result = result.filter { !$0.isCompleted }
        }
        if let selectedTagFilter {
            switch selectedTagFilter {
            case .tag(let tag):
                result = result.filter { task in
                    task.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
                }
            case .noTags:
                result = result.filter { $0.tags.isEmpty }
            }
        }
        if let qFilter = quickTagFilter {
            switch qFilter {
            case .tag(let tag):
                result = result.filter { $0.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
            case .noTags:
                result = result.filter { $0.tags.isEmpty }
            }
        }
        if let qStatus = quickStatusFilter {
            result = result.filter { $0.status == qStatus }
        }
        if let qPriority = quickPriorityFilter {
            result = result.filter { $0.priority == qPriority }
        }
        if quickDueFilter != .any {
            let now = Date()
            let cal = Calendar.current
            switch quickDueFilter {
            case .overdue:
                result = result.filter { $0.isOverdue(now: now, calendar: cal) }
            case .today:
                result = result.filter { task in
                    guard let d = task.dueDate else { return false }
                    return cal.isDateInToday(d)
                }
            case .next7Days:
                result = result.filter { $0.isDue(inNextDays: 7, now: now, calendar: cal) }
            case .noDate:
                result = result.filter { $0.dueDate == nil }
            case .any:
                break
            }
        }
        if dueFilter != .any {
            let now = Date()
            let cal = Calendar.current
            switch dueFilter {
            case .overdue:
                result = result.filter { $0.isOverdue(now: now, calendar: cal) }
            case .today:
                result = result.filter { task in
                    guard let d = task.dueDate else { return false }
                    return cal.isDateInToday(d)
                }
            case .next7Days:
                result = result.filter { $0.isDue(inNextDays: 7, now: now, calendar: cal) }
            case .noDate:
                result = result.filter { $0.dueDate == nil }
            case .any:
                break
            }
        }
        if isSearchActive, let tag = searchTagToken {
            // "#tag" searches match tags exactly, like tag search in Reminders.
            result = result.filter { $0.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
        } else if isSearchActive {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let listNames = Dictionary(lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            result = result.filter { task in
                task.title.localizedCaseInsensitiveContains(q) ||
                task.notes.localizedCaseInsensitiveContains(q) ||
                task.tags.contains { $0.localizedCaseInsensitiveContains(q) } ||
                task.comments.contains { $0.text.localizedCaseInsensitiveContains(q) } ||
                (listNames[task.listID]?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return sortTasks(result)
    }
    var groupedRootTasks: [TaskGroup] { cachedGroups(rootsOnly: true) }
    /// Upcoming (and its older names) always shows day sections.
    var isUpcomingScope: Bool { selectedScope == .next7Days || selectedScope == .upNext }
    var showsGroupHeaders: Bool { isUpcomingScope || taskGroupOption != .none }
    func cachedGroups(rootsOnly: Bool) -> [TaskGroup] {
        let items = filteredTasks
        let key = taskFilterCacheKey + [taskGroupOption.rawValue, String(rootsOnly)]
        if key == groupCacheKey && Date() < groupCacheExpiry { return groupCacheResult }
        let scoped = rootsOnly ? items.filter { $0.parentID == nil } : items
        let result = isUpcomingScope ? Self.upcomingGroups(scoped) : calculateGroups(scoped)
        groupCacheKey = key
        groupCacheExpiry = taskFilterCacheExpiry
        groupCacheResult = result
        return result
    }
    /// Overdue, Today, Tomorrow, the rest of this week by day, then by month.
    static func upcomingGroups(_ list: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> [TaskGroup] {
        let today = calendar.startOfDay(for: now)
        let sorted = list.sorted { ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title) }
        var order: [String] = []
        var titles: [String: String] = [:]
        var members: [String: [TaskItem]] = [:]
        for task in sorted {
            guard let due = task.dueDate else { continue }
            let day = calendar.startOfDay(for: due)
            let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            var id = "", title = ""
            if task.isOverdue(now: now, calendar: calendar) || offset < 0 {
                (id, title) = ("overdue", "Overdue")
            } else if offset == 0 {
                (id, title) = ("today", "Today")
            } else if offset == 1 {
                (id, title) = ("tomorrow", "Tomorrow")
            } else if offset < 7 {
                (id, title) = ("day-\(offset)", due.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            } else {
                let sameYear = calendar.component(.year, from: due) == calendar.component(.year, from: now)
                let month = calendar.dateComponents([.year, .month], from: due)
                (id, title) = ("month-\(month.year ?? 0)-\(month.month ?? 0)", sameYear ? due.formatted(.dateTime.month(.wide)) : due.formatted(.dateTime.month(.wide).year()))
            }
            if members[id] == nil { order.append(id); titles[id] = title }
            members[id, default: []].append(task)
        }
        return order.map { TaskGroup(id: $0, title: titles[$0] ?? "", tasks: members[$0] ?? []) }
    }
    func calculateGroups(_ list: [TaskItem]) -> [TaskGroup] {
        switch taskGroupOption {
        case .none:
            return [TaskGroup(id: "all", title: "All Tasks", tasks: list)]
        case .list:
            let dict = Dictionary(grouping: list, by: \.listID)
            return lists.compactMap { l in
                guard let items = dict[l.id], !items.isEmpty else { return nil }
                return TaskGroup(id: l.id, title: l.title, tasks: items)
            }
        case .dueDate:
            let cal = Calendar.current
            let overdue = list.filter { $0.isOverdue() }
            let today = list.filter { task in
                guard let d = task.dueDate else { return false }
                return cal.isDateInToday(d) && !task.isOverdue()
            }
            let upcoming = list.filter { task in
                guard let d = task.dueDate else { return false }
                return d > Date() && !cal.isDateInToday(d)
            }
            let noDate = list.filter { $0.dueDate == nil }
            var groups: [TaskGroup] = []
            if !overdue.isEmpty { groups.append(TaskGroup(id: "overdue", title: "Overdue", tasks: overdue)) }
            if !today.isEmpty { groups.append(TaskGroup(id: "today", title: "Today", tasks: today)) }
            if !upcoming.isEmpty { groups.append(TaskGroup(id: "upcoming", title: "Upcoming", tasks: upcoming)) }
            if !noDate.isEmpty { groups.append(TaskGroup(id: "noDate", title: "No Due Date", tasks: noDate)) }
            return groups.isEmpty ? [TaskGroup(id: "all", title: "All Tasks", tasks: list)] : groups
        case .tag:
            var dict: [String: [TaskItem]] = [:]
            for task in list {
                if task.tags.isEmpty {
                    dict["Untagged", default: []].append(task)
                } else {
                    for tag in task.tags {
                        dict["#\(tag)", default: []].append(task)
                    }
                }
            }
            return dict.map { TaskGroup(id: $0.key, title: $0.key, tasks: $0.value) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .status:
            return TaskStatus.editableCases.compactMap { status in
                let items = list.filter { $0.status == status }
                return items.isEmpty ? nil : TaskGroup(id: "status-\(status.rawValue)", title: status.rawValue, tasks: items)
            }
        }
    }
    func clearTaskFilters() {
        clearQuickFilters()
        selectedTagFilter = nil
        dueFilter = .any
        searchQuery = ""
    }
    func clearQuickFilters() {
        quickTagFilter = nil
        quickStatusFilter = nil
        quickPriorityFilter = nil
        quickDueFilter = .any
    }
    /// There is one set of filters (status, priority, due, tag), shown as chips. The older
    /// separate due/tag filters fold into it once, so nothing filters invisibly.
    func foldLegacyFilters() {
        if quickDueFilter == .any, dueFilter != .any { quickDueFilter = dueFilter }
        if quickTagFilter == nil, let selectedTagFilter { quickTagFilter = selectedTagFilter }
        dueFilter = .any
        selectedTagFilter = nil
        preferences.set(quickDueFilter.rawValue, forKey: "TaskFlow.quickDueFilter")
        preferences.set(try? JSONEncoder().encode(quickTagFilter), forKey: "TaskFlow.quickTagFilter")
        preferences.removeObject(forKey: "TaskFlow.dueFilter")
        preferences.removeObject(forKey: "TaskFlow.selectedTagFilter")
    }
    /// Active filters in display order, each with a chip title.
    var activeFilters: [ActiveTaskFilter] {
        var result: [ActiveTaskFilter] = []
        if let quickStatusFilter { result.append(.init(kind: .status, title: quickStatusFilter.rawValue)) }
        if let quickPriorityFilter { result.append(.init(kind: .priority, title: quickPriorityFilter.rawValue + " Priority")) }
        if quickDueFilter != .any { result.append(.init(kind: .due, title: quickDueFilter.rawValue)) }
        if let quickTagFilter { result.append(.init(kind: .tag, title: quickTagFilter.title)) }
        return result
    }
    var hasActiveFilters: Bool { !activeFilters.isEmpty }
    func clearFilter(_ kind: TaskFilterKind) {
        switch kind {
        case .status: quickStatusFilter = nil
        case .priority: quickPriorityFilter = nil
        case .due: quickDueFilter = .any
        case .tag: quickTagFilter = nil
        }
    }
    func applyScope(_ items: [TaskItem], scope: TaskScope? = nil) -> [TaskItem] {
        switch scope ?? selectedScope {
        case .all:
            return items
        case .inbox:
            return items.filter { $0.listID == defaultListID || defaultListID.isEmpty }
        case .notes:
            return items.filter { !$0.comments.isEmpty || !$0.notes.isEmpty }
        case .list(let id):
            return items.filter { $0.listID == id }
        case .smart(let id):
            guard let def = smartLists.first(where: { $0.id == id }) else { return items }
            return items.filter { def.matches($0) }
        case .flagged:
            return items.filter { $0.isFlagged }
        case .today:
            let cal = Calendar.current
            return items.filter { task in
                guard let d = task.dueDate else { return false }
                return cal.isDateInToday(d) || task.isOverdue()
            }
        case .completed:
            return items.filter { $0.isCompleted }
        case .next7Days, .upNext:
            // Upcoming: every dated task, shown in day sections like Reminders' Scheduled list.
            return items.filter { $0.dueDate != nil }
        case .planMyDay:
            return items.filter { !$0.isCompleted }
        }
    }
    func sortTasks(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { lhs, rhs in
            let mult = taskSortDirection == .ascending ? 1 : -1
            switch taskSortOption {
            case .dueDate:
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return mult > 0 ? l < r : l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.title < rhs.title
                }
            case .priority:
                let left = lhs.priority == .none ? Int.max : lhs.priority.eventKitValue
                let right = rhs.priority == .none ? Int.max : rhs.priority.eventKitValue
                if left == right { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
                return mult > 0 ? left < right : left > right
            case .title:
                return mult > 0 ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            case .createdAt:
                let l = lhs.createdAt ?? Date.distantPast
                let r = rhs.createdAt ?? Date.distantPast
                return mult > 0 ? l < r : l > r
            case .status:
                return mult > 0 ? lhs.status.rawValue < rhs.status.rawValue : lhs.status.rawValue > rhs.status.rawValue
            }
        }
    }
}
