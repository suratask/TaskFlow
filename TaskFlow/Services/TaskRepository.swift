import Foundation
import UserNotifications
import CloudKit
import EventKit
import Observation
import SwiftUI
import WidgetKit
import LinkPresentation
import UIKit

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

        /// The curated themes offered in Settings.
        static let selectableCases: [AppTheme] = [.system, .classicBlue, .oceanTeal, .meadowGreen, .sunsetCoral, .slate, .aurora]

        /// Retired themes stay decodable (stored preferences, iCloud settings) and quietly
        /// map to the closest curated theme.
        var canonical: AppTheme {
            switch self {
            case .taskflow: .classicBlue
            case .ocean, .lagoon: .oceanTeal
            case .citrus, .ember, .rose, .sunrise: .sunsetCoral
            case .grape, .berry: .aurora
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

        /// Timeline and Agenda are retired top-level modes: Timeline shows as List, and
        /// Agenda opens Calendar (where Agenda remains a style alongside Day, Week, and Month).
        var normalized: TaskViewMode {
            switch self {
            case .timeline: .list
            case .agenda: .calendar
            default: self
            }
        }
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
    @ObservationIgnored var taskIndexByID: [String: Int] = [:]
    private func currentTask(id: String) -> TaskItem? {
        guard let index = taskIndexByID[id], tasks.indices.contains(index), tasks[index].id == id else { return nil }
        return tasks[index]
    }
    private(set) var tasksRevision = 0
    private(set) var notesRevision = 0
    private(set) var attachmentContentRevision = 0
    private(set) var linkedNoteURLs: Set<URL> = []
    @ObservationIgnored var childrenByParent: [String: [TaskItem]] = [:]
    var listProfiles: [String: SpecializedListProfile] = [:] { didSet { taskFilterRevision &+= 1 } }
    var specializedTasks: [String: SpecializedTaskDetails] = [:] { didSet { taskFilterRevision &+= 1 } }
    var listTemplates: [SpecializedListTemplate] = []
    var shoppingPriceHistory: [String: Double] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(shoppingPriceHistory) { preferences.set(data, forKey: "TaskFlow.shoppingPriceHistory") }
        }
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
    var shoppingQuantityUpdates: Set<String> = []
    var listIcons: [String: String] = [:]
    static let listIconChoices = ["list.bullet", "briefcase", "house", "cart", "heart", "pills", "book", "person.2", "airplane", "graduationcap", "star", "folder", "wrench.and.screwdriver", "leaf", "music.note", "sportscourt", "film", "tv", "headphones", "bookmark", "newspaper", "bag", "basket", "fork.knife", "cup.and.saucer", "gift", "pawprint", "car", "bicycle", "tram", "map", "tent", "sun.max", "moon", "cloud", "camera", "paintbrush", "gamecontroller", "laptopcomputer", "hammer", "building.2", "dollarsign.circle", "creditcard", "banknote", "calendar", "clock", "checkmark.seal", "lightbulb", "brain.head.profile", "figure.walk", "figure.run", "dumbbell", "cross.case", "stethoscope", "waterbottle", "drop", "flame", "globe", "shippingbox", "pencil", "note.text", "doc.text", "tray", "flag", "bolt", "sparkles"]
    var todaySectionRevision = 0
    var todayPlanningRevision = 0
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
    /// Lists the user turned off for Focus Next; nil until they first choose, when
    /// Shopping and Reading & Watch Later lists are left out by default.
    /// Kept on this device: reminder list identifiers differ between devices.
    var focusNextExcludedListIDs: Set<String>? = nil {
        didSet { preferences.set(focusNextExcludedListIDs.map { $0.sorted() }, forKey: "TaskFlow.focusNextExcludedListIDs") }
    }
    var excludedAvailabilityCalendarIDs: Set<String> = [] {
        didSet {
            preferences.set(excludedAvailabilityCalendarIDs.sorted(), forKey: "TaskFlow.excludedAvailabilityCalendarIDs")
            scheduleCloudSync()
        }
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
    let reminderService = EventKitReminderService()
    let metadataStore: MetadataStore
    let cloudSync = CloudMetadataSyncService()
    var cloudSyncEnabled = false
    var cloudSyncTask: Task<Void, Never>?
    var isApplyingCloudSnapshot = false
    var isCloudSyncRunning = false
    var hasPendingCloudSync = false
    var cloudPreferencesObserver: NSObjectProtocol?
    @ObservationIgnored var cloudPreferencesCapture: Task<Void, Never>?
    var cloudSyncStatus = "Not synced yet"
    private static let syncedPreferenceKeys = [
        "TaskFlow.appTheme", "TaskFlow.appearanceMode", "TaskFlow.taskDensity",
        "TaskFlow.taskViewMode", "TaskFlow.taskGroupOption", "TaskFlow.taskSortOption",
        "TaskFlow.todaySectionOrder", "TaskFlow.todayHiddenSections",
        "TaskFlow.taskSortDirection", "TaskFlow.listIcons", "TaskFlow.listOrder", "TaskFlow.includeCompletedTasks",
        "TaskFlow.dueFilter", "TaskFlow.quickDueFilter", "TaskFlow.quickStatusFilter",
        "TaskFlow.quickPriorityFilter", "TaskFlow.selectedTagFilter", "TaskFlow.quickTagFilter",
        "TaskFlow.calendar.workspace", "TaskFlow.calendar.savedContexts", "TaskFlow.excludedAvailabilityCalendarIDs",
        "TaskFlow.shoppingPriceHistory"
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
    let preferences: UserDefaults
    var loadingTask: Task<Void, Never>?
    var taskRefresh: Task<[TaskItem], Never>?
    var taskFetchGeneration = 0
    var hasLoadedInitialData = false
    let notificationScheduler = NotificationScheduler()
    let dueTodayActivity = DueTodayLiveActivityCoordinator()
    /// Opt-in Lock Screen Live Activity listing today's tasks.
    var showsDueTodayLiveActivity = false {
        didSet {
            preferences.set(showsDueTodayLiveActivity, forKey: "TaskFlow.showsDueTodayLiveActivity")
            Task { await syncDueTodayActivity() }
        }
    }
    var lastActivityTasks: [TaskItem]?
    var lastActivityLists: [TaskList]?
    var lastActivityDay: Date?
    var lastActivityEnabled: Bool?
    var accessState: ReminderAccessState = .unknown
    var noteDrafts: [NoteEditorRecovery] = []
    var draftWriteGeneration = 0
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
        focusNextExcludedListIDs = preferences.stringArray(forKey: "TaskFlow.focusNextExcludedListIDs").map(Set.init)
        hasCompletedOnboarding = preferences.bool(forKey: "TaskFlow.hasCompletedOnboarding")
        appearanceMode = AppearanceMode(rawValue: preferences.string(forKey: "TaskFlow.appearanceMode") ?? "") ?? .system
        appTheme = (AppTheme(rawValue: preferences.string(forKey: "TaskFlow.appTheme") ?? "") ?? .system).canonical
        taskDensity = TaskDensity(rawValue: preferences.string(forKey: "TaskFlow.taskDensity") ?? "") ?? .comfortable
        taskViewMode = (TaskViewMode(rawValue: preferences.string(forKey: "TaskFlow.taskViewMode") ?? "") ?? .list).normalized
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
    var taskFilterRevision = 0
    @ObservationIgnored var taskFilterCacheKey: [String] = []
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
    @ObservationIgnored var groupCacheKey: [String] = []
    @ObservationIgnored private var groupCacheResult: [TaskGroup] = []
    @ObservationIgnored private var groupCacheExpiry = Date.distantPast

    var groupedTasks: [TaskGroup] { cachedGroups(rootsOnly: false) }
    enum TaskFilterKind: String, CaseIterable, Identifiable {
        case status, priority, due, tag
        var id: String { rawValue }
    }
    struct ActiveTaskFilter: Identifiable, Hashable {
        let kind: TaskFilterKind
        let title: String
        var id: TaskFilterKind { kind }
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
    /// Light ticks for steppers, drag-and-drop, and reordering.
    var selectionFeedbackSequence = 0
    /// A soft tap when an undo or redo lands.
    var undoFeedbackSequence = 0

    func scrollAnchor(for scope: TaskScope) -> String? {
        preferences.string(forKey: "TaskFlow.scroll.\(scope.id)")
    }
    var previousEventEdit: EventDraft?
    var previousEventBatchIDs: [String] = []
    var eventSaveStatus = ""
    private(set) var lastEventDeletion: EventDeletion?
    var deletingEventKeys: Set<String> = []
    private(set) var lastSavedEventID: String?
    private(set) var lastAvailabilityEventID: String?
    var calendarAnchor = Date()
    var readingPreviewJobs: Set<String> = []
    var refreshingShows: Set<String> = []
    var consumingEpisodeActions = false
    struct NoteUndo {
        let id = UUID()
        let noteID: UUID
        let previous: QuickNote?
        let message: String
    }
    var noteUndo: NoteUndo?
    var noteRedo: NoteUndo?
    struct CalendarFetchKey: Hashable {
        let start: Date
        let end: Date
        let calendars: Set<String>
    }
    var calendarEventCache: [CalendarFetchKey: [CalendarEvent]] = [:]
    var calendarCacheOrder: [CalendarFetchKey] = []
}
