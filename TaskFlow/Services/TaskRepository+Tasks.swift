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
    /// Applies a single field to selected items and records all successful changes in one Undo.
    /// Failed items remain selected in the editor and can be retried independently.
    func bulkUpdateListDetails(ids: Set<String>, listID: String, field: String, value: String) async -> Set<String> {
        let type = listProfile(listID).type
        guard !isUndoing, type.bulkFields.contains(field),
              field != type.stageField || type.stages.contains(value) else { return [] }
        let selected = tasks.filter { ids.contains($0.id) && $0.listID == listID && $0.parentID == nil }
        var previous: [TaskItem] = []
        var snapshots: [String: SpecializedTaskDetails] = [:]
        var applied: Set<String> = []
        var completionChanged = false
        var failures = 0
        for item in selected {
            let old = specializedDetails(item)
            var updated = old
            if value.isEmpty { updated.fields.removeValue(forKey: field) }
            else { updated.fields[field] = value }
            guard updated != old else { applied.insert(item.id); continue }
            do {
                if type == .shopping {
                    _ = try reminderService.saveTask(TaskDraft(task: item), metadataStore: metadataStore, shoppingDetails: updated)
                    taskFetchGeneration &+= 1
                    taskRefresh = nil
                }
                if field == type.stageField, !type.stages.isEmpty {
                    let complete = ["Paid", "Canceled", "Packed", "Finished"].contains(value)
                    if item.isCompleted != complete {
                        try reminderService.setCompleted(complete, task: item, metadataStore: metadataStore)
                        completionChanged = true
                    }
                }
                setSpecializedDetails(updated, for: item)
                if type == .shopping, let index = tasks.firstIndex(where: { $0.id == item.id }) { tasks[index].sharedShoppingDetails = updated }
                previous.append(item)
                snapshots[item.id] = old
                applied.insert(item.id)
            } catch { failures += 1; errorMessage = FriendlyError.message(for: error) }
        }
        if !previous.isEmpty {
            offerUndo("Update \(previous.count) Items", previous: previous)
            taskUndo?.specializedPrevious = snapshots
        }
        if completionChanged { await refreshTasks(); await rescheduleNotifications() }
        if failures > 0 { errorMessage = "Updated \(applied.count) items. \(failures) could not be updated. " + (errorMessage ?? "Please retry.") }
        return applied
    }
    func moveProjectItems(_ items: [TaskItem], to section: String) {
        selectionFeedbackSequence &+= 1
        guard !isUndoing, !items.isEmpty else { return }
        let current = items.map { item in currentTask(id: item.id) ?? item }
        let previous = Dictionary(current.map { ($0.id, specializedDetails($0)) }, uniquingKeysWith: { first, _ in first })
        for task in current {
            var details = specializedDetails(task)
            details.fields["Section"] = section
            specializedTasks[task.metadataID] = details
        }
        metadataStore.specializedTasks = specializedTasks
        offerUndo("Move to section", previous: current)
        taskUndo?.specializedPrevious = previous
    }
    func listIcon(for id: String) -> String { listIcons[id] ?? "list.bullet" }
    func setListIcon(_ icon: String, for id: String) {
        guard Self.listIconChoices.contains(icon) else { return }
        listIcons[id] = icon
        preferences.set(listIcons, forKey: "TaskFlow.listIcons")
        scheduleCloudSync()
    }
    static func orderedLists(_ lists: [TaskList], order: [String]) -> [TaskList] {
        let unique = order.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let ranks = Dictionary(unique.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return lists.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max, right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    func moveLists(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var reordered = lists
        reordered.move(fromOffsets: offsets, toOffset: destination)
        let hidden = (preferences.stringArray(forKey: "TaskFlow.listOrder") ?? []).filter { id in !reordered.contains { $0.id == id } }
        preferences.set(reordered.map(\.id) + hidden, forKey: "TaskFlow.listOrder")
        lists = reordered
        scheduleCloudSync()
    }
    func canAddDependency(_ candidate: TaskItem, to task: TaskItem) -> Bool {
        candidate.id != task.id && !candidate.isCompleted && !dependencyChain(for: candidate).contains { $0.id == task.id }
    }
    func setDependency(_ candidate: TaskItem, for task: TaskItem, enabled: Bool) async -> Bool {
        guard let current = currentTask(id: task.id), let candidate = currentTask(id: candidate.id) else { return false }
        if enabled, !canAddDependency(candidate, to: current) { errorMessage = "This dependency would create a cycle."; return false }
        var draft = TaskDraft(task: current)
        draft.blockedByTaskIDs.removeAll { $0 == candidate.id }
        if enabled { draft.blockedByTaskIDs.append(candidate.id) }
        return await saveTask(draft)
    }
    func waitingOnDescription(_ task: TaskItem) -> String? {
        let blockers = task.blockedByTaskIDs.compactMap { id -> String? in
            guard let blocker = tasks.first(where: { $0.id == id }) else { return "Unavailable task" }
            return blocker.isCompleted ? nil : blocker.title
        }
        if !blockers.isEmpty {
            return "Waiting On: " + blockers.prefix(2).joined(separator: ", ") + (blockers.count > 2 ? " (+\(blockers.count - 2))" : "")
        }
        return task.status == .blocked || task.status == .waiting ? "Waiting On: Not specified" : nil
    }
    /// Reloads every reminder list, then returns the ones turned on in TaskFlow, narrowed by any Focus filter.
    func visibleLists() -> [TaskList] {
        allReminderLists = Self.orderedLists(reminderService.loadLists(), order: preferences.stringArray(forKey: "TaskFlow.listOrder") ?? [])
        let all = enabledReminderLists
        let allowed = focusListIDs
        guard !allowed.isEmpty else { return all }
        let filtered = all.filter { allowed.contains($0.id) }
        return filtered.isEmpty ? all : filtered
    }
    func refreshTasks(force: Bool = true) async {
        // Read-only reloads share a fetch. A successful mutation always requests
        // fresh data; a slower older fetch cannot overwrite its newer result.
        let pending: Task<[TaskItem], Never>
        let generation: Int
        if !force, let existing = taskRefresh {
            pending = existing
            generation = taskFetchGeneration
        } else {
            taskFetchGeneration &+= 1
            generation = taskFetchGeneration
            pending = Task { await self.loadVisibleTasks() }
            taskRefresh = pending
        }
        let loaded = await pending.value
        guard generation == taskFetchGeneration else { return }
        taskRefresh = nil
        metadataStore.performBatchUpdates {
            seedShoppingPriceHistory(from: loaded)
            var incoming = specializedTasks
            for task in loaded {
                guard let details = task.sharedShoppingDetails else { continue }
                incoming[task.metadataID] = details
                if listProfiles[task.listID] == nil { setListProfile(.init(type: .shopping), for: task.listID) }
            }
            if incoming != specializedTasks { specializedTasks = incoming; metadataStore.specializedTasks = incoming }
        }
        if tasks != loaded { tasks = loaded }
    }
    func loadVisibleTasks() async -> [TaskItem] {
        guard usesReminders else { return [] }
        let disabled = disabledReminderListIDs
        let all = await reminderService.loadTasks(metadataStore: metadataStore).filter { !disabled.contains($0.listID) }
        let allowed = focusListIDs
        guard !allowed.isEmpty, all.contains(where: { allowed.contains($0.listID) }) else { return all }
        return all.filter { allowed.contains($0.listID) }
    }
    func bootstrap() async {
        foldLegacyFilters()
        cloudSyncEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        if cloudPreferencesObserver == nil {
            cloudPreferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.preferencesDidChange() }
            }
        }
        metadataStore.onChange = { [weak self] in
            self?.scheduleCloudSync()
        }
        TaskFlowSharedSettings.theme = appTheme.sharedTheme
        await loadAllData()
        scheduleCloudSync()
    }
    /// Foreground and EventKit reconciliation leaves local note/settings state alone.
    func reloadExternalData() async {
        await loadAllData(includeMetadata: false)
        if !isCloudSyncRunning { scheduleCloudSync() }
    }
    func reload() async {
        await loadAllData()
        if !isCloudSyncRunning { scheduleCloudSync() }
    }
    func requestAccess() async {
        _ = await reminderService.requestAccess()
        await loadAllData()
    }
    func resetLaunchSelection() {
        selectedTaskID = nil
        selectedScope = .today
    }
    func completeOnboarding() {
        hasCompletedOnboarding = true
        preferences.set(true, forKey: "TaskFlow.hasCompletedOnboarding")
    }
    func openTask(id: String) {
        guard let task = currentTask(id: id) else {
            pendingOpenTaskID = id
            return
        }
        pendingOpenTaskID = nil
        var destination = task
        var visited: Set<String> = [task.id]
        while let mergedID = specializedDetails(destination).fields["Merged Into"],
              let target = currentTask(id: mergedID), visited.insert(target.id).inserted {
            destination = target
        }
        selectedScope = .list(destination.listID)
        selectedTaskID = destination.id
    }
    func consumeWidgetCompletions() async {
        guard accessState == .granted else { return }
        let ids = TaskFlowSharedWidgetActions.consumeCompletedReminderIDs()
        guard !ids.isEmpty else { return }
        // Widgets already update EventKit; refresh instead of toggling completion again.
        await reload()
    }
    func updateList(id: String, title: String, color: Color) async -> Bool {
        do {
            try reminderService.updateList(id: id, title: title, color: color)
            await reload()
            return true
        } catch { errorMessage = FriendlyError.message(for: error); return false }
    }
    func createList(named name: String) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try reminderService.createList(named: title)
            lists = visibleLists()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func clearCompletedTasks(_ items: [TaskItem]) async {
        guard !isUndoing else { return }
        let confirmed = Set(items.map(\.id))
        let items = tasks.filter { confirmed.contains($0.id) && $0.isCompleted }
        guard !items.isEmpty else { return }
        do {
            try reminderService.deleteTasks(ids: items.map(\.id), metadataStore: metadataStore)
            offerUndo(items.count == 1 ? "Clear completed task" : "Clear \(items.count) completed tasks", previous: items, deleted: true)
            await refreshTasks()
            await rescheduleNotifications()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func moveOverdueTasksToTomorrowMorning() async {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
              let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) else { return }
        await setDueDates(morning, for: overdueTasks)
    }
    var visibleTaskCount: Int {
        filteredTasks.count
    }
    func selectTask(_ task: TaskItem?) {
        selectedTaskID = task?.id
    }
    func color(forTag tag: String) -> Color {
        if let saved = savedTags.first(where: { $0.name.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            return saved.color.color
        }
        return MetadataSnapshot.defaultColor(for: tag).color
    }
    func saveScrollAnchor(_ id: String, for scope: TaskScope) {
        let key = "TaskFlow.scroll.\(scope.id)"
        if preferences.string(forKey: key) != id { preferences.set(id, forKey: key) }
    }
    func dismissUndo() { taskUndo = nil }
    func offerUndo(_ message: String, previous: [TaskItem], deleted: Bool = false) {
        guard !previous.isEmpty, !isUndoing else { return }
        taskRedo = nil
        taskUndo = TaskUndo(message: message, previous: previous, wasDeleted: deleted)
        feedbackSequence += 1
    }
    func undoLastTaskAction() async {
        guard let action = taskUndo else { return }
        await performUndo(action)
    }
    func redoLastTaskAction() async {
        guard let redo = taskRedo, !isUndoing else { return }
        let previous = tasks.filter { task in redo.previous.contains { $0.id == task.id } }
        if await performUndo(redo) {
            taskRedo = nil
            taskUndo = TaskUndo(message: redo.message, previous: previous, wasDeleted: false)
        }
    }
    /// Restores the tasks captured by one undoable action. Called by the system undo manager.
    @discardableResult
    func performUndo(_ action: TaskUndo) async -> Bool {
        guard !isUndoing else { return false }
        isUndoing = true
        defer { isUndoing = false }
        taskRedo = nil
        var restoredCount = 0
        let affectedIDs = Set(action.previous.map(\.id))
        let current = tasks.filter { affectedIDs.contains($0.id) }
        var succeeded = false
        do {
            for previous in action.previous {
                if action.wasDeleted {
                    try reminderService.restoreDeletedTask(previous, metadataStore: metadataStore)
                } else {
                    let details = action.specializedPrevious[previous.id] ?? action.specializedPrevious[previous.metadataID] ?? previous.sharedShoppingDetails
                    let metadataOnly = action.specializedPrevious[previous.id] != nil && currentTask(id: previous.id) == previous
                    if !metadataOnly { _ = try reminderService.saveTask(TaskDraft(task: previous), metadataStore: metadataStore, shoppingDetails: details) }
                }
                restoredCount += 1
            }
            for id in action.createdTaskIDs { try reminderService.deleteTask(id: id, metadataStore: metadataStore) }
            for (id, details) in action.specializedPrevious {
                let metadataID = action.previous.first { $0.id == id || $0.metadataID == id }?.metadataID ?? reminderService.metadataIdentifier(forReminderID: id)
                specializedTasks[metadataID] = details
            }
            if !action.specializedPrevious.isEmpty { metadataStore.specializedTasks = specializedTasks }
            for (id, profile) in action.listProfilesPrevious { setListProfile(profile, for: id) }
            if taskUndo?.id == action.id { taskUndo = nil }
            if !action.wasDeleted && action.createdTaskIDs.isEmpty && action.specializedPrevious.isEmpty && current.count == action.previous.count {
                taskRedo = TaskUndo(message: action.message, previous: current, wasDeleted: false)
            }
            succeeded = true
            undoFeedbackSequence &+= 1
            feedbackSequence += 1
        } catch {
            if taskUndo?.id == action.id { taskUndo?.previous = Array(action.previous.dropFirst(restoredCount)) }
            errorMessage = "Could not undo: " + FriendlyError.message(for: error)
        }
        specializedTasks = metadataStore.specializedTasks
        await refreshTasks()
        quickNotes = metadataStore.quickNotes
        await rescheduleNotifications()
        return succeeded
    }
    func toggleCompletion(for task: TaskItem) async {
        guard !isUndoing else { return }
        do {
            let current = currentTask(id: task.id) ?? task
            let previousDetails = specializedDetails(current)
            var updatedDetails = previousDetails
            updatedDetails.fields = listProfile(current.listID).type.fieldsForCompletion(!current.isCompleted, fields: updatedDetails.fields)
            if !current.isCompleted { updatedDetails.fields["Last Completed"] = SpecializedTaskDetails.dateText(Date()) }
            let shopping = listProfile(current.listID).type == .shopping || current.sharedShoppingDetails != nil
            if shopping {
                updatedDetails.fields["Purchased By"] = current.isCompleted ? nil : shoppingActor
                updatedDetails.fields["Purchased At"] = current.isCompleted ? nil : Date().ISO8601Format()
            }
            try reminderService.setCompleted(!current.isCompleted, task: current, metadataStore: metadataStore, shoppingDetails: shopping ? updatedDetails : nil)
            var displayed = current
            displayed.isCompleted.toggle()
            displayed.status = displayed.isCompleted ? .done : .notStarted
            if shopping { displayed.sharedShoppingDetails = updatedDetails }
            updateTaskInMemory(displayed)
            setSpecializedDetails(updatedDetails, for: current)
            let nextID = !current.isCompleted ? await scheduleNextChore(current) : nil
            offerUndo(current.isCompleted ? "Task reopened" : "Task completed", previous: [current])
            taskUndo?.specializedPrevious[current.id] = previousDetails
            if let nextID { taskUndo?.createdTaskIDs = [nextID] }
            await refreshTasks()
            await rescheduleNotifications()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func setFlagged(_ isFlagged: Bool, for task: TaskItem) async {
        guard !isUndoing else { return }
        do {
            var draft = TaskDraft(task: task)
            draft.isFlagged = isFlagged
            _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
            var displayed = task
            displayed.isFlagged = isFlagged
            updateTaskInMemory(displayed)
            offerUndo("Flag updated", previous: [task])
            await refreshTasks()
            await rescheduleNotifications()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func setPriority(_ priority: TaskPriority, for task: TaskItem) async {
        guard !isUndoing, task.priority != priority else { return }
        do {
            var draft = TaskDraft(task: task)
            draft.priority = priority
            _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
            var displayed = task
            displayed.priority = priority
            updateTaskInMemory(displayed)
            offerUndo("Priority updated", previous: [task])
            await refreshTasks()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func setStatus(_ status: TaskStatus, for task: TaskItem) async {
        guard !isUndoing else { return }
        do {
            var draft = TaskDraft(task: task)
            draft.status = status
            draft.isCompleted = status == .done
            _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
            var displayed = task
            displayed.status = status
            displayed.isCompleted = status == .done
            updateTaskInMemory(displayed)
            offerUndo("Status updated", previous: [task])
            await refreshTasks()
            await rescheduleNotifications()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func setDueDate(_ date: Date?, for task: TaskItem) async {
        await setDueDates(date, for: [task])
    }
    func setDueDates(_ date: Date?, hasDueTime: Bool? = nil, for items: [TaskItem]) async {
        guard !isUndoing else { return }
        var changed: [TaskItem] = []
        guard !items.isEmpty else { return }
        for task in items {
            do {
                var draft = TaskDraft(task: task)
                draft.dueDate = date
                if let hasDueTime { draft.hasDueTime = hasDueTime }
                _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
                changed.append(task)
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
        offerUndo("Schedule updated", previous: changed)
        await refreshTasks()
        await rescheduleNotifications()
    }
    func setDueDate(_ date: Date?, hasDueTime: Bool? = nil, forTaskIDs ids: Set<String>) async {
        await setDueDates(date, hasDueTime: hasDueTime, for: tasks.filter { ids.contains($0.id) })
    }
    func setCompletion(_ isCompleted: Bool, forTaskIDs ids: Set<String>) async {
        guard !isUndoing else { return }
        let changed = tasks.filter { ids.contains($0.id) && $0.isCompleted != isCompleted }
        guard !changed.isEmpty else { return }
        let drafts = changed.map { task -> TaskDraft in
            var draft = TaskDraft(task: task)
            draft.isCompleted = isCompleted
            draft.status = isCompleted ? .done : .active
            return draft
        }
        do {
            try reminderService.saveTasks(drafts, metadataStore: metadataStore)
            var created: [String] = []
            if isCompleted {
                for task in changed { if let id = await scheduleNextChore(task) { created.append(id) } }
            }
            offerUndo(isCompleted ? "Tasks completed" : "Tasks reopened", previous: changed)
            taskUndo?.createdTaskIDs = created
            await refreshTasks()
            await rescheduleNotifications()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func saveTasks(_ drafts: [TaskDraft]) async -> Bool {
        do {
            try reminderService.saveTasks(drafts, metadataStore: metadataStore)
            await refreshTasks()
            await rescheduleNotifications()
            return true
        } catch {
            errorMessage = FriendlyError.message(for: error)
            return false
        }
    }
    func moveTasks(toListID listID: String, taskIDs ids: Set<String>) async {
        selectionFeedbackSequence &+= 1
        guard !isUndoing, lists.contains(where: { $0.id == listID }) else { return }
        let changed = tasks.filter { ids.contains($0.id) && $0.listID != listID }
        guard !changed.isEmpty else { return }
        var saved: [TaskItem] = []
        for task in changed {
            var draft = TaskDraft(task: task)
            draft.listID = listID
            do {
                _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
                saved.append(task)
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
        offerUndo("Tasks moved", previous: saved)
        await refreshTasks()
        await rescheduleNotifications()
    }
    func addTags(_ newTags: [String], to task: TaskItem) async {
        await addTags(newTags, toTaskIDs: [task.id])
    }
    func addTags(_ newTags: [String], toTaskIDs ids: Set<String>) async {
        guard !isUndoing else { return }
        var changed: [TaskItem] = []
        for id in ids {
            if let task = currentTask(id: id) {
                var draft = TaskDraft(task: task)
                var merged = draft.tags
                for tag in newTags where !merged.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
                    merged.append(tag)
                }
                draft.tags = merged
                do {
                    _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
                    changed.append(task)
                } catch {
                    errorMessage = FriendlyError.message(for: error)
                }
            }
        }
        offerUndo("Tags added", previous: changed)
        await refreshTasks()
    }
    func removeTags(_ remove: [String], from task: TaskItem) async {
        await removeTags(remove, fromTaskIDs: [task.id])
    }
    func removeTags(_ remove: [String], fromTaskIDs ids: Set<String>) async {
        guard !isUndoing else { return }
        var changed: [TaskItem] = []
        for id in ids {
            if let task = currentTask(id: id) {
                var draft = TaskDraft(task: task)
                draft.tags.removeAll { t in remove.contains { $0.localizedCaseInsensitiveCompare(t) == .orderedSame } }
                do {
                    _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
                    changed.append(task)
                } catch {
                    errorMessage = FriendlyError.message(for: error)
                }
            }
        }
        offerUndo("Tags removed", previous: changed)
        await refreshTasks()
    }
    func moveTasksToNextOpenWorkBlock(taskIDs ids: Set<String>) async {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        await setDueDates(morning, for: tasks.filter { ids.contains($0.id) })
    }
    func smartReschedule(_ task: TaskItem, option: SmartRescheduleOption) async {
        let cal = Calendar.current
        let now = Date()
        var newDate: Date?
        switch option {
        case .laterToday:
            newDate = cal.date(byAdding: .hour, value: 3, to: now)
        case .tomorrowMorning:
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            newDate = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .nextOpenGap:
            newDate = cal.date(byAdding: .hour, value: 2, to: now)
        case .deferOneWeek:
            newDate = cal.date(byAdding: .day, value: 7, to: now)
        }
        await setDueDate(newDate, for: task)
    }
    func saveSmartList(_ definition: SmartListDefinition) {
        var current = smartLists
        if let idx = current.firstIndex(where: { $0.id == definition.id }) {
            current[idx] = definition
        } else {
            current.append(definition)
        }
        smartLists = current
        metadataStore.smartLists = current
    }
    func deleteSmartList(_ definition: SmartListDefinition) {
        if selectedScope == .smart(definition.id) { selectedScope = .inbox }
        var current = smartLists
        current.removeAll { $0.id == definition.id }
        smartLists = current
        metadataStore.smartLists = current
    }
    var streamingServiceChoices: [String] {
        let used = tasks.flatMap { task -> [String] in
            let fields = specializedDetails(task).fields
            return ReadingMedia.watchLinks(fields).map(\.provider) + [fields["Streaming Service"] ?? ""]
        }
        var choices: [String] = []
        for raw in (preferences.stringArray(forKey: "TaskFlow.streamingServices") ?? []) + used + ReadingMedia.providers {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !choices.contains(where: { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }) { choices.append(value) }
        }
        return choices
    }
    func rememberStreamingServices(_ fields: [String: String]) {
        let values = ReadingMedia.watchLinks(fields).map(\.provider) + [fields["Streaming Service"] ?? ""]
        let previous = preferences.stringArray(forKey: "TaskFlow.streamingServices") ?? []
        preferences.set(Array(Set((previous + values).filter { !$0.isEmpty })).sorted(), forKey: "TaskFlow.streamingServices")
    }
    func applyShowArtwork(_ show: ReadingMedia.ShowArtwork, to task: TaskItem) async -> Bool {
        guard let current = currentTask(id: task.id), let thumbnail = show.thumbnail else { return false }
        var updated = specializedDetails(current)
        let previous = updated.fields
        updated.fields["Thumbnail URL"] = thumbnail.absoluteString
        updated.fields["Artwork Override"] = "true"
        updated.fields.removeValue(forKey: "Local Preview")
        updated.fields.removeValue(forKey: "Suppress Preview")
        updated.fields["Artwork Credit"] = show.url.absoluteString
        updated.fields["Format"] = "TV Show"
        updated.fields.removeValue(forKey: "Captured Format")
        let tags = mediaTags(current.tags, previous: previous, fields: updated.fields)
        updated.fields["Auto Tags"] = ReadingMedia.suggestedTags(updated.fields, includeGenres: false).joined(separator: ",")
        return await saveMediaItem(updated, title: current.title, note: current.notes, tags: tags, for: current)
    }
    func saveTask(_ draft: TaskDraft) async -> Bool {
        guard !isUndoing else { return false }
        let previous = draft.reminderID.flatMap { currentTask(id: $0) }
        do {
            _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
            if let previous { offerUndo("Task updated", previous: [previous]) }
            else { feedbackSequence += 1 }
            await refreshTasks()
            await rescheduleNotifications()
            return true
        } catch {
            errorMessage = FriendlyError.message(for: error)
            return false
        }
    }
    func deleteTasks(_ ids: Set<String>) async {
        guard !isUndoing else { return }
        var deleted: [TaskItem] = []
        for task in tasks.filter({ ids.contains($0.id) }) {
            do {
                try reminderService.deleteTask(id: task.id, metadataStore: metadataStore)
                deleted.append(task)
            } catch { errorMessage = FriendlyError.message(for: error) }
        }
        if !deleted.isEmpty {
            // A fetch started before these deletions must not restore them.
            taskFetchGeneration &+= 1
            taskRefresh = nil
        }
        offerUndo("Delete Tasks", previous: deleted, deleted: true)
        let removed = Set(deleted.map(\.id))
        tasks.removeAll { removed.contains($0.id) }
        if let selectedTaskID, removed.contains(selectedTaskID) { self.selectedTaskID = nil }
        await rescheduleNotifications()
    }
    func deleteTask(_ task: TaskItem) async {
        guard !isUndoing else { return }
        do {
            let current = currentTask(id: task.id) ?? task
            try reminderService.deleteTask(id: task.id, metadataStore: metadataStore)
            taskFetchGeneration &+= 1
            taskRefresh = nil
            offerUndo("Task deleted", previous: [current], deleted: true)
            tasks.removeAll { $0.id == task.id }
            if selectedTaskID == task.id { selectedTaskID = nil }
            await rescheduleNotifications()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
    func saveTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = savedTags
        if !current.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            current.append(SavedTag(name: trimmed, color: .indigo))
            savedTags = current
            metadataStore.savedTags = current
        }
    }
    func renameSavedTag(_ oldName: String, to newName: String) async {
        let normalized = MetadataStore.normalizedTag(newName)
        guard !normalized.isEmpty, oldName != normalized else { return }
        await replaceTag(oldName, with: normalized)
    }
    func deleteSavedTag(_ name: String) async {
        await replaceTag(name, with: nil)
    }
    func replaceTag(_ oldName: String, with newName: String?) async {
        metadataStore.replaceTag(oldName, with: newName)
        // Old note snapshots must not resurrect renamed/deleted global tags.
        noteUndo = nil
        noteRedo = nil
        savedTags = metadataStore.savedTags
        eventTags = metadataStore.eventTags
        if quickNotes != metadataStore.quickNotes { quickNotes = metadataStore.quickNotes }
        eventTags = metadataStore.eventTags
        smartLists = metadataStore.smartLists
        listProfiles = metadataStore.listProfiles
        specializedTasks = metadataStore.specializedTasks
        listTemplates = metadataStore.listTemplates
        func updatedFilter(_ filter: TagFilter?) -> TagFilter? {
            guard case .tag(let name) = filter,
                  name.localizedCaseInsensitiveCompare(oldName) == .orderedSame else { return filter }
            return newName.map { .tag($0) }
        }
        selectedTagFilter = updatedFilter(selectedTagFilter)
        quickTagFilter = updatedFilter(quickTagFilter)
        await refreshTasks()
        await refreshCalendarEvents()
    }
    func setTagColor(_ color: TaskTagColor, for name: String) {
        var current = savedTags
        if let idx = current.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            current[idx].color = color
        } else {
            current.append(SavedTag(name: name, color: color))
        }
        savedTags = current
        metadataStore.savedTags = current
    }
    func blockingTasks(for task: TaskItem) -> [TaskItem] {
        tasks.filter { task.blockedByTaskIDs.contains($0.id) }
    }
    func dependentTasks(for task: TaskItem) -> [TaskItem] {
        tasks.filter { $0.blockedByTaskIDs.contains(task.id) }
    }
    func dependencyChain(for task: TaskItem) -> [TaskItem] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TaskItem] = []
        var visited: Set<String> = [task.id]
        var pending = Array(task.blockedByTaskIDs.reversed())
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let parent = byID[id] else { continue }
            result.append(parent)
            pending.append(contentsOf: parent.blockedByTaskIDs.reversed())
        }
        return result
    }
    func subtasks(for parent: TaskItem) -> [TaskItem] {
        _ = tasksRevision
        return childrenByParent[parent.id] ?? []
    }
    func attachmentURL(for attachment: TaskAttachment) -> URL? {
        metadataStore.attachmentURL(for: attachment)
    }
    func makeURLAttachment(from urlString: String) -> TaskAttachment? {
        metadataStore.makeURLAttachment(from: urlString)
    }
    func importFileAttachment(from url: URL) throws -> TaskAttachment {
        let data = try Data(contentsOf: url)
        return try metadataStore.saveFileAttachment(data: data, suggestedName: url.lastPathComponent, kind: .file)
    }
    func importPhotoAttachment(data: Data, suggestedName: String) throws -> TaskAttachment {
        return try metadataStore.saveFileAttachment(data: data, suggestedName: suggestedName, kind: .photo)
    }
    func requestNotificationAccess() async {
        let status = await notificationScheduler.requestAuthorization()
        notificationStatus = status.canSchedule ? .granted : .denied
        notificationsEnabled = status.canSchedule
        await rescheduleNotifications()
    }
    func loadAllData(includeMetadata: Bool = true) async {
        if let loadingTask {
            await loadingTask.value
            // The shared load may have skipped local metadata (an EventKit-only
            // reload); a cloud merge waiting on it still needs its notes and settings.
            if includeMetadata { applyMetadata() }
            return
        }
        let work = Task { await self.performLoad(includeMetadata: includeMetadata) }
        loadingTask = work
        await work.value
        loadingTask = nil
    }
    func performLoad(includeMetadata: Bool) async {
        let interval = TaskFlowPerformance.begin("Repository reload")
        defer { TaskFlowPerformance.end("Repository reload", interval) }
        isLoading = !hasLoadedInitialData
        defer { isLoading = false; hasLoadedInitialData = true }
        // Local notes are independent of Reminders permission.
        if includeMetadata || !hasLoadedInitialData { applyMetadata() }

        accessState = reminderService.authorizationState
        updateCalendarAccessState()
        let authorization = await notificationScheduler.authorizationStatus()
        notificationStatus = authorization.canSchedule ? .granted : (authorization == .denied ? .denied : .unknown)
        if accessState == .granted {
            lists = visibleLists()
            publishReadingDestinations()
            await refreshTasks(force: false)
            resumeReadingPreviews()
            Task { await refreshWatchShowsIfNeeded() }
            if let id = pendingOpenTaskID { openTask(id: id) }
        } else {
            allReminderLists = []
            lists = []
            tasks = []
        }
        if accessState == .granted {
            TaskFlowSpotlightIndexer.update(tasks: tasks, lists: lists)
        }
        reloadEventCalendars()
        await refreshCalendarEvents()
        await rescheduleNotifications()
    }
    func applyMetadata() {
        savedTags = metadataStore.savedTags
        eventTags = metadataStore.eventTags
        quickNotes = metadataStore.quickNotes
        smartLists = metadataStore.smartLists
        listProfiles = metadataStore.listProfiles
        specializedTasks = metadataStore.specializedTasks
        listTemplates = metadataStore.listTemplates
        let savedPinnedOrder = metadataStore.pinnedListIDs
        let seededOrder = Self.seededPinnedOrder(savedPinnedOrder)
        pinnedItemOrder = seededOrder
        pinnedListIDs = Set(seededOrder.filter { !Self.isBuiltInPinnedID($0) })
    }
    func updateTaskInMemory(_ task: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
    }
    func rescheduleNotifications() async {
        await notificationScheduler.rescheduleNotifications(for: tasks, deadlines: billDeadlineAlerts + episodeReleaseAlerts, enabled: notificationsEnabled)
        await syncDueTodayActivity()
    }
}
