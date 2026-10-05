import Foundation
import EventKit
import Observation
import SwiftUI
import WidgetKit

@MainActor
@Observable
final class TaskRepository {
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var id: String { rawValue }
    }

    enum AppTheme: String, CaseIterable, Identifiable {
        case system = "System"
        case classicBlue = "Classic Blue"
        case oceanTeal = "Ocean Teal"
        case meadowGreen = "Meadow Green"
        case sunsetCoral = "Sunset Coral"
        case grape = "Grape"
        case slate = "Slate"
        case aurora = "Aurora"
        case ember = "Ember"
        case rose = "Rose"
        case lagoon = "Lagoon"
        case sunrise = "Sunrise"
        case taskflow = "TaskFlow"
        case ocean = "Ocean"
        case citrus = "Citrus"
        case berry = "Berry"
        case graphite = "Graphite"

        var id: String { rawValue }

        /// Older themes duplicated these colors; they remain decodable but map to the matching accent.
        static let selectableCases: [AppTheme] = [.system, .classicBlue, .oceanTeal, .meadowGreen, .sunsetCoral, .grape, .slate, .aurora, .ember, .rose, .lagoon, .sunrise]

        var canonical: AppTheme {
            switch self {
            case .taskflow: .classicBlue
            case .ocean: .oceanTeal
            case .citrus: .sunsetCoral
            case .berry: .grape
            case .graphite: .slate
            default: self
            }
        }

        var sharedTheme: TaskFlowSharedTheme {
            TaskFlowSharedTheme(rawValue: canonical.rawValue) ?? .system
        }
        var primary: Color { sharedTheme.primary }
        var secondary: Color { sharedTheme.secondary }
        var tertiary: Color { sharedTheme.tertiary }
    }

    enum TaskViewMode: String, CaseIterable, Identifiable {
        case list = "List"
        case timeline = "Timeline"
        case calendar = "Calendar"
        case agenda = "Agenda"
        case board = "Board"

        var id: String { rawValue }
    }

    enum TaskDensity: String, CaseIterable, Identifiable {
        case compact = "Compact"
        case comfortable = "Comfortable"
        case detailed = "Detailed"

        var id: String { rawValue }
    }

    enum DueFilter: String, CaseIterable, Identifiable {
        case any = "Any Due Date"
        case overdue = "Overdue"
        case today = "Today"
        case next7Days = "Next 7 Days"
        case noDate = "No Date"

        var id: String { rawValue }
    }

    enum TagFilter: Hashable, Identifiable, Codable {
        case tag(String)
        case noTags

        var id: String {
            switch self {
            case .tag(let tag): "tag:\(tag.lowercased())"
            case .noTags: "no-tags"
            }
        }

        var title: String {
            switch self {
            case .tag(let tag): "#\(tag)"
            case .noTags: "Untagged"
            }
        }
    }

    enum TaskGroupOption: String, CaseIterable, Identifiable {
        case none = "None"
        case list = "List"
        case dueDate = "Due Date"
        case tag = "Tag"
        case status = "Status"

        var id: String { rawValue }
    }

    enum TaskSortOption: String, CaseIterable, Identifiable {
        case dueDate = "Due Date"
        case priority = "Priority"
        case title = "Title"
        case createdAt = "Created Date"
        case status = "Status"

        var id: String { rawValue }
    }

    enum TaskSortDirection: String, CaseIterable, Identifiable {
        case ascending = "Ascending"
        case descending = "Descending"

        var id: String { rawValue }
    }

    enum EventAccessState: String {
        case unknown = "Unknown"
        case granted = "Granted"
        case denied = "Denied"
        case restricted = "Restricted"

        var message: String {
            switch self {
            case .unknown: "TaskFlow Studio needs Calendar access to show events alongside tasks."
            case .granted: "Calendar access granted."
            case .denied: "Calendar access is turned off in system Settings."
            case .restricted: "Calendar access is restricted on this device."
            }
        }
    }

    enum NotificationStatus: String {
        case unknown = "Unknown"
        case granted = "Granted"
        case denied = "Denied"
    }

    struct TaskGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [TaskItem]
    }

    // Properties
    var tasks: [TaskItem] = [] {
        didSet {
            tasksRevision &+= 1
            taskFilterRevision &+= 1
            linkedNoteURLs = Set(tasks.compactMap(\.url))
            childrenByParent = Dictionary(grouping: tasks.filter { $0.parentID != nil }, by: { $0.parentID! })
            taskIndexByID = Dictionary(tasks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// Constant-time lookup; per-task helpers run inside loops over every task.
    @ObservationIgnored private var taskIndexByID: [String: Int] = [:]
    private func currentTask(id: String) -> TaskItem? {
        guard let index = taskIndexByID[id], tasks.indices.contains(index), tasks[index].id == id else { return nil }
        return tasks[index]
    }
    private(set) var tasksRevision = 0
    private(set) var notesRevision = 0
    private(set) var attachmentContentRevision = 0
    private(set) var linkedNoteURLs: Set<URL> = []
    @ObservationIgnored private var childrenByParent: [String: [TaskItem]] = [:]
    var listProfiles: [String: SpecializedListProfile] = [:] { didSet { taskFilterRevision &+= 1 } }
    var specializedTasks: [String: SpecializedTaskDetails] = [:] { didSet { taskFilterRevision &+= 1 } }
    var listTemplates: [SpecializedListTemplate] = []

    func listProfile(_ id: String) -> SpecializedListProfile { listProfiles[id] ?? SpecializedListProfile() }
    func setListProfile(_ profile: SpecializedListProfile, for id: String) {
        guard listProfile(id) != profile else { return }
        listProfiles[id] = profile
        metadataStore.listProfiles = listProfiles
    }
    func specializedDetails(_ task: TaskItem) -> SpecializedTaskDetails {
        currentTask(id: task.id)?.sharedShoppingDetails ?? task.sharedShoppingDetails ?? specializedTasks[task.metadataID] ?? specializedTasks[task.id] ?? SpecializedTaskDetails()
    }
    func setSpecializedDetails(_ details: SpecializedTaskDetails, for task: TaskItem) {
        if specializedTasks[task.metadataID] != details {
            specializedTasks[task.metadataID] = details
            metadataStore.specializedTasks = specializedTasks
        }
        if let index = tasks.firstIndex(where: { $0.id == task.id }), tasks[index].sharedShoppingDetails != nil, tasks[index].sharedShoppingDetails != details {
            tasks[index].sharedShoppingDetails = details
        }
    }
    func setSpecializedStage(_ stage: String, for task: TaskItem, type: SpecializedListType) async {
        guard type.stages.contains(stage) else { return }
        var details = specializedDetails(task)
        details.fields[type == .reading ? "Progress" : "Stage"] = stage
        _ = await saveSpecializedDetails(details, for: task, type: type)
    }
    func saveSpecializedDetails(_ details: SpecializedTaskDetails, for task: TaskItem, type: SpecializedListType) async -> Bool {
        guard !isUndoing else { return false }
        let current = currentTask(id: task.id) ?? task
        let previous = specializedDetails(current)
        guard previous != details else { return true }
        let stage = details.fields[type == .reading ? "Progress" : "Stage"] ?? ""
        let completionChanged = type.stages.contains(stage) && current.isCompleted != ["Paid", "Canceled", "Packed", "Finished"].contains(stage)
        do {
            if type == .shopping {
                _ = try reminderService.saveTask(TaskDraft(task: current), metadataStore: metadataStore, shoppingDetails: details)
                // An older fetch must not replace this in-place quantity edit.
                taskFetchGeneration &+= 1
                taskRefresh = nil
            }
            if completionChanged {
                let completes = ["Paid", "Canceled", "Packed", "Finished"].contains(stage)
                if current.isCompleted != completes { try reminderService.setCompleted(completes, task: current, metadataStore: metadataStore) }
            }
            setSpecializedDetails(details, for: current)
            if type == .shopping { rememberShoppingEstimate(title: current.title, fields: details.fields) }
            if type == .shopping, let index = tasks.firstIndex(where: { $0.id == current.id }) { tasks[index].sharedShoppingDetails = details }
            offerUndo("Update List Details", previous: [current])
            taskUndo?.specializedPrevious = [current.id: previous]
            if completionChanged {
                await refreshTasks()
                await rescheduleNotifications()
            } else if type == .bills {
                await rescheduleNotifications() // Deadline dates feed reminders.
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func updateListTemplate(_ template: SpecializedListTemplate) {
        guard let index = listTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        var updated = template
        if listProfile(template.listID).type == .routines {
            for index in updated.items.indices { updated.items[index].details.fields["Step Order"] = String(index + 1) }
        }
        listTemplates[index] = updated
        metadataStore.listTemplates = listTemplates
    }
    func deleteListTemplate(_ id: UUID) {
        listTemplates.removeAll { $0.id == id }
        metadataStore.listTemplates = listTemplates
    }
    func moveProjectItems(_ items: [TaskItem], to section: String) {
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

    func setSpecializedField(_ key: String, value: String, for task: TaskItem) async {
        var details = specializedDetails(task)
        details.fields[key] = value
        _ = await saveSpecializedDetails(details, for: task, type: listProfile(task.listID).type)
    }

    func saveListTemplate(listID: String, title: String) {
        let items = tasks.filter { $0.listID == listID && $0.parentID == nil }.map {
            SpecializedListTemplate.Item(title: $0.title, notes: $0.notes, details: specializedDetails($0))
        }
        guard !items.isEmpty else { return }
        listTemplates.append(SpecializedListTemplate(title: title, listID: listID, items: items))
        metadataStore.listTemplates = listTemplates
    }
    func createTemplateRun(_ template: SpecializedListTemplate) async {
        guard lists.contains(where: { $0.id == template.listID }) else { return }
        let previousProfile = listProfile(template.listID)
        let run = Date().formatted(date: .abbreviated, time: .shortened)
        let runID = UUID().uuidString
        var createdAny = false
        var createdIDs: [String] = []
        for (itemIndex, item) in template.items.enumerated() {
            var draft = makeDraft()
            draft.listID = template.listID
            draft.title = item.title
            draft.notes = item.notes
            do {
                let shopping = listProfile(template.listID).type == .shopping
                var details = shopping ? recallingShoppingPrice(title: item.title, details: item.details) : item.details
                let id = try reminderService.saveTask(draft, metadataStore: metadataStore, shoppingDetails: shopping ? details : nil)
                if shopping { rememberShoppingEstimate(title: item.title, fields: details.fields) }
                if listProfile(template.listID).type == .routines { details.fields["Step Order"] = String(itemIndex + 1) }
                details.fields["Stage"] = nil
                details.fields["Progress"] = nil
                details.fields["Last Completed"] = nil
                details.fields["Run"] = run
                details.fields["Run ID"] = runID
                createdAny = true
                createdIDs.append(id)
                specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
                metadataStore.specializedTasks = specializedTasks
            } catch { errorMessage = error.localizedDescription; break }
        }
        let type = listProfile(template.listID).type
        if createdAny && [.routines, .packing, .household].contains(type) {
            var profile = listProfile(template.listID)
            profile.settings["Current Run"] = runID
            setListProfile(profile, for: template.listID)
        }
        if !createdIDs.isEmpty {
            taskRedo = nil
            taskUndo = TaskUndo(message: "Start checklist", previous: [], wasDeleted: false, createdTaskIDs: createdIDs, listProfilesPrevious: [template.listID: previousProfile])
            feedbackSequence += 1
        }
        await refreshTasks()
        await rescheduleNotifications()
    }
    private var shoppingPriceHistory: [String: Double] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(shoppingPriceHistory) { preferences.set(data, forKey: "TaskFlow.shoppingPriceHistory") }
        }
    }
    private func shoppingPriceKey(title: String, fields: [String: String]) -> String {
        ShoppingQuantity.key(title: title, fields: fields) + "\u{001F}" + (Locale.current.currency?.identifier ?? "USD")
    }
    func seedShoppingPriceHistory(from items: [TaskItem]) {
        // Seed older items only when no explicit remembered price exists.
        // Newest records win; a reload must not overwrite a correction.
        for task in items.sorted(by: { ($0.modifiedAt ?? $0.createdAt ?? .distantPast) > ($1.modifiedAt ?? $1.createdAt ?? .distantPast) }) {
            guard listProfile(task.listID).type == .shopping || task.sharedShoppingDetails != nil else { continue }
            let fields = task.sharedShoppingDetails?.fields ?? specializedTasks[task.metadataID]?.fields ?? specializedTasks[task.id]?.fields ?? [:]
            if rememberedShoppingPrice(title: task.title, fields: fields) == nil { rememberShoppingEstimate(title: task.title, fields: fields) }
        }
    }
    func rememberedShoppingPrice(title: String, fields: [String: String]) -> Double? {
        shoppingPriceHistory[shoppingPriceKey(title: title, fields: fields)]
    }
    func rememberShoppingEstimate(title: String, fields: [String: String]) {
        guard let price = Double(fields["Price"] ?? ""), price.isFinite, price >= 0 else { return }
        let key = shoppingPriceKey(title: title, fields: fields)
        if shoppingPriceHistory[key] != price { shoppingPriceHistory[key] = price }
    }
    func recallingShoppingPrice(title: String, details: SpecializedTaskDetails) -> SpecializedTaskDetails {
        var result = details
        if (result.fields["Price"] ?? "").isEmpty, let price = rememberedShoppingPrice(title: title, fields: result.fields) {
            result.fields["Price"] = ShoppingQuantity.text(price)
        }
        return result
    }
    func pricedShoppingSuggestion(_ item: SpecializedListTemplate.Item, store: String) -> SpecializedListTemplate.Item {
        var result = item
        if !store.isEmpty { result.details.fields["Store"] = store }
        if let price = rememberedShoppingPrice(title: result.title, fields: result.details.fields) {
            result.details.fields["Price"] = ShoppingQuantity.text(price)
        }
        return result
    }
    func saveShoppingEstimate(_ price: Double, for task: TaskItem) async -> Bool {
        guard price.isFinite, price >= 0, let current = currentTask(id: task.id) else { return false }
        var details = specializedDetails(current)
        details.fields["Price"] = ShoppingQuantity.text(price)
        guard await saveSpecializedDetails(details, for: current, type: .shopping) else { return false }
        rememberShoppingEstimate(title: current.title, fields: details.fields)
        return true
    }
    var shoppingShopperName = "" {
        didSet {
            preferences.set(shoppingShopperName, forKey: "TaskFlow.shoppingShopperName")
            TaskFlowSharedSettings.shoppingShopperName = shoppingShopperName
            for raw in [oldValue, shoppingShopperName] {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !rememberedShoppingShopperNames.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    rememberedShoppingShopperNames.append(name)
                }
            }
        }
    }
    private(set) var rememberedShoppingShopperNames: [String] = [] {
        didSet { preferences.set(rememberedShoppingShopperNames, forKey: "TaskFlow.shoppingShopperNames") }
    }
    var shoppingShopperChoices: [String] {
        var names: [String] = []
        let incoming = tasks.flatMap { task in
            let fields = specializedDetails(task).fields
            return [fields["Shopper"], fields["Added By"], fields["Purchased By"]].compactMap { $0 }.filter { $0 != "Unnamed shopper" }
        }
        for raw in [shoppingShopperName] + rememberedShoppingShopperNames + incoming {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !names.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    @discardableResult
    func rememberShoppingShopper(_ raw: String) -> String {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return "" }
        let canonical = shoppingShopperChoices.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
        if !rememberedShoppingShopperNames.contains(where: { $0.localizedCaseInsensitiveCompare(canonical) == .orderedSame }) {
            rememberedShoppingShopperNames.append(canonical)
        }
        return canonical
    }
    func selectShoppingShopper(_ raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        shoppingShopperName = shoppingShopperChoices.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
    }
    private var shoppingActor: String {
        let name = shoppingShopperName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unnamed shopper" : String(name.prefix(80))
    }
    private var shoppingQuantityUpdates: Set<String> = []
    func shoppingQuantityIsUpdating(_ id: String) -> Bool { shoppingQuantityUpdates.contains(id) }
    func adjustShoppingQuantity(_ task: TaskItem, by change: Double) async {
        guard !shoppingQuantityUpdates.contains(task.id), !isUndoing,
              let current = currentTask(id: task.id), !current.isCompleted,
              let value = ShoppingQuantity.value(specializedDetails(current).fields["Quantity"]) else { return }
        let next = value + change
        guard next.isFinite, next > 0 else { return }
        shoppingQuantityUpdates.insert(task.id)
        defer { shoppingQuantityUpdates.remove(task.id) }
        var details = specializedDetails(current)
        details.fields["Quantity"] = ShoppingQuantity.text(next)
        _ = await saveSpecializedDetails(details, for: current, type: .shopping)
    }
    func shoppingDuplicate(_ item: SpecializedListTemplate.Item, listID: String, store: String) -> TaskItem? {
        var fields = item.details.fields
        if !store.isEmpty { fields["Store"] = store }
        let key = ShoppingQuantity.key(title: item.title, fields: fields)
        return tasks.first { $0.listID == listID && $0.parentID == nil && !$0.isCompleted && ShoppingQuantity.key(title: $0.title, fields: specializedDetails($0).fields) == key }
    }
    func shoppingHasDuplicates(_ entries: [SpecializedListTemplate.Item], listID: String, store: String) -> Bool {
        var keys: Set<String> = []
        return entries.contains { item in
            var fields = item.details.fields
            if !store.isEmpty { fields["Store"] = store }
            return !keys.insert(ShoppingQuantity.key(title: item.title, fields: fields)).inserted || shoppingDuplicate(item, listID: listID, store: store) != nil
        }
    }
    func shoppingRepeatSuggestions(listID: String) -> [SpecializedListTemplate.Item] {
        let purchased = tasks.filter { $0.listID == listID && $0.parentID == nil && $0.isCompleted }
        let grouped = Dictionary(grouping: purchased) { ShoppingQuantity.key(title: $0.title, fields: specializedDetails($0).fields) }
        return grouped.values.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return (left.compactMap(\.completedAt).max() ?? .distantPast) > (right.compactMap(\.completedAt).max() ?? .distantPast)
        }.prefix(12).compactMap { purchases in
            // Prefer the most common quantity/unit/store combination, breaking ties by recency.
            let variants = Dictionary(grouping: purchases) { specializedDetails($0).fields["Quantity"] ?? "" }
            guard let usual = variants.values.sorted(by: {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.compactMap(\.completedAt).max() ?? .distantPast) > ($1.compactMap(\.completedAt).max() ?? .distantPast)
            }).first?.max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) else { return nil }
            var details = specializedDetails(usual)
            for key in ["Added By", "Added At", "Purchased By", "Purchased At", "Last Completed", "Run", "Run ID"] { details.fields[key] = nil }
            return .init(title: usual.title, notes: usual.notes, details: details)
        }
    }
    func buyAgain(_ task: TaskItem) async {
        let template = SpecializedListTemplate(title: task.title, listID: task.listID, items: [.init(title: task.title, notes: task.notes, details: specializedDetails(task))])
        await createTemplateRun(template)
    }
    func mergeShoppingDuplicates(listID: String) async {
        guard !isUndoing else { return }
        let open = tasks.filter { $0.listID == listID && !$0.isCompleted && $0.parentID == nil }
        let groups = Dictionary(grouping: open) { task in
            let fields = specializedDetails(task).fields
            return [task.title, fields["Store"] ?? "", fields["Unit"] ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "\u{001F}")
        }
        var previous: [TaskItem] = []
        var snapshots: [String: SpecializedTaskDetails] = [:]
        for group in groups.values where group.count > 1 {
            guard let first = group.first else { continue }
            let quantities = group.map { task -> Double? in
                let raw = specializedDetails(task).fields["Quantity"] ?? ""
                return raw.isEmpty ? 1 : Double(raw)
            }
            guard quantities.allSatisfy({ value in guard let value else { return false }; return value.isFinite && value > 0 }) else { continue }
            var total = quantities[0] ?? 1
            var merged: [TaskItem] = []
            for (index, duplicate) in group.dropFirst().enumerated() {
                let nextTotal = total + (quantities[index + 1] ?? 1)
                guard nextTotal.isFinite else { continue }
                do {
                    try reminderService.setCompleted(true, task: duplicate, metadataStore: metadataStore)
                    total = nextTotal
                    merged.append(duplicate)
                } catch { errorMessage = error.localizedDescription }
            }
            guard !merged.isEmpty, total.isFinite else { continue }
            snapshots[first.metadataID] = specializedDetails(first)
            var details = specializedDetails(first)
            details.fields["Quantity"] = String(total)
            setSpecializedDetails(details, for: first)
            previous.append(contentsOf: [first] + merged)
        }
        offerUndo("Merge Shopping Items", previous: previous)
        taskUndo?.specializedPrevious = snapshots
        await refreshTasks()
        await rescheduleNotifications()
    }

    func scheduleNextChore(_ task: TaskItem) async -> String? {
        guard task.recurrence == nil, let days = specializedDetails(task).repeatAfterDays, (1...3650).contains(days) else { return nil }
        var draft = TaskDraft(task: task)
        draft.reminderID = nil
        draft.title = task.title
        draft.isCompleted = false
        draft.status = .notStarted
        draft.recurrence = nil
        draft.dueDate = Calendar.current.date(byAdding: .day, value: days, to: Date())
        do {
            let id = try reminderService.saveTask(draft, metadataStore: metadataStore)
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = specializedDetails(task)
            metadataStore.specializedTasks = specializedTasks
            return id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    var listIcons: [String: String] = [:]
    static let listIconChoices = ["list.bullet", "briefcase", "house", "cart", "heart", "pills", "book", "person.2", "airplane", "graduationcap", "star", "folder", "wrench.and.screwdriver", "leaf", "music.note", "sportscourt"]

    func listIcon(for id: String) -> String { listIcons[id] ?? "list.bullet" }

    func setListIcon(_ icon: String, for id: String) {
        guard Self.listIconChoices.contains(icon) else { return }
        listIcons[id] = icon
        preferences.set(listIcons, forKey: "TaskFlow.listIcons")
        scheduleCloudSync()
    }

    var lists: [TaskList] = [] { didSet { taskFilterRevision &+= 1 } }
    var savedTags: [SavedTag] = []
    var quickNotes: [QuickNote] = [] {
        didSet {
            guard oldValue != quickNotes else { return }
            notesRevision &+= 1
            let shared = quickNotes.map(TaskFlowSharedNote.init(note:))
            guard shared != oldValue.map(TaskFlowSharedNote.init(note:)) else { return }
            TaskFlowSharedNotes.save(shared)
        }
    }
    var eventTags: [String: [String]] = [:]
    var excludedAvailabilityCalendarIDs: Set<String> = [] {
        didSet {
            preferences.set(excludedAvailabilityCalendarIDs.sorted(), forKey: "TaskFlow.excludedAvailabilityCalendarIDs")
            scheduleCloudSync()
        }
    }

    func calendarAffectsAvailability(_ id: String) -> Bool {
        !excludedAvailabilityCalendarIDs.contains(id)
    }

    func setCalendarAffectsAvailability(_ calendar: EventCalendar, _ enabled: Bool) {
        if enabled { excludedAvailabilityCalendarIDs.remove(calendar.id) }
        else { excludedAvailabilityCalendarIDs.insert(calendar.id) }
    }

    func availabilityEvents(from events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { calendarAffectsAvailability($0.calendarID) }
    }

    var calendarEvents: [CalendarEvent] = []
    var eventCalendars: [EventCalendar] = []

    var selectedTaskID: String?
    var selectedScope: TaskScope = .all
    var selectedListID: String?
    var selectedSmartListID: String?
    var searchQuery = ""

    var dueFilter: DueFilter = .any { didSet { preferences.set(dueFilter.rawValue, forKey: "TaskFlow.dueFilter"); scheduleCloudSync() } }
    var selectedTagFilter: TagFilter? { didSet { preferences.set(try? JSONEncoder().encode(selectedTagFilter), forKey: "TaskFlow.selectedTagFilter"); scheduleCloudSync() } }
    var includeCompletedTasks = false { didSet { preferences.set(includeCompletedTasks, forKey: "TaskFlow.includeCompletedTasks"); scheduleCloudSync() } }

    var quickTagFilter: TagFilter? = nil { didSet { preferences.set(try? JSONEncoder().encode(quickTagFilter), forKey: "TaskFlow.quickTagFilter"); scheduleCloudSync() } }
    var quickStatusFilter: TaskStatus? = nil { didSet { preferences.set(quickStatusFilter?.rawValue, forKey: "TaskFlow.quickStatusFilter"); scheduleCloudSync() } }
    var quickPriorityFilter: TaskPriority? = nil { didSet { preferences.set(quickPriorityFilter?.rawValue, forKey: "TaskFlow.quickPriorityFilter"); scheduleCloudSync() } }
    var quickDueFilter: DueFilter = .any { didSet { preferences.set(quickDueFilter.rawValue, forKey: "TaskFlow.quickDueFilter"); scheduleCloudSync() } }

    var isFocusModeEnabled = false
    var isLoading = false

    var taskGroupOption: TaskGroupOption = .none { didSet { preferences.set(taskGroupOption.rawValue, forKey: "TaskFlow.taskGroupOption"); scheduleCloudSync() } }
    var taskSortOption: TaskSortOption = .dueDate { didSet { preferences.set(taskSortOption.rawValue, forKey: "TaskFlow.taskSortOption"); scheduleCloudSync() } }
    var taskSortDirection: TaskSortDirection = .ascending { didSet { preferences.set(taskSortDirection.rawValue, forKey: "TaskFlow.taskSortDirection"); scheduleCloudSync() } }

    var appearanceMode: AppearanceMode = .system { didSet { preferences.set(appearanceMode.rawValue, forKey: "TaskFlow.appearanceMode"); scheduleCloudSync() } }
    var appTheme: AppTheme = .system {
        didSet {
            preferences.set(appTheme.rawValue, forKey: "TaskFlow.appTheme")
            scheduleCloudSync()
            TaskFlowSharedSettings.theme = appTheme.sharedTheme
        }
    }
    var taskDensity: TaskDensity = .comfortable { didSet { preferences.set(taskDensity.rawValue, forKey: "TaskFlow.taskDensity"); scheduleCloudSync() } }
    var taskViewMode: TaskViewMode = .list { didSet { preferences.set(taskViewMode.rawValue, forKey: "TaskFlow.taskViewMode"); scheduleCloudSync() } }

    var defaultListID: String = "" { didSet { preferences.set(defaultListID, forKey: "TaskFlow.defaultListID"); scheduleCloudSync() } }
    var defaultEventCalendarID: String = "" { didSet { preferences.set(defaultEventCalendarID, forKey: "TaskFlow.defaultEventCalendarID"); scheduleCloudSync() } }
    var selectedEventCalendarIDs: Set<String> = [] {
        didSet {
            preferences.set(Array(selectedEventCalendarIDs), forKey: TaskFlowSharedSettings.selectedEventCalendarIDsKey)
            TaskFlowSharedSettings.defaults.set(Array(selectedEventCalendarIDs), forKey: TaskFlowSharedSettings.selectedEventCalendarIDsKey)
        }
    }

    var eventAccessState: EventAccessState = .unknown
    var notificationStatus: NotificationStatus = .unknown
    var notificationsEnabled = true {
        didSet {
            preferences.set(notificationsEnabled, forKey: "TaskFlow.notificationsEnabled")
            Task { await rescheduleNotifications() }
        }
    }

    var errorMessage: String?
    var isSyncing = false
    var pinnedListIDs: Set<String> = []
    var pinnedItemOrder: [String] = []
    var smartLists: [SmartListDefinition] = [] { didSet { taskFilterRevision &+= 1 } }

    private let reminderService = EventKitReminderService()
    private let metadataStore: MetadataStore
    private let cloudSync = CloudMetadataSyncService()
    private var cloudSyncEnabled = false
    private var cloudSyncTask: Task<Void, Never>?
    private var isApplyingCloudSnapshot = false
    private var isCloudSyncRunning = false
    private var hasPendingCloudSync = false
    private var cloudPreferencesObserver: NSObjectProtocol?
    @ObservationIgnored private var cloudPreferencesCapture: Task<Void, Never>?
    var cloudSyncStatus = "Not synced yet"
    private static let syncedPreferenceKeys = [
        "TaskFlow.appTheme", "TaskFlow.appearanceMode", "TaskFlow.taskDensity",
        "TaskFlow.taskViewMode", "TaskFlow.taskGroupOption", "TaskFlow.taskSortOption",
        "TaskFlow.taskSortDirection", "TaskFlow.listIcons", "TaskFlow.includeCompletedTasks",
        "TaskFlow.dueFilter", "TaskFlow.quickDueFilter", "TaskFlow.quickStatusFilter",
        "TaskFlow.quickPriorityFilter", "TaskFlow.selectedTagFilter", "TaskFlow.quickTagFilter",
        "TaskFlow.calendar.workspace", "TaskFlow.calendar.savedContexts", "TaskFlow.excludedAvailabilityCalendarIDs"
    ]

    private func scheduleCloudSync() {
        guard cloudSyncEnabled, !isApplyingCloudSnapshot else { return }
        if isCloudSyncRunning { hasPendingCloudSync = true; return }
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.synchronizeCloud()
        }
    }

    static func equivalentSyncedSettings(_ lhs: [String: Data], _ rhs: [String: Data]) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { key, data in
            guard let other = rhs[key] else { return false }
            if data == other { return true }
            guard let left = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSObject,
                  let right = try? PropertyListSerialization.propertyList(from: other, options: [], format: nil) as? NSObject else { return false }
            return left == right
        }
    }

    private func captureCloudSettings() {
        var values: [String: Data] = [:]
        let previous = metadataStore.currentSnapshot().syncedSettings
        for key in Self.syncedPreferenceKeys {
            if let value = preferences.object(forKey: key),
               let data = try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0) {
                if let oldData = previous[key],
                   let old = try? PropertyListSerialization.propertyList(from: oldData, options: [], format: nil) as? [String: Any],
                   (old["value"] as? NSObject) == (value as? NSObject) {
                    values[key] = oldData
                } else { values[key] = data }
            }
        }
        metadataStore.setSyncedSettings(values)
    }

    func synchronizeCloud() async {
        guard !isCloudSyncRunning else { scheduleCloudSync(); return }
        isCloudSyncRunning = true
        defer {
            isCloudSyncRunning = false
            if hasPendingCloudSync { hasPendingCloudSync = false; scheduleCloudSync() }
        }
        isApplyingCloudSnapshot = true
        captureCloudSettings()
        isApplyingCloudSnapshot = false
        let listIdentities = reminderService.cloudListIdentities()
        let localIDs = Dictionary(listIdentities.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let calendarIdentities = reminderService.cloudEventCalendarIdentities()
        let localCalendarIDs = Dictionary(calendarIdentities.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let sent = metadataStore.currentSnapshot().remappingListIDs(listIdentities).remappingCalendarIDs(calendarIdentities)
        cloudSyncStatus = "Syncing…"
        do {
            let received = try await cloudSync.synchronize(local: sent).remappingListIDs(localIDs).remappingCalendarIDs(localCalendarIDs)
            // Never overwrite edits made while the network request was in flight.
            let merged = try metadataStore.currentSnapshot().merging(received)
            let metadataChanged = merged != metadataStore.currentSnapshot()
            let settingsChanged = !Self.equivalentSyncedSettings(merged.syncedSettings, metadataStore.currentSnapshot().syncedSettings)
            isApplyingCloudSnapshot = true
            if metadataChanged { metadataStore.replace(with: merged) }
            if settingsChanged {
            for key in Self.syncedPreferenceKeys where merged.syncedSettings[key] == nil && merged.fieldUpdatedAt["syncedSettings/" + key] != nil {
                preferences.removeObject(forKey: key)
            }
            for (key, data) in merged.syncedSettings where Self.syncedPreferenceKeys.contains(key) {
                if let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    preferences.set(values["value"], forKey: key)
                }
            }
            appearanceMode = AppearanceMode(rawValue: preferences.string(forKey: "TaskFlow.appearanceMode") ?? "") ?? .system
            appTheme = (AppTheme(rawValue: preferences.string(forKey: "TaskFlow.appTheme") ?? "") ?? .system).canonical
            taskDensity = TaskDensity(rawValue: preferences.string(forKey: "TaskFlow.taskDensity") ?? "") ?? .comfortable
            taskViewMode = TaskViewMode(rawValue: preferences.string(forKey: "TaskFlow.taskViewMode") ?? "") ?? .list
            taskGroupOption = TaskGroupOption(rawValue: preferences.string(forKey: "TaskFlow.taskGroupOption") ?? "") ?? .none
            taskSortOption = TaskSortOption(rawValue: preferences.string(forKey: "TaskFlow.taskSortOption") ?? "") ?? .dueDate
            taskSortDirection = TaskSortDirection(rawValue: preferences.string(forKey: "TaskFlow.taskSortDirection") ?? "") ?? .ascending
            listIcons = preferences.dictionary(forKey: "TaskFlow.listIcons") as? [String: String] ?? [:]
            excludedAvailabilityCalendarIDs = Set(preferences.stringArray(forKey: "TaskFlow.excludedAvailabilityCalendarIDs") ?? [])
            includeCompletedTasks = preferences.bool(forKey: "TaskFlow.includeCompletedTasks")
            dueFilter = DueFilter(rawValue: preferences.string(forKey: "TaskFlow.dueFilter") ?? "") ?? .any
            quickDueFilter = DueFilter(rawValue: preferences.string(forKey: "TaskFlow.quickDueFilter") ?? "") ?? .any
            quickStatusFilter = TaskStatus(rawValue: preferences.string(forKey: "TaskFlow.quickStatusFilter") ?? "")
            quickPriorityFilter = TaskPriority(rawValue: preferences.string(forKey: "TaskFlow.quickPriorityFilter") ?? "")
            selectedTagFilter = preferences.data(forKey: "TaskFlow.selectedTagFilter").flatMap { try? JSONDecoder().decode(TagFilter.self, from: $0) }
            quickTagFilter = preferences.data(forKey: "TaskFlow.quickTagFilter").flatMap { try? JSONDecoder().decode(TagFilter.self, from: $0) }
            }
            isApplyingCloudSnapshot = false
            // Publish synced links/text before binary downloads; an unavailable
            // photo or document must not hide an already-merged note.
            if metadataChanged { await loadAllData() }
            try await cloudSync.uploadAttachments(metadataStore.localAttachmentUploads())
            let downloaded = try await cloudSync.downloadAttachments(metadataStore.missingCloudAttachmentDownloads())
            if downloaded > 0 {
                attachmentContentRevision &+= 1
                await loadAllData()
            }
            cloudSyncStatus = "Synced"
            if merged != received { scheduleCloudSync() }
        } catch {
            isApplyingCloudSnapshot = false
            cloudSyncStatus = "Sync unavailable: " + error.localizedDescription
        }
    }

    private let preferences: UserDefaults
    private var loadingTask: Task<Void, Never>?
    private var taskRefresh: Task<[TaskItem], Never>?
    private var taskFetchGeneration = 0
    private var hasLoadedInitialData = false
    private let notificationScheduler = NotificationScheduler()
    private let dueTodayActivity = DueTodayLiveActivityCoordinator()

    /// Opt-in Lock Screen Live Activity listing today's tasks.
    var showsDueTodayLiveActivity = false {
        didSet {
            preferences.set(showsDueTodayLiveActivity, forKey: "TaskFlow.showsDueTodayLiveActivity")
            Task { await syncDueTodayActivity() }
        }
    }

    /// List IDs allowed by the active Focus filter; empty when no filter applies.
    var focusListIDs: Set<String> {
        Set(TaskFlowSharedSettings.defaults.stringArray(forKey: TaskFlowSharedSettings.focusListIDsKey) ?? [])
    }

    var isFocusFilterActive: Bool { !focusListIDs.isEmpty }

    private func visibleLists() -> [TaskList] {
        let all = reminderService.loadLists()
        let allowed = focusListIDs
        guard !allowed.isEmpty else { return all }
        let filtered = all.filter { allowed.contains($0.id) }
        return filtered.isEmpty ? all : filtered
    }

    private func refreshTasks(force: Bool = true) async {
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

    private func loadVisibleTasks() async -> [TaskItem] {
        let all = await reminderService.loadTasks(metadataStore: metadataStore)
        let allowed = focusListIDs
        guard !allowed.isEmpty, all.contains(where: { allowed.contains($0.listID) }) else { return all }
        return all.filter { allowed.contains($0.listID) }
    }

    private var lastActivityTasks: [TaskItem]?
    private var lastActivityLists: [TaskList]?
    private var lastActivityDay: Date?
    private var lastActivityEnabled: Bool?

    private func syncDueTodayActivity() async {
        let day = Calendar.current.startOfDay(for: Date())
        let enabled = showsDueTodayLiveActivity && accessState == .granted
        guard lastActivityTasks != tasks || lastActivityLists != lists || lastActivityDay != day || lastActivityEnabled != enabled else { return }
        lastActivityTasks = tasks; lastActivityLists = lists; lastActivityDay = day; lastActivityEnabled = enabled
        if showsDueTodayLiveActivity && accessState == .granted {
            await dueTodayActivity.sync(tasks: tasks, lists: lists)
        } else {
            await dueTodayActivity.endCurrentActivity()
        }
    }

    var accessState: ReminderAccessState = .unknown
    var noteDrafts: [NoteEditorRecovery] = []
    private var draftWriteGeneration = 0
    var pendingNoteCapture: TaskFlowNoteCaptureMode?
    var pendingOpenNoteID: UUID?
    var pendingOpenListID: String?
    var pendingOpenTaskID: String?
    var hasCompletedOnboarding: Bool

    init(preferences: UserDefaults = .standard, metadataStore: MetadataStore = MetadataStore()) {
        self.preferences = preferences
        if let data = preferences.data(forKey: "TaskFlow.shoppingPriceHistory") { shoppingPriceHistory = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:] }
        rememberedShoppingShopperNames = preferences.stringArray(forKey: "TaskFlow.shoppingShopperNames") ?? []
        shoppingShopperName = (preferences.string(forKey: "TaskFlow.shoppingShopperName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        TaskFlowSharedSettings.shoppingShopperName = preferences.string(forKey: "TaskFlow.shoppingShopperName") ?? ""
        self.noteDrafts = metadataStore.loadNoteDrafts()
        self.metadataStore = metadataStore
        savedTags = metadataStore.savedTags
        eventTags = metadataStore.eventTags
        let savedPinnedOrder = metadataStore.pinnedListIDs
        let seededOrder = Self.seededPinnedOrder(savedPinnedOrder)
        pinnedItemOrder = seededOrder
        pinnedListIDs = Set(seededOrder.filter { !Self.isBuiltInPinnedID($0) })

        quickNotes = metadataStore.quickNotes
        smartLists = metadataStore.smartLists
        listProfiles = metadataStore.listProfiles
        specializedTasks = metadataStore.specializedTasks
        listTemplates = metadataStore.listTemplates
        dueFilter = DueFilter(rawValue: preferences.string(forKey: "TaskFlow.dueFilter") ?? "") ?? .any
        quickDueFilter = DueFilter(rawValue: preferences.string(forKey: "TaskFlow.quickDueFilter") ?? "") ?? .any
        quickStatusFilter = TaskStatus(rawValue: preferences.string(forKey: "TaskFlow.quickStatusFilter") ?? "")
        quickPriorityFilter = TaskPriority(rawValue: preferences.string(forKey: "TaskFlow.quickPriorityFilter") ?? "")
        selectedTagFilter = preferences.data(forKey: "TaskFlow.selectedTagFilter").flatMap { try? JSONDecoder().decode(TagFilter.self, from: $0) }
        quickTagFilter = preferences.data(forKey: "TaskFlow.quickTagFilter").flatMap { try? JSONDecoder().decode(TagFilter.self, from: $0) }
        listIcons = preferences.dictionary(forKey: "TaskFlow.listIcons") as? [String: String] ?? [:]
        excludedAvailabilityCalendarIDs = Set(preferences.stringArray(forKey: "TaskFlow.excludedAvailabilityCalendarIDs") ?? [])
        hasCompletedOnboarding = preferences.bool(forKey: "TaskFlow.hasCompletedOnboarding")
        appearanceMode = AppearanceMode(rawValue: preferences.string(forKey: "TaskFlow.appearanceMode") ?? "") ?? .system
        appTheme = (AppTheme(rawValue: preferences.string(forKey: "TaskFlow.appTheme") ?? "") ?? .system).canonical
        taskDensity = TaskDensity(rawValue: preferences.string(forKey: "TaskFlow.taskDensity") ?? "") ?? .comfortable
        taskViewMode = TaskViewMode(rawValue: preferences.string(forKey: "TaskFlow.taskViewMode") ?? "") ?? .list
        taskGroupOption = TaskGroupOption(rawValue: preferences.string(forKey: "TaskFlow.taskGroupOption") ?? "") ?? .none
        taskSortOption = TaskSortOption(rawValue: preferences.string(forKey: "TaskFlow.taskSortOption") ?? "") ?? .dueDate
        taskSortDirection = TaskSortDirection(rawValue: preferences.string(forKey: "TaskFlow.taskSortDirection") ?? "") ?? .ascending

        defaultListID = preferences.string(forKey: "TaskFlow.defaultListID") ?? ""
        defaultEventCalendarID = preferences.string(forKey: "TaskFlow.defaultEventCalendarID") ?? ""
        includeCompletedTasks = preferences.bool(forKey: "TaskFlow.includeCompletedTasks")
        notificationsEnabled = preferences.object(forKey: "TaskFlow.notificationsEnabled") as? Bool ?? true
        showsDueTodayLiveActivity = preferences.bool(forKey: "TaskFlow.showsDueTodayLiveActivity")
        selectedEventCalendarIDs = Set(preferences.stringArray(forKey: TaskFlowSharedSettings.selectedEventCalendarIDsKey) ?? [])
    }

    /// Scroll anchors and comment drafts write preferences continuously; coalesce
    /// them so scrolling and typing do not re-encode every synced setting.
    private func preferencesDidChange() {
        cloudPreferencesCapture?.cancel()
        cloudPreferencesCapture = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, !self.isApplyingCloudSnapshot else { return }
            // Ignore unrelated device-only preferences and unchanged synced values.
            let before = self.metadataStore.currentSnapshot().syncedSettings
            self.isApplyingCloudSnapshot = true
            self.captureCloudSettings()
            self.isApplyingCloudSnapshot = false
            if before != self.metadataStore.currentSnapshot().syncedSettings { self.scheduleCloudSync() }
        }
    }

    func bootstrap() async {
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
        selectedScope = .list(task.listID)
        selectedTaskID = id
    }

    func consumeWidgetCompletions() async {
        guard accessState == .granted else { return }
        let ids = TaskFlowSharedWidgetActions.consumeCompletedReminderIDs()
        guard !ids.isEmpty else { return }
        // Widgets already update EventKit; refresh instead of toggling completion again.
        await reload()
    }

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
        var ids = pinnedItemIDs
        let moving = fromOffsets.sorted().map { ids[$0] }
        for index in fromOffsets.sorted(by: >) { ids.remove(at: index) }
        let insertion = max(0, min(ids.count, toOffset - fromOffsets.filter { $0 < toOffset }.count))
        ids.insert(contentsOf: moving, at: insertion)
        pinnedItemOrder = ids
        metadataStore.pinnedListIDs = ids
    }

    private static func seededPinnedOrder(_ stored: [String]) -> [String] {
        var order = stored
        if !order.contains(PinnedTaskIdentifier.allTasks) { order.insert(PinnedTaskIdentifier.allTasks, at: 0) }
        if !order.contains(PinnedTaskIdentifier.upNext) { order.insert(PinnedTaskIdentifier.upNext, at: min(1, order.count)) }
        return order
    }

    private static func isBuiltInPinnedID(_ id: String) -> Bool {
        id == PinnedTaskIdentifier.allTasks || id == PinnedTaskIdentifier.upNext
    }

    func updateList(id: String, title: String, color: Color) async -> Bool {
        do {
            try reminderService.updateList(id: id, title: title, color: color)
            await reload()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func createList(named name: String) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try reminderService.createList(named: title)
            lists = visibleLists()
        } catch {
            errorMessage = error.localizedDescription
        }
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
            errorMessage = error.localizedDescription
        }
    }

    func taskCount(for scope: TaskScope) -> Int {
        applyScope(tasks.filter { includeCompletedTasks || !$0.isCompleted || scope == .completed }, scope: scope).count
    }

    func moveOverdueTasksToTomorrowMorning() async {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
              let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) else { return }
        await setDueDates(morning, for: overdueTasks)
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

    var nextFocusEvent: CalendarEvent? {
        calendarEvents.first { $0.startDate > Date() }
    }

    func dayTimeGaps(on date: Date = Date()) -> [DayTimeGap] {
        var gaps: [DayTimeGap] = []
        let cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 18, minute: 0, second: 0, of: date) ?? date.addingTimeInterval(3600 * 4)
        if endOfDay > date {
            gaps.append(DayTimeGap(start: date, end: endOfDay, nextTitle: nextFocusEvent?.title))
        }
        return gaps
    }

    func dayTimeGaps() -> [DayTimeGap] {
        dayTimeGaps(on: Date())
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

    var visibleTaskCount: Int {
        filteredTasks.count
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

    private var taskFilterRevision = 0
    @ObservationIgnored private var taskFilterCacheKey: [String] = []
    @ObservationIgnored private var taskFilterCacheResult: [TaskItem] = []
    @ObservationIgnored private var taskFilterCacheExpiry = Date.distantPast

    private func filteredTaskItems(includeCompleted: Bool, completedOnly: Bool = false) -> [TaskItem] {
        let now = Date()
        let key = [String(taskFilterRevision), String(reflecting: selectedScope), searchQuery,
                   String(reflecting: selectedTagFilter), String(reflecting: quickTagFilter),
                   String(reflecting: quickStatusFilter), String(reflecting: quickPriorityFilter),
                   dueFilter.rawValue, quickDueFilter.rawValue, taskSortOption.rawValue,
                   taskSortDirection.rawValue, String(includeCompleted), String(completedOnly),
                   TimeZone.current.identifier, String(reflecting: Calendar.current.identifier), defaultListID]
        if taskFilterCacheKey == key && now < taskFilterCacheExpiry { return taskFilterCacheResult }
        let interval = TaskFlowPerformance.begin("Task filtering")
        defer { TaskFlowPerformance.end("Task filtering", interval) }
        let result = calculateFilteredTaskItems(includeCompleted: includeCompleted, completedOnly: completedOnly)
        taskFilterCacheKey = key
        taskFilterCacheResult = result
        taskFilterCacheExpiry = min(now.addingTimeInterval(30), tasks.compactMap(\.dueDate).filter { $0 > now }.min() ?? now.addingTimeInterval(30))
        return result
    }

    private func calculateFilteredTaskItems(includeCompleted: Bool, completedOnly: Bool) -> [TaskItem] {
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

    @ObservationIgnored private var groupCacheKey: [String] = []
    @ObservationIgnored private var groupCacheResult: [TaskGroup] = []
    @ObservationIgnored private var groupCacheExpiry = Date.distantPast

    var groupedTasks: [TaskGroup] { cachedGroups(rootsOnly: false) }
    var groupedRootTasks: [TaskGroup] { cachedGroups(rootsOnly: true) }

    private func cachedGroups(rootsOnly: Bool) -> [TaskGroup] {
        let items = filteredTasks
        let key = taskFilterCacheKey + [taskGroupOption.rawValue, String(rootsOnly)]
        if key == groupCacheKey && Date() < groupCacheExpiry { return groupCacheResult }
        let result = calculateGroups(rootsOnly ? items.filter { $0.parentID == nil } : items)
        groupCacheKey = key
        groupCacheExpiry = taskFilterCacheExpiry
        groupCacheResult = result
        return result
    }

    private func calculateGroups(_ list: [TaskItem]) -> [TaskGroup] {
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

    var filteredCalendarEvents: [CalendarEvent] {
        var result = calendarEvents
        let tagFilter = quickTagFilter ?? selectedTagFilter
        if let tagFilter {
            switch tagFilter {
            case .tag(let tag): result = result.filter { $0.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
            case .noTags: result = result.filter { $0.tags.isEmpty }
            }
        }
        guard isSearchActive else { return result }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendarTitles = Dictionary(eventCalendars.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return result.filter { event in
            event.title.localizedCaseInsensitiveContains(q) ||
            (event.location?.localizedCaseInsensitiveContains(q) ?? false) ||
            (event.notes?.localizedCaseInsensitiveContains(q) ?? false) ||
            event.tags.contains { $0.localizedCaseInsensitiveContains(q) } ||
            (calendarTitles[event.calendarID]?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var writableEventCalendars: [EventCalendar] {
        eventCalendars.filter(\.allowsModifications)
    }

    func selectTask(_ task: TaskItem?) {
        selectedTaskID = task?.id
    }

    func clearQuickFilters() {
        quickTagFilter = nil
        quickStatusFilter = nil
        quickPriorityFilter = nil
        quickDueFilter = .any
    }

    func color(forTag tag: String) -> Color {
        if let saved = savedTags.first(where: { $0.name.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            return saved.color.color
        }
        return MetadataSnapshot.defaultColor(for: tag).color
    }

    struct TaskUndo: Identifiable {
        let id = UUID()
        let message: String
        var previous: [TaskItem]
        let wasDeleted: Bool
        var specializedPrevious: [String: SpecializedTaskDetails] = [:]
        var createdTaskIDs: [String] = []
        var listProfilesPrevious: [String: SpecializedListProfile] = [:]
    }
    var taskUndo: TaskUndo?
    var taskRedo: TaskUndo?
    var isUndoing = false
    var feedbackSequence = 0

    func scrollAnchor(for scope: TaskScope) -> String? {
        preferences.string(forKey: "TaskFlow.scroll.\(scope.id)")
    }

    func saveScrollAnchor(_ id: String, for scope: TaskScope) {
        let key = "TaskFlow.scroll.\(scope.id)"
        if preferences.string(forKey: key) != id { preferences.set(id, forKey: key) }
    }

    func commentDraft(for taskID: String) -> String {
        preferences.string(forKey: "TaskFlow.commentDraft.\(taskID)") ?? ""
    }

    func saveCommentDraft(_ text: String, for taskID: String) {
        let key = "TaskFlow.commentDraft.\(taskID)"
        if text.isEmpty { preferences.removeObject(forKey: key) }
        else { preferences.set(text, forKey: key) }
    }

    func dismissUndo() { taskUndo = nil }

    private func offerUndo(_ message: String, previous: [TaskItem], deleted: Bool = false) {
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
                    _ = try reminderService.saveTask(TaskDraft(task: previous), metadataStore: metadataStore, shoppingDetails: details)
                }
                restoredCount += 1
            }
            for id in action.createdTaskIDs { try reminderService.deleteTask(id: id, metadataStore: metadataStore) }
            for (id, details) in action.specializedPrevious { specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details }
            if !action.specializedPrevious.isEmpty { metadataStore.specializedTasks = specializedTasks }
            for (id, profile) in action.listProfilesPrevious { setListProfile(profile, for: id) }
            if taskUndo?.id == action.id { taskUndo = nil }
            if !action.wasDeleted && action.createdTaskIDs.isEmpty && action.specializedPrevious.isEmpty && current.count == action.previous.count {
                taskRedo = TaskUndo(message: action.message, previous: current, wasDeleted: false)
            }
            succeeded = true
            feedbackSequence += 1
        } catch {
            if taskUndo?.id == action.id { taskUndo?.previous = Array(action.previous.dropFirst(restoredCount)) }
            errorMessage = "Could not undo: " + error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    func setDueDate(_ date: Date?, for task: TaskItem) async {
        await setDueDates(date, for: [task])
    }

    private func setDueDates(_ date: Date?, hasDueTime: Bool? = nil, for items: [TaskItem]) async {
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
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    func saveTasks(_ drafts: [TaskDraft]) async -> Bool {
        do {
            try reminderService.saveTasks(drafts, metadataStore: metadataStore)
            await refreshTasks()
            await rescheduleNotifications()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func moveTasks(toListID listID: String, taskIDs ids: Set<String>) async {
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
                errorMessage = error.localizedDescription
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
                    errorMessage = error.localizedDescription
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
                    errorMessage = error.localizedDescription
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

    var previousEventEdit: EventDraft?
    var previousEventBatchIDs: [String] = []
    var eventSaveStatus = ""
    private(set) var lastEventDeletion: EventDeletion?
    private var deletingEventKeys: Set<String> = []
    private(set) var lastSavedEventID: String?
    private(set) var lastAvailabilityEventID: String?
    private var calendarAnchor = Date()

    func showCalendarDate(_ date: Date) async {
        calendarAnchor = date
        await refreshCalendarEvents(invalidateCache: false)
    }

    func undoEventEdit() async {
        do {
            if !previousEventBatchIDs.isEmpty {
                try reminderService.deleteEvents(ids: previousEventBatchIDs)
                previousEventBatchIDs = []
            } else if let previous = previousEventEdit {
                let restoredID = try reminderService.saveEvent(previous)
                metadataStore.setEventTags(previous.tags, for: restoredID)
                eventTags = metadataStore.eventTags
                previousEventEdit = nil
            } else { return }
            eventSaveStatus = "Change undone"
            await refreshCalendarEvents()
        } catch { eventSaveStatus = error.localizedDescription }
    }

    var eventStore: EKEventStore { reminderService.eventStore }

    func systemEvent(for draft: EventDraft) -> EKEvent {
        reminderService.systemEvent(for: draft)
    }

    /// Called when Apple's event editor closes; keeps TaskFlow tags and the calendar list in sync.
    func systemEventEditorDidFinish(savedEventID: String?, tags: [String]) async {
        if let savedEventID {
            metadataStore.setEventTags(tags, for: savedEventID)
            eventTags = metadataStore.eventTags
        }
        await refreshCalendarEvents()
    }

    func deleteCalendarEvent(_ event: CalendarEvent, scope: EventDeletionScope) async -> Bool {
        guard !deletingEventKeys.contains(event.occurrenceKey) else { return false }
        deletingEventKeys.insert(event.occurrenceKey)
        defer { deletingEventKeys.remove(event.occurrenceKey) }
        do {
            try reminderService.deleteEvent(event, scope: scope)
            await eventDeletionDidComplete(EventDeletion(eventID: event.id, startDate: event.startDate, scope: scope))
            return true
        } catch {
            eventSaveStatus = "Could not delete the event: " + error.localizedDescription
            return false
        }
    }

    /// A confirmed native deletion also uses this path; Cancel never emits a
    /// deletion. Publish identity before refreshing so split-view selection and
    /// presented detail screens can release their stale copies immediately.
    func eventDeletionDidComplete(_ deletion: EventDeletion) async {
        calendarEventCache.removeAll()
        calendarCacheOrder.removeAll()
        calendarEvents.removeAll { deletion.includes($0) }
        lastEventDeletion = deletion
        if let previous = previousEventEdit, previous.eventID == deletion.eventID {
            let start = previous.originalStartDate ?? previous.startDate
            if deletion.scope == .thisEvent ? start == deletion.startDate : start >= deletion.startDate {
                previousEventEdit = nil
            }
        }
        previousEventBatchIDs.removeAll { $0 == deletion.eventID }
        eventSaveStatus = "Event deleted"
        await EventLiveActivityCoordinator.end(eventID: deletion.eventID, matching: deletion)
        await refreshCalendarEvents()
    }

    func setEventTags(_ tags: [String], for eventID: String) async {
        metadataStore.setEventTags(tags, for: eventID)
        eventTags = metadataStore.eventTags
        await refreshCalendarEvents()
    }

    func planningEvents(from start: Date, to end: Date) -> [CalendarEvent] {
        conflictCheckEvents(from: start, to: end)
    }

    func makeEventDraft(on date: Date? = nil, startDate: Date? = nil, endDate: Date? = nil) -> EventDraft {
        let start = startDate ?? date ?? Date()
        let end = endDate.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        let calendarID = writableEventCalendars.first(where: { $0.id == defaultEventCalendarID })?.id
            ?? writableEventCalendars.first?.id ?? ""
        return EventDraft(calendarID: calendarID, startDate: start, endDate: end)
    }

    func saveEvents(_ drafts: [EventDraft]) async -> Bool {
        eventSaveStatus = "Saving batch…"
        do {
            previousEventBatchIDs = try reminderService.saveEvents(drafts)
            for (id, draft) in zip(previousEventBatchIDs, drafts) {
                metadataStore.setEventTags(draft.tags, for: id)
            }
            eventTags = metadataStore.eventTags
            previousEventEdit = nil
            eventSaveStatus = "Saved"
            await refreshCalendarEvents()
            return true
        } catch {
            eventSaveStatus = "Could not save: " + error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func availabilityOptions(for calendarID: String) -> [EventAvailability] {
        reminderService.availabilityOptions(calendarID: calendarID)
    }

    func conflictCheckEvents(from start: Date, to end: Date) -> [CalendarEvent] {
        guard eventAccessState == .granted, end > start else { return [] }
        return reminderService.loadEvents(from: start, to: end, calendarIDs: Set(reminderService.loadEventCalendars().map(\.id)).subtracting(excludedAvailabilityCalendarIDs))
    }

    func eventConflicts(for draft: EventDraft, originalStart: Date? = nil) -> [CalendarEvent] {
        guard calendarAffectsAvailability(draft.calendarID) else { return [] }
        let start = draft.isAllDay ? Calendar.current.startOfDay(for: draft.startDate) : draft.startDate
        let end = draft.isAllDay ? (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(draft.endDate, draft.startDate))) ?? draft.endDate) : draft.endDate
        let events = conflictCheckEvents(from: start, to: end)
        return EventConflictChecker.overlaps(start: start, end: end, events: events, excludingID: draft.eventID, excludingStart: originalStart ?? draft.startDate, availability: draft.availability)
    }

    @discardableResult
    func setEventAvailability(_ value: EventAvailability, for event: CalendarEvent) async -> Bool {
        do {
            lastAvailabilityEventID = try reminderService.setAvailability(value, for: event)
            eventSaveStatus = "Availability saved"
            await refreshCalendarEvents()
            return true
        } catch {
            eventSaveStatus = "Could not save: " + error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveEvent(_ draft: EventDraft) async -> Bool {
        eventSaveStatus = "Saving…"
        let previous = calendarEvents.first { $0.id == draft.eventID && (draft.originalStartDate == nil || $0.startDate == draft.originalStartDate) }.map(EventDraft.init(event:))
        do {
            let eventID = try reminderService.saveEvent(draft)
            lastSavedEventID = eventID
            metadataStore.setEventTags(draft.tags, for: eventID)
            eventTags = metadataStore.eventTags
            previousEventEdit = previous
            previousEventBatchIDs = []
            eventSaveStatus = "Saved"
            await refreshCalendarEvents()
            return true
        } catch {
            eventSaveStatus = "Could not save: " + error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func shoppingTask(_ task: TaskItem, matchesStore store: String?) -> Bool {
        guard let store else { return true }
        let actual = (specializedDetails(task).fields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return actual.compare(store.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    func shoppingCustomCategories(listID: String) -> [String] {
        guard let data = listProfile(listID).settings["Shopping Categories"]?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    func shoppingCategories(listID: String) -> [String] {
        let assigned = tasks.filter { $0.listID == listID }.compactMap { specializedDetails($0).fields["Category"] }
        var result: [String] = []
        for raw in ShoppingCatalog.categories + shoppingCustomCategories(listID: listID) + assigned {
            let name = ShoppingCatalog.canonicalCategory(raw)
            if !name.isEmpty, !result.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) { result.append(name) }
        }
        return result
    }
    @discardableResult
    func addShoppingCategory(_ raw: String, listID: String) -> String {
        let name = ShoppingCatalog.canonicalCategory(String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
        guard !name.isEmpty else { return "" }
        if let existing = shoppingCategories(listID: listID).first(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return existing }
        var profile = listProfile(listID)
        var categories = shoppingCustomCategories(listID: listID)
        categories.append(name)
        profile.settings["Shopping Categories"] = String(data: (try? JSONEncoder().encode(categories)) ?? Data(), encoding: .utf8)
        setListProfile(profile, for: listID)
        return name
    }
    func removeShoppingCategory(_ name: String, listID: String) {
        var profile = listProfile(listID)
        let categories = shoppingCustomCategories(listID: listID).filter { $0.localizedCaseInsensitiveCompare(name) != .orderedSame }
        profile.settings["Shopping Categories"] = String(data: (try? JSONEncoder().encode(categories)) ?? Data(), encoding: .utf8)
        setListProfile(profile, for: listID)
    }
    private func shoppingStoreOrderKey(_ store: String?) -> String {
        guard let store else { return "*" }
        return "store:" + store.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private func shoppingCategoryOrders(listID: String) -> [String: [String]] {
        guard let data = listProfile(listID).settings["Shopping Category Orders"]?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
    func shoppingCategoryOrder(listID: String, store: String?) -> [String] {
        let orders = shoppingCategoryOrders(listID: listID)
        let legacy = (listProfile(listID).settings["Aisle Order"] ?? "").split(separator: ",").map(String.init)
        let saved = orders[shoppingStoreOrderKey(store)] ?? orders["*"] ?? legacy
        let available = shoppingCategories(listID: listID)
        var result: [String] = []
        for raw in saved + available {
            let name = ShoppingCatalog.canonicalCategory(raw)
            if available.contains(name), !result.contains(name) { result.append(name) }
        }
        return result
    }
    func setShoppingCategoryOrder(_ categories: [String]?, listID: String, store: String?) {
        var profile = listProfile(listID)
        var orders = shoppingCategoryOrders(listID: listID)
        orders[shoppingStoreOrderKey(store)] = categories
        if store == nil, categories == nil { profile.settings["Aisle Order"] = nil }
        profile.settings["Shopping Category Orders"] = String(data: (try? JSONEncoder().encode(orders)) ?? Data(), encoding: .utf8)
        setListProfile(profile, for: listID)
    }

    func shoppingStores(for listID: String) -> [String] {
        let saved = listProfile(listID).settings["Shopping Stores"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let existing = tasks.filter { $0.listID == listID }.compactMap { specializedDetails($0).fields["Store"] }
        var unique: [String: String] = [:]
        for value in saved + existing {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if unique[key] == nil { unique[key] = name }
        }
        return unique.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func rememberShoppingStore(_ store: String, for listID: String) {
        let name = store.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var values = shoppingStores(for: listID)
        if !values.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { values.append(name) }
        guard let data = try? JSONEncoder().encode(values), let encoded = String(data: data, encoding: .utf8) else { return }
        var profile = listProfile(listID)
        profile.settings["Shopping Stores"] = encoded
        setListProfile(profile, for: listID)
    }

    func addReadingLink(title: String, url: URL, listID: String, metadata: ReadingLinkMetadata? = nil) async -> Bool {
        guard !isUndoing, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        var draft = TaskDraft(listID: listID)
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { return false }
        do {
            let id = try reminderService.saveTask(draft, metadataStore: metadataStore)
            var details = SpecializedTaskDetails()
            details.fields = (metadata?.fields ?? [:]).merging(["Source Link": url.absoluteString, "Progress": "Saved"]) { _, required in required }
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
            metadataStore.specializedTasks = specializedTasks
            taskRedo = nil
            taskUndo = TaskUndo(message: "Save reading link", previous: [], wasDeleted: false, createdTaskIDs: [id])
            feedbackSequence += 1
            await refreshTasks()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Import a reviewed shopping batch with one reload and one undo action.
    /// Open tasks marked Next Action in every Projects list, soonest due first.
    var projectNextActions: [TaskItem] {
        tasks.filter { !$0.isCompleted && listProfile($0.listID).type == .projects && specializedDetails($0).fields["Next Action"] == "Yes" }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
    }

    /// The Reading list shared links go to: the selected one, then the default list, then the first.
    var preferredReadingListID: String? {
        let reading = lists.filter { listProfile($0.id).type == .reading }
        if case .list(let id) = selectedScope, reading.contains(where: { $0.id == id }) { return id }
        return reading.first { $0.id == defaultListID }?.id ?? reading.first?.id
    }

    /// Saves a link shared from another app, filling in its title and details from the page.
    func addSharedReadingLink(_ url: URL) async -> Bool {
        guard let listID = preferredReadingListID else { return false }
        let metadata = await ReadingLinkMetadata.fetch(url)
        let title = metadata?.title.isEmpty == false ? metadata?.title ?? "" : (url.host ?? url.absoluteString)
        return await addReadingLink(title: String(title.prefix(200)), url: url, listID: listID, metadata: metadata)
    }

    func addShoppingItems(_ entries: [ShoppingCaptureItem], listID: String, increaseDuplicates: Bool = false) async -> Int {
        let items = entries.map { item in
            var details = SpecializedTaskDetails()
            details.fields = ["Quantity": item.quantity, "Category": item.category]
            return SpecializedListTemplate.Item(title: item.title, notes: "", details: details)
        }
        return await addShoppingSelection(items, listID: listID, store: listProfile(listID).settings["Store Filter"] ?? listProfile(listID).settings["Last Store"] ?? "", increaseDuplicates: increaseDuplicates)
    }

    /// Saves suggestions and custom entries together, preserving their optional item details.
    func addShoppingSelection(_ entries: [SpecializedListTemplate.Item], listID: String, store: String, increaseDuplicates: Bool = false) async -> Int {
        guard !isUndoing, entries.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return 0 }
        var created: [String] = [], previous: [TaskItem] = []
        var snapshots: [String: SpecializedTaskDetails] = [:]
        var targets: [String: (TaskDraft, SpecializedTaskDetails)] = [:]
        var count = 0
        for item in entries {
            var details = item.details
            if !store.isEmpty { details.fields["Store"] = store }
            details = recallingShoppingPrice(title: item.title, details: details)
            let key = ShoppingQuantity.key(title: item.title, fields: details.fields)
            var draft = TaskDraft(listID: listID)
            draft.title = item.title
            draft.notes = item.notes
            do {
                if increaseDuplicates {
                    if targets[key] == nil, let existing = shoppingDuplicate(item, listID: listID, store: store) {
                        targets[key] = (TaskDraft(task: existing), specializedDetails(existing))
                        previous.append(existing)
                        snapshots[existing.id] = specializedDetails(existing)
                    }
                    if let (existingDraft, existingDetails) = targets[key] {
                        guard let left = ShoppingQuantity.value(existingDetails.fields["Quantity"]), let right = ShoppingQuantity.value(details.fields["Quantity"]), (left + right).isFinite else {
                            errorMessage = "This item has a custom quantity. Keep it separate or edit its quantity first."
                            break
                        }
                        draft = existingDraft
                        details = existingDetails
                        details.fields["Quantity"] = ShoppingQuantity.text(left + right)
                    }
                }
                if draft.reminderID == nil {
                    for field in ["Run", "Run ID", "Last Completed", "Purchased By", "Purchased At"] { details.fields[field] = nil }
                    details.fields["Added By"] = shoppingActor
                    details.fields["Added At"] = Date().ISO8601Format()
                }
                let id = try reminderService.saveTask(draft, metadataStore: metadataStore, shoppingDetails: details)
                if draft.reminderID == nil { created.append(id) }
                draft.reminderID = id
                targets[key] = (draft, details)
                rememberShoppingEstimate(title: draft.title, fields: details.fields)
                specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
                count += 1
            } catch { errorMessage = error.localizedDescription; break }
        }
        if count > 0 {
            metadataStore.specializedTasks = specializedTasks
            rememberShoppingStore(store, for: listID)
            var profile = listProfile(listID)
            profile.settings["Last Store"] = store
            setListProfile(profile, for: listID)
            taskRedo = nil
            taskUndo = TaskUndo(message: "Add shopping items", previous: previous, wasDeleted: false, createdTaskIDs: created)
            taskUndo?.specializedPrevious = snapshots
            feedbackSequence += 1
            await refreshTasks()
            await rescheduleNotifications()
        }
        return count
    }

    func saveShoppingItem(_ draft: TaskDraft, details: SpecializedTaskDetails) async -> Bool {
        guard !isUndoing, !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            let previous = draft.reminderID.flatMap { currentTask(id: $0) }
            let previousDetails = previous.map { specializedDetails($0) }
            var details = previous == nil ? recallingShoppingPrice(title: draft.title, details: details) : details
            if previous == nil {
                details.fields["Added By"] = shoppingActor
                details.fields["Added At"] = Date().ISO8601Format()
            }
            let id = try reminderService.saveTask(draft, metadataStore: metadataStore, shoppingDetails: details)
            rememberShoppingEstimate(title: draft.title, fields: details.fields)
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
            metadataStore.specializedTasks = specializedTasks
            rememberShoppingStore(details.fields["Store"] ?? "", for: draft.listID)
            var profile = listProfile(draft.listID)
            profile.settings["Last Store"] = details.fields["Store"] ?? ""
            setListProfile(profile, for: draft.listID)
            if let previous {
                offerUndo("Shopping item updated", previous: [previous])
                if let previousDetails { taskUndo?.specializedPrevious[previous.id] = previousDetails }
            }
            else { feedbackSequence += 1 }
            await refreshTasks()
            await rescheduleNotifications()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
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
            errorMessage = error.localizedDescription
            return false
        }
    }

    func completedShoppingItemIDs(in listID: String) -> Set<String> {
        guard listProfile(listID).type == .shopping else { return [] }
        return Set(tasks.filter { $0.listID == listID && $0.isCompleted }.map(\.id))
    }

    func clearCompletedShoppingItems(in listID: String, confirmedIDs: Set<String>) async {
        let ids = completedShoppingItemIDs(in: listID).intersection(confirmedIDs)
        guard !ids.isEmpty else { return }
        await clearCompletedTasks(tasks.filter { ids.contains($0.id) })
    }

    func deleteTasks(_ ids: Set<String>) async {
        guard !isUndoing else { return }
        var deleted: [TaskItem] = []
        for task in tasks.filter({ ids.contains($0.id) }) {
            do {
                try reminderService.deleteTask(id: task.id, metadataStore: metadataStore)
                deleted.append(task)
            } catch { errorMessage = error.localizedDescription }
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
            errorMessage = error.localizedDescription
        }
    }

    func makeDraft(parentID: String? = nil) -> TaskDraft {
        let contextID: String?
        if let parentID, let parent = currentTask(id: parentID) {
            contextID = parent.listID
        } else if case .list(let id) = selectedScope {
            contextID = id
        } else {
            contextID = nil
        }
        let listID = lists.first(where: { $0.id == contextID })?.id
            ?? lists.first(where: { $0.id == defaultListID })?.id
            ?? lists.first?.id ?? ""
        var d = TaskDraft(listID: listID)
        d.parentID = parentID
        return d
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

    private func replaceTag(_ oldName: String, with newName: String?) async {
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

    struct NoteUndo {
        let id = UUID()
        let noteID: UUID
        let previous: QuickNote?
        let message: String
    }
    var noteUndo: NoteUndo?
    var noteRedo: NoteUndo?

    private func recordNoteUndo(_ note: QuickNote?, id: UUID, message: String) {
        noteUndo = NoteUndo(noteID: id, previous: note, message: message)
        noteRedo = nil
    }

    func restoreNote(_ action: NoteUndo, isRedo: Bool = false) {
        let inverse = NoteUndo(noteID: action.noteID, previous: quickNotes.first { $0.id == action.noteID }, message: action.message)
        quickNotes.removeAll { $0.id == action.noteID }
        if let previous = action.previous { quickNotes.insert(previous, at: 0) }
        metadataStore.quickNotes = quickNotes
        if isRedo { noteUndo = inverse; noteRedo = nil }
        else { noteRedo = inverse; noteUndo = nil }
    }

    func toggleNotePin(_ note: QuickNote) {
        guard let index = quickNotes.firstIndex(where: { $0.id == note.id }) else { return }
        recordNoteUndo(quickNotes[index], id: note.id, message: "Pin Note")
        quickNotes[index].isPinned.toggle()
        metadataStore.quickNotes = quickNotes
    }

    var noteFolders: [String] {
        Array(Set((quickNotes.map(\.folder) + noteDrafts.map { $0.note.folder })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @discardableResult
    func moveNote(id: UUID, toFolder folder: String) -> Bool {
        guard var note = quickNotes.first(where: { $0.id == id }) else {
            errorMessage = "That note is no longer available."
            return false
        }
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        note.folder = noteFolders.first { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
        return saveNoteSnapshot(note)
    }

    @discardableResult
    func saveNoteSnapshot(_ note: QuickNote, forceCheckpoint: Bool = false) -> Bool {
        var notes = quickNotes
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var comparable = note
            comparable.versions = notes[index].versions
            comparable.updatedAt = notes[index].updatedAt
            guard comparable != notes[index] else { return true }
            recordNoteUndo(notes[index], id: note.id, message: "Edit Note")
            notes[index] = note.versioned(replacing: notes[index], forceCheckpoint: forceCheckpoint)
        } else {
            recordNoteUndo(nil, id: note.id, message: "Create Note")
            notes.insert(note, at: 0)
        }
        metadataStore.quickNotes = notes
        guard metadataStore.persistenceError == nil else { errorMessage = metadataStore.persistenceError; return false }
        quickNotes = metadataStore.quickNotes
        return true
    }

    /// Autosave uses the same ordering and history as explicit Save, with encoding
    /// and atomic file replacement performed by the serial persistence worker.
    func autosaveNoteSnapshot(_ note: QuickNote) async -> Bool {
        var notes = quickNotes
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return false }
        var comparable = note
        comparable.versions = notes[index].versions
        comparable.updatedAt = notes[index].updatedAt
        guard comparable != notes[index] else { return true }
        recordNoteUndo(notes[index], id: note.id, message: "Edit Note")
        notes[index] = note.versioned(replacing: notes[index])
        let saved = await metadataStore.saveQuickNotesAsync(notes)
        if saved { quickNotes = metadataStore.quickNotes }
        else { errorMessage = metadataStore.persistenceError }
        return saved
    }

    func saveNoteDraftAsync(_ draft: NoteEditorRecovery) async -> Bool {
        if let existing = noteDrafts.first(where: { $0.id == draft.id }),
           existing.note == draft.note && existing.originalNoteID == draft.originalNoteID && existing.pendingURL == draft.pendingURL { return true }
        draftWriteGeneration &+= 1
        let generation = draftWriteGeneration
        var drafts = noteDrafts.filter { $0.id != draft.id }
        drafts.insert(draft, at: 0)
        // Publish desired drafts so a simultaneous save of another draft includes
        // the pending one. Discard increments the generation and cannot be undone
        // by a late completion from this write.
        let previousDrafts = noteDrafts
        noteDrafts = drafts
        do {
            try await metadataStore.writeNoteDraftsAsync(drafts)
            return true
        } catch {
            if generation == draftWriteGeneration {
                noteDrafts = previousDrafts
                errorMessage = "Could not recoverably save this draft: " + error.localizedDescription
            }
            return false
        }
    }

    func saveNoteDraft(_ draft: NoteEditorRecovery) -> Bool {
        draftWriteGeneration &+= 1
        var drafts = noteDrafts.filter { $0.id != draft.id }
        drafts.insert(draft, at: 0)
        do { try metadataStore.writeNoteDrafts(drafts); noteDrafts = drafts; return true }
        catch { errorMessage = "Could not recoverably save this draft: " + error.localizedDescription; return false }
    }

    func discardNoteDraft(id: UUID) {
        draftWriteGeneration &+= 1
        let drafts = noteDrafts.filter { $0.id != id }
        do { try metadataStore.writeNoteDrafts(drafts); noteDrafts = drafts }
        catch { errorMessage = error.localizedDescription }
    }

    func restoreNoteVersion(noteID: UUID, revision: NoteRevision) {
        guard let current = quickNotes.first(where: { $0.id == noteID }) else { return }
        var restored = revision.snapshot
        restored.id = noteID
        restored.isPinned = current.isPinned
        _ = saveNoteSnapshot(restored, forceCheckpoint: true)
    }

    func addQuickNote(title: String, text: String, tags: [String], linkedTaskID: String?, linkedEventID: String? = nil, format: QuickNoteFormat = .plain, layout: QuickNoteLayout = .standard, drawingData: Data? = nil, attachments: [TaskAttachment] = []) async {
        let note = QuickNote(title: title, text: text, tags: tags, linkedTaskID: linkedTaskID, linkedEventID: linkedEventID, format: format, layout: layout, drawingData: drawingData, attachments: attachments)
        recordNoteUndo(nil, id: note.id, message: "Create Note")
        var current = quickNotes
        current.insert(note, at: 0)
        quickNotes = current
        metadataStore.quickNotes = current
    }

    func updateQuickNote(_ note: QuickNote, title: String, text: String, tags: [String], linkedTaskID: String?, linkedEventID: String?, format: QuickNoteFormat, layout: QuickNoteLayout, drawingData: Data?, attachments: [TaskAttachment]) async {
        var current = quickNotes
        if let idx = current.firstIndex(where: { $0.id == note.id }) {
            recordNoteUndo(current[idx], id: note.id, message: "Edit Note")
            var updated = current[idx]
            updated.title = title
            updated.text = text
            updated.tags = tags
            updated.linkedTaskID = linkedTaskID
            updated.linkedEventID = linkedEventID
            updated.format = format
            updated.layout = layout
            updated.drawingData = drawingData
            updated.attachments = attachments
            current[idx] = updated.versioned(replacing: current[idx])
            quickNotes = current
            metadataStore.quickNotes = current
        }
    }

    func setNoteChecklistItem(noteID: UUID, itemID: Int, checked: Bool) {
        guard var note = quickNotes.first(where: { $0.id == noteID }), [.checklist, .markdown].contains(note.format) else { return }
        note.text = NoteChecklist.replacing(note.text, itemID: itemID, checked: checked)
        _ = saveNoteSnapshot(note)
    }

    func deleteQuickNote(_ note: QuickNote) async {
        guard let existing = quickNotes.first(where: { $0.id == note.id }) else { return }
        recordNoteUndo(existing, id: note.id, message: "Delete Note")
        var current = quickNotes
        current.removeAll { $0.id == note.id }
        quickNotes = current
        metadataStore.quickNotes = current
    }

    func addComment(_ text: String, to task: TaskItem) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let comment = TaskComment(text: text)
        var updated = currentTask(id: task.id) ?? task
        updated.comments.append(comment)
        updateTaskInMemory(updated)
        var meta = metadataStore.metadata(for: task.id, cloudID: task.metadataID)
        meta.comments = updated.comments
        metadataStore.setMetadata(meta, for: task.metadataID)
    }

    func toggleComment(_ comment: TaskComment, on task: TaskItem) async {
        var updated = currentTask(id: task.id) ?? task
        if let idx = updated.comments.firstIndex(where: { $0.id == comment.id }) {
            updated.comments[idx].isResolved.toggle()
            updateTaskInMemory(updated)
            var meta = metadataStore.metadata(for: task.id, cloudID: task.metadataID)
            meta.comments = updated.comments
            metadataStore.setMetadata(meta, for: task.metadataID)
        }
    }

    func editComment(_ comment: TaskComment, text: String, on task: TaskItem) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = currentTask(id: task.id) ?? task
        guard let index = updated.comments.firstIndex(where: { $0.id == comment.id }),
              updated.comments[index].text != text else { return }
        updated.comments[index].text = text
        updated.comments[index].editedAt = Date()
        saveComments(on: updated)
    }

    func deleteComment(_ comment: TaskComment, on task: TaskItem) async {
        var updated = currentTask(id: task.id) ?? task
        updated.comments.removeAll { $0.id == comment.id }
        saveComments(on: updated)
    }

    private func saveComments(on task: TaskItem) {
        updateTaskInMemory(task)
        var meta = metadataStore.metadata(for: task.id, cloudID: task.metadataID)
        meta.comments = task.comments
        metadataStore.setMetadata(meta, for: task.metadataID)
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

    func importFileAttachmentAsync(from url: URL) async throws -> TaskAttachment {
        try await metadataStore.saveFileAttachmentAsync(sourceURL: url, suggestedName: url.lastPathComponent, kind: .file)
    }

    func importPhotoAttachmentAsync(data: Data, suggestedName: String) async throws -> TaskAttachment {
        try await metadataStore.saveFileAttachmentAsync(data: data, suggestedName: suggestedName, kind: .photo)
    }

    func importFileAttachment(from url: URL) throws -> TaskAttachment {
        let data = try Data(contentsOf: url)
        return try metadataStore.saveFileAttachment(data: data, suggestedName: url.lastPathComponent, kind: .file)
    }

    func importPhotoAttachment(data: Data, suggestedName: String) throws -> TaskAttachment {
        return try metadataStore.saveFileAttachment(data: data, suggestedName: suggestedName, kind: .photo)
    }

    func requestEventCalendarAccess() async {
        _ = await reminderService.requestEventAccess()
        updateCalendarAccessState()
        eventCalendars = eventAccessState == .granted ? reminderService.loadEventCalendars() : []
        await refreshCalendarEvents()
    }

    private func updateCalendarAccessState() {
        switch reminderService.eventAuthorizationState {
        case .unknown: eventAccessState = .unknown
        case .granted: eventAccessState = .granted
        case .denied: eventAccessState = .denied
        case .restricted: eventAccessState = .restricted
        }
    }

    func requestNotificationAccess() async {
        let status = await notificationScheduler.requestAuthorization()
        notificationStatus = status.canSchedule ? .granted : .denied
        notificationsEnabled = status.canSchedule
        await rescheduleNotifications()
    }

    func setEventCalendar(_ calendar: EventCalendar, isSelected: Bool) {
        if isSelected {
            selectedEventCalendarIDs.insert(calendar.id)
        } else {
            selectedEventCalendarIDs.remove(calendar.id)
        }
        Task { await refreshCalendarEvents() }
    }

    private func loadAllData(includeMetadata: Bool = true) async {
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

    private func performLoad(includeMetadata: Bool) async {
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
            await refreshTasks(force: false)
            if let id = pendingOpenTaskID { openTask(id: id) }
        } else {
            lists = []
            tasks = []
        }
        if accessState == .granted {
            TaskFlowSpotlightIndexer.update(tasks: tasks, lists: lists)
        }
        eventCalendars = eventAccessState == .granted ? reminderService.loadEventCalendars() : []
        await refreshCalendarEvents()
        await rescheduleNotifications()
    }

    private func applyMetadata() {
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

    private struct CalendarFetchKey: Hashable {
        let start: Date
        let end: Date
        let calendars: Set<String>
    }
    private var calendarEventCache: [CalendarFetchKey: [CalendarEvent]] = [:]
    private var calendarCacheOrder: [CalendarFetchKey] = []

    private func refreshCalendarEvents(invalidateCache: Bool = true) async {
        let interval = TaskFlowPerformance.begin("Calendar fetch")
        defer { TaskFlowPerformance.end("Calendar fetch", interval) }
        if invalidateCache { calendarEventCache.removeAll(); calendarCacheOrder.removeAll() }
        guard reminderService.eventAuthorizationState == .granted, !selectedEventCalendarIDs.isEmpty else {
            calendarEvents = []
            return
        }
        let now = calendarAnchor
        let cal = Calendar.current
        let start = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let end = cal.date(byAdding: .month, value: 4, to: now) ?? now
        let currentStart = cal.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let currentEnd = cal.date(byAdding: .month, value: 3, to: Date()) ?? Date()
        let ranges = Self.mergedCalendarRanges(DateInterval(start: start, end: end), DateInterval(start: currentStart, end: currentEnd))
        let fetchedEvents = ranges.flatMap { range -> [CalendarEvent] in
            var result: [CalendarEvent] = []
            var start = cal.dateInterval(of: .month, for: range.start)?.start ?? range.start
            while start < range.end {
                guard let end = cal.date(byAdding: .month, value: 1, to: start), end > start else { break }
                let key = CalendarFetchKey(start: start, end: end, calendars: selectedEventCalendarIDs)
                if let cached = calendarEventCache[key] { result += cached }
                else {
                    let events = reminderService.loadEvents(from: start, to: end, calendarIDs: selectedEventCalendarIDs)
                    calendarEventCache[key] = events
                    calendarCacheOrder.append(key)
                    result += events
                    if calendarCacheOrder.count > 18 { calendarEventCache.removeValue(forKey: calendarCacheOrder.removeFirst()) }
                }
                start = end
            }
            return result.filter { $0.endDate >= range.start && $0.startDate < range.end }
        }
        var seen: Set<String> = []
        let loadedEvents = fetchedEvents.filter {
            seen.insert("\($0.id)-\($0.startDate.timeIntervalSince1970)").inserted
        }.map { event in
            var taggedEvent = event
            taggedEvent.tags = metadataStore.eventTags[event.id] ?? []
            return taggedEvent
        }.sorted { $0.startDate < $1.startDate }
        if calendarEvents != loadedEvents { calendarEvents = loadedEvents }
    }

    static func mergedCalendarRanges(_ first: DateInterval, _ second: DateInterval) -> [DateInterval] {
        if first.end >= second.start && second.end >= first.start {
            return [DateInterval(start: min(first.start, second.start), end: max(first.end, second.end))]
        }
        return [first, second].sorted { $0.start < $1.start }
    }

    private func updateTaskInMemory(_ task: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
    }

    /// Open bills' renewal, notice, and cancellation dates, for lists that keep deadline reminders on.
    var billDeadlineAlerts: [NotificationScheduler.DeadlineAlert] {
        tasks.compactMap { task -> [NotificationScheduler.DeadlineAlert]? in
            let profile = listProfile(task.listID)
            guard profile.type == .bills, profile.settings["Deadline Reminders"] != "false", !task.isCompleted else { return nil }
            let fields = specializedDetails(task).fields
            guard !["Paid", "Canceled"].contains(fields["Stage"] ?? "") else { return nil }
            let lead = Int(profile.settings["Deadline Lead Days"] ?? "") ?? 3
            return SpecializedListType.billDeadlineFields.compactMap { key in
                guard profile.settings["Hidden Field " + key] != "true",
                      let date = SpecializedTaskDetails.dateValue(fields[key] ?? "") else { return nil }
                return NotificationScheduler.DeadlineAlert(taskID: task.id, listID: task.listID, taskTitle: task.title, label: key, date: date, leadDays: lead)
            }
        }.flatMap { $0 }
    }

    /// Re-applies reminders after list options that affect them change.
    func refreshDeadlineReminders() async { await rescheduleNotifications() }

    private func rescheduleNotifications() async {
        await notificationScheduler.rescheduleNotifications(for: tasks, deadlines: billDeadlineAlerts, enabled: notificationsEnabled)
        await syncDueTodayActivity()
    }

    private func applyScope(_ items: [TaskItem], scope: TaskScope? = nil) -> [TaskItem] {
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
        case .next7Days:
            return items.filter { $0.isDue(inNextDays: 7) }
        case .upNext:
            return items.filter { $0.isDue(inNextDays: 14) }
        case .planMyDay:
            return items.filter { !$0.isCompleted }
        }
    }

    private func sortTasks(_ items: [TaskItem]) -> [TaskItem] {
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

/// Title, creator, thumbnail, and reading time for a saved link, read from the page's HTML.
struct ReadingLinkMetadata: Equatable, Sendable {
    var title = ""
    var creator = ""
    var format = ""
    var thumbnailURL: URL?
    var estimatedMinutes: Int?

    /// Fields for `SpecializedTaskDetails`, leaving out anything unknown.
    var fields: [String: String] {
        var result: [String: String] = [:]
        if !creator.isEmpty { result["Creator"] = creator }
        if !format.isEmpty { result["Format"] = format }
        if let thumbnailURL { result["Thumbnail URL"] = thumbnailURL.absoluteString }
        if let estimatedMinutes { result["Estimated Minutes"] = String(estimatedMinutes) }
        return result
    }

    private static let maximumBytes = 1_000_000

    static func fetch(_ url: URL) async -> ReadingLinkMetadata? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        let prefix = data.prefix(maximumBytes)
        guard let html = String(data: prefix, encoding: .utf8) ?? String(data: prefix, encoding: .isoLatin1) else { return nil }
        return parse(html: html, baseURL: response.url ?? url, isComplete: data.count <= maximumBytes)
    }

    static func parse(html: String, baseURL: URL, isComplete: Bool = true) -> ReadingLinkMetadata {
        var result = ReadingLinkMetadata()
        result.title = meta(["og:title", "twitter:title"], in: html) ?? element("title", in: html) ?? ""
        result.creator = meta(["author", "article:author", "book:author", "og:site_name", "twitter:creator"], in: html) ?? ""
        if result.creator.lowercased().hasPrefix("http") { result.creator = "" }
        if let image = meta(["og:image:secure_url", "og:image", "twitter:image"], in: html),
           let imageURL = URL(string: image, relativeTo: baseURL)?.absoluteURL, imageURL.scheme?.lowercased() == "https" {
            result.thumbnailURL = imageURL
        }
        let type = (meta(["og:type"], in: html) ?? "").lowercased()
        let host = (baseURL.host ?? "").lowercased()
        if type.contains("video") || ["youtube.com", "youtu.be", "vimeo.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            result.format = "Video"
        } else if type.contains("book") {
            result.format = "Book"
        } else if type.contains("article") {
            result.format = "Article"
        }
        if result.format != "Video", isComplete {
            let words = wordCount(html)
            if words >= 150 { result.estimatedMinutes = max(1, Int((Double(words) / 230).rounded())) }
        }
        return result
    }

    private static func meta(_ names: [String], in html: String) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            // The content value ends at its own opening quote, so apostrophes inside "…" survive.
            let patterns = [
                "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*?content\\s*=\\s*([\"'])(.*?)\\1",
                "<meta[^>]+?content\\s*=\\s*([\"'])(.*?)\\1[^>]*(?:property|name)\\s*=\\s*[\"']\(escaped)[\"']"
            ]
            for pattern in patterns {
                if let value = firstCapture(pattern, group: 2, in: html), !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func element(_ tag: String, in html: String) -> String? {
        firstCapture("<\(tag)[^>]*>([^<]*)</\(tag)>", group: 1, in: html).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func firstCapture(_ pattern: String, group: Int, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: html) else { return nil }
        return decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&#8217;", "’"), ("&#8211;", "–"), ("&#8212;", "—"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Words of visible body text; scripts, styles, and markup are removed first.
    private static func wordCount(_ html: String) -> Int {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<noscript[\\s\\S]*?</noscript>", "<[^>]+>"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
