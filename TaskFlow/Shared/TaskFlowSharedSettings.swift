import AppIntents
import Foundation
@preconcurrency import EventKit
import SwiftUI
import WidgetKit

enum TaskFlowSharedSettings {
    static let appThemeKey = "TaskFlow.appTheme"
    static var shoppingShopperName: String {
        get { defaults.string(forKey: "TaskFlow.shoppingShopperName") ?? "" }
        set { defaults.set(newValue, forKey: "TaskFlow.shoppingShopperName") }
    }
    static let widgetCompletedReminderIDsKey = "TaskFlow.widgetCompletedReminderIDs"
    static let selectedEventCalendarIDsKey = "TaskFlow.selectedEventCalendarIDs"
    /// Reminder list IDs chosen by the active Focus filter; empty means show every list.
    static let focusListIDsKey = "TaskFlow.focusListIDs"
    /// Which reminder lists and event calendars the user turned off in TaskFlow, shared so widgets hide them too.
    static let usesRemindersKey = "TaskFlow.usesReminders"
    static let usesCalendarsKey = "TaskFlow.usesCalendars"
    static let disabledReminderListIDsKey = "TaskFlow.disabledReminderListIDs"
    static let disabledEventCalendarIDsKey = "TaskFlow.disabledEventCalendarIDs"

    static var usesReminders: Bool { defaults.object(forKey: usesRemindersKey) as? Bool ?? true }
    static var usesCalendars: Bool { defaults.object(forKey: usesCalendarsKey) as? Bool ?? true }
    static var disabledReminderListIDs: Set<String> { Set(defaults.stringArray(forKey: disabledReminderListIDsKey) ?? []) }
    static var disabledEventCalendarIDs: Set<String> { Set(defaults.stringArray(forKey: disabledEventCalendarIDsKey) ?? []) }

    /// Reminder lists turned on in TaskFlow Settings; widget pickers and Shortcuts offer only these.
    static func availableReminderLists(in store: EKEventStore) -> [EKCalendar] {
        guard usesReminders else { return [] }
        let disabled = disabledReminderListIDs
        return store.calendars(for: .reminder).filter { !disabled.contains($0.calendarIdentifier) }
    }
    static let appGroupID = "group.com.surratt.TaskFlow"
    static let widgetMetadataFileName = "WidgetMetadata.json"
    static let widgetSmartListsFileName = "WidgetSmartLists.json"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static var theme: TaskFlowSharedTheme {
        get {
            TaskFlowSharedTheme(rawValue: defaults.string(forKey: appThemeKey) ?? "") ?? .system
        }
        set {
            guard defaults.string(forKey: appThemeKey) != newValue.rawValue else { return }
            defaults.set(newValue.rawValue, forKey: appThemeKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

enum TaskFlowDeepLink {
    static let scheme = "taskflow"
    static let calendarURL = URL(string: "\(scheme)://calendar")!
    static let captureURL = URL(string: "\(scheme)://capture")!
    static let newNoteURL = URL(string: "\(scheme)://new-note")!
    static let dictateNoteURL = URL(string: "\(scheme)://dictate-note")!

    static func taskURL(_ id: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return URL(string: "\(scheme)://task/\(id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)") ?? calendarURL
    }

    static func noteURL(_ id: UUID) -> URL { URL(string: "\(scheme)://note/\(id.uuidString)")! }

    static func listURL(_ id: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return URL(string: "\(scheme)://list/\(id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)") ?? calendarURL
    }

    static func eventURL(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "event"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? calendarURL
    }
}

enum TaskFlowSharedWidgetActions {
    static func recordCompletedReminder(id: String) {
        guard !id.isEmpty else { return }
        var ids = TaskFlowSharedSettings.defaults.stringArray(forKey: TaskFlowSharedSettings.widgetCompletedReminderIDsKey) ?? []
        if !ids.contains(id) {
            ids.append(id)
        }
        TaskFlowSharedSettings.defaults.set(ids, forKey: TaskFlowSharedSettings.widgetCompletedReminderIDsKey)
    }

    static func consumeCompletedReminderIDs() -> [String] {
        let ids = TaskFlowSharedSettings.defaults.stringArray(forKey: TaskFlowSharedSettings.widgetCompletedReminderIDsKey) ?? []
        TaskFlowSharedSettings.defaults.removeObject(forKey: TaskFlowSharedSettings.widgetCompletedReminderIDsKey)
        return ids
    }
}

struct TaskFlowSharedTaskMetadata: Codable, Hashable {
    var tags: [String] = []
    var status: String = "Not Started"
    var isFlagged = false
    var parentID: String?
    var durationMinutes: Int?
    var blockedByTaskIDs: [String] = []
    var specializedFields: [String: String]? = nil
}

struct TaskFlowSharedSmartListDefinition: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var icon: String
    var status: String?
    var priority: String?
    var dateRange: String?
    var requiredTag: String?
    var listID: String?
    var flaggedOnly: Bool
    var blockedOnly: Bool
    var includeCompleted: Bool
    var matchMode: String? = nil
    var rules: [TaskFlowSharedSmartTaskRule]? = nil
}

struct TaskFlowSharedSmartTaskRule: Codable, Hashable {
    var field: String
    var value: String
}

enum TaskFlowSharedWidgetMetadata {
    static func tags(for id: String, externalID: String?) -> [String] {
        let metadata = load()
        if let externalID, let externalMetadata = metadata[externalID] {
            return externalMetadata.tags
        }
        return metadata[id]?.tags ?? []
    }

    static func save(_ metadata: [String: TaskFlowSharedTaskMetadata]) {
        guard let url else { return }
        guard load() != metadata, let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: url, options: [.atomic])
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func metadata(for id: String, externalID: String?) -> TaskFlowSharedTaskMetadata {
        let metadata = load()
        if let externalID, let externalMetadata = metadata[externalID] {
            return externalMetadata
        }
        return metadata[id] ?? TaskFlowSharedTaskMetadata()
    }

    static func saveSmartLists(_ smartLists: [TaskFlowSharedSmartListDefinition]) {
        guard let smartListsURL else { return }
        guard loadSmartLists() != smartLists, let data = try? JSONEncoder().encode(smartLists) else { return }
        try? data.write(to: smartListsURL, options: [.atomic])
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func loadSmartLists() -> [TaskFlowSharedSmartListDefinition] {
        guard let smartListsURL, let data = try? Data(contentsOf: smartListsURL) else { return [] }
        return (try? JSONDecoder().decode([TaskFlowSharedSmartListDefinition].self, from: data)) ?? []
    }

    static func load() -> [String: TaskFlowSharedTaskMetadata] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: TaskFlowSharedTaskMetadata].self, from: data)) ?? [:]
    }

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TaskFlowSharedSettings.appGroupID)?
            .appendingPathComponent(TaskFlowSharedSettings.widgetMetadataFileName)
    }

    private static var smartListsURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TaskFlowSharedSettings.appGroupID)?
            .appendingPathComponent(TaskFlowSharedSettings.widgetSmartListsFileName)
    }
}

enum TaskFlowSharedTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case classicBlue = "Classic Blue"
    case oceanTeal = "Ocean Teal"
    case meadowGreen = "Meadow Green"
    case sunsetCoral = "Sunset Coral"
    case grape = "Grape"
    case slate = "Slate"
    case taskflow = "TaskFlow"
    case ocean = "Ocean"
    case citrus = "Citrus"
    case berry = "Berry"
    case graphite = "Graphite"
    case aurora = "Aurora"
    case meadow = "Meadow"
    case ember = "Ember"
    case rose = "Rose"
    case lagoon = "Lagoon"
    case sunrise = "Sunrise"

    var id: String { rawValue }

    var primary: Color {
        switch self {
        case .system: .blue
        case .classicBlue: Color(red: 0.18, green: 0.45, blue: 0.82)
        case .oceanTeal: Color(red: 0.05, green: 0.58, blue: 0.53)
        case .meadowGreen: Color(red: 0.13, green: 0.60, blue: 0.35)
        case .sunsetCoral: Color(red: 0.90, green: 0.42, blue: 0.30)
        case .grape: Color(red: 0.52, green: 0.34, blue: 0.78)
        case .slate: Color(red: 0.38, green: 0.45, blue: 0.54)
        case .taskflow: .indigo
        case .ocean: .teal
        case .citrus: .orange
        case .berry: .pink
        case .graphite: .gray
        case .aurora: .green
        case .meadow: Color(red: 0.24, green: 0.58, blue: 0.32)
        case .ember: .red
        case .rose: Color(red: 0.86, green: 0.20, blue: 0.36)
        case .lagoon: .cyan
        case .sunrise: Color(red: 0.96, green: 0.44, blue: 0.20)
        }
    }

    var secondary: Color {
        switch self {
        case .system: .secondary
        case .classicBlue: .blue
        case .oceanTeal: .teal
        case .meadowGreen: .green
        case .sunsetCoral: .orange
        case .grape: .purple
        case .slate: .gray
        case .taskflow: .teal
        case .ocean: .blue
        case .citrus: .yellow
        case .berry: .purple
        case .graphite: .blue
        case .aurora: .cyan
        case .meadow: .mint
        case .ember: .orange
        case .rose: .pink
        case .lagoon: .teal
        case .sunrise: .yellow
        }
    }

    var tertiary: Color {
        switch self {
        case .system: .gray
        case .classicBlue: .cyan
        case .oceanTeal: .mint
        case .meadowGreen: Color(red: 0.70, green: 0.78, blue: 0.18)
        case .sunsetCoral: .yellow
        case .grape: .pink
        case .slate: .indigo
        case .taskflow: .purple
        case .ocean: .mint
        case .citrus: .green
        case .berry: .orange
        case .graphite: .indigo
        case .aurora: .pink
        case .meadow: Color(red: 0.70, green: 0.78, blue: 0.18)
        case .ember: .yellow
        case .rose: .purple
        case .lagoon: .indigo
        case .sunrise: .pink
        }
    }
}

/// Shared by the app and widget extension so controls can launch the containing app.
/// A durable route survives startup; the notification handles an already running app.
enum TaskFlowSharedIntentRoute {
    static let pendingURLKey = "TaskFlow.pendingIntentURL"
    static let notification = Notification.Name("TaskFlow.intentRouteChanged")

    @MainActor
    static func open(url: URL, defaults: UserDefaults = TaskFlowSharedSettings.defaults) {
        defaults.set(url.absoluteString, forKey: pendingURLKey)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    @MainActor
    static func consume(defaults: UserDefaults = TaskFlowSharedSettings.defaults) -> URL? {
        guard let value = defaults.string(forKey: pendingURLKey) else { return nil }
        defaults.removeObject(forKey: pendingURLKey)
        return URL(string: value)
    }
}

enum TaskFlowNoteCaptureMode {
    case newNote
    case dictateNote
}

struct OpenQuickCaptureControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Capture"
    static var description = IntentDescription("Open Quick Capture in TaskFlow Studio.")
    static var openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        TaskFlowSharedIntentRoute.open(url: TaskFlowDeepLink.captureURL)
        return .result()
    }
}

struct NewNoteControlIntent: AppIntent {
    static var title: LocalizedStringResource = "New Note"
    static var description = IntentDescription("Open a blank note in TaskFlow Studio.")
    static var openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        TaskFlowSharedIntentRoute.open(url: TaskFlowDeepLink.newNoteURL)
        return .result()
    }
}

struct DictateNoteControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate Note"
    static var description = IntentDescription("Open a new note and begin speech transcription in TaskFlow Studio.")
    static var openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        TaskFlowSharedIntentRoute.open(url: TaskFlowDeepLink.dictateNoteURL)
        return .result()
    }
}

enum NoteChecklist {
    struct Item: Identifiable, Equatable, Sendable {
        let id: Int // Source line index, including blank lines; duplicate titles stay distinct.
        var title: String
        var isChecked: Bool
        var section: String = ""
        var depth: Int = 0
    }

    static func items(in text: String) -> [Item] {
        var section = ""
        return text.components(separatedBy: "\n").enumerated().compactMap { index, source in
            let line = source.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
                section = line.drop(while: { $0 == "#" || $0 == " " }).description
                return nil
            }
            let marker = ["- [ ]", "- [x]", "- [X]", "[ ]", "[x]", "[X]", "- ", "> "].first {
                if $0.hasSuffix(" ") { return line.hasPrefix($0) }
                return line == $0 || line.hasPrefix($0 + " ") || line.hasPrefix($0 + "\t")
            }
            let checked = marker == "- [x]" || marker == "- [X]" || marker == "[x]" || marker == "[X]"
            let title = marker.map { String(line.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? line
            guard !line.isEmpty else { return nil }
            return Item(id: index, title: title, isChecked: checked, section: section, depth: source.prefix { $0 == " " }.count / 2)
        }
    }

    static func replacing(_ text: String, itemID: Int, title: String? = nil, checked: Bool? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let item = items(in: text).first(where: { $0.id == itemID }), lines.indices.contains(itemID) else { return text }
        let indent = String(lines[itemID].prefix { $0 == " " || $0 == "\t" })
        let value = title ?? item.title
        lines[itemID] = indent + ((checked ?? item.isChecked) ? "- [x] " : "- [ ] ") + value.replacingOccurrences(of: "\n", with: " ")
        return lines.joined(separator: "\n")
    }

    static func formatted(_ text: String, prefix: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return prefix }
        var lines = text.components(separatedBy: "\n")
        for item in items(in: text) {
            let indent = String(lines[item.id].prefix { $0 == " " || $0 == "\t" })
            let marker = prefix == "- [ ] " && item.isChecked ? "- [x] " : prefix
            lines[item.id] = indent + marker + item.title
        }
        return lines.joined(separator: "\n")
    }

    static func setAll(_ text: String, checked: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        for item in items(in: text) {
            let indent = String(lines[item.id].prefix { $0 == " " || $0 == "\t" })
            lines[item.id] = indent + (checked ? "- [x] " : "- [ ] ") + item.title
        }
        return lines.joined(separator: "\n")
    }

    static func removing(_ text: String, itemIDs: Set<Int>) -> String {
        text.components(separatedBy: "\n").enumerated().filter { !itemIDs.contains($0.offset) }.map(\.element).joined(separator: "\n")
    }
}



extension NoteChecklist {
    static func moving(_ text: String, itemID: Int, before targetID: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(itemID), lines.indices.contains(targetID), itemID != targetID else { return text }
        let baseIndent = lines[itemID].prefix { $0 == " " || $0 == "\t" }.count
        var end = itemID + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty,
              lines[end].prefix(while: { $0 == " " || $0 == "\t" }).count > baseIndent { end += 1 }
        guard !(itemID..<end).contains(targetID) else { return text }
        let block = Array(lines[itemID..<end])
        lines.removeSubrange(itemID..<end)
        let destination = targetID > itemID ? targetID - block.count : targetID
        lines.insert(contentsOf: block, at: destination)
        return lines.joined(separator: "\n")
    }

    static func isCheckboxLine(_ source: String) -> Bool {
        let line = source.trimmingCharacters(in: .whitespaces)
        return ["- [ ]", "- [x]", "- [X]", "[ ]", "[x]", "[X]"].contains { line == $0 || line.hasPrefix($0 + " ") }
    }
}


struct TaskFlowSharedNote: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var text: String
    var folder: String
    var tags: [String]
    var isPinned: Bool
    var format: String
    var updatedAt: Date
    var checklistItems: [NoteChecklist.Item] {
        guard format == "checklist" || format == "markdown" else { return [] }
        let lines = text.components(separatedBy: "\n")
        return NoteChecklist.items(in: text).filter { format == "checklist" || NoteChecklist.isCheckboxLine(lines[$0.id]) }
    }
}

enum TaskFlowSharedNotes {
    private static let writer = DispatchQueue(label: "TaskFlow.notes-widget-cache", qos: .utility)
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TaskFlowSharedSettings.appGroupID)?.appendingPathComponent("NotesWidget.json")
    }
    static func load() -> [TaskFlowSharedNote] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TaskFlowSharedNote].self, from: data)) ?? []
    }
    static func save(_ notes: [TaskFlowSharedNote]) {
        guard let url else { return }
        writer.async {
            guard load() != notes, let data = try? JSONEncoder().encode(notes) else { return }
            do {
                try data.write(to: url, options: .atomic)
                WidgetCenter.shared.reloadTimelines(ofKind: "TaskFlowPinnedNoteWidget")
            } catch { /* Never replace the authoritative saved note on cache failure. */ }
        }
    }
}

@MainActor
protocol TaskFlowNoteIntentHandling: Sendable {
    func notes() -> [TaskFlowSharedNote]
    func create(title: String, text: String, folder: String, format: String, pinned: Bool) throws -> TaskFlowSharedNote
    func append(noteID: UUID, text: String) throws -> TaskFlowSharedNote
    func setChecked(noteID: UUID, itemID: Int, expectedSource: String, checked: Bool) throws
}

struct ToggleNoteChecklistWidgetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Check Note Item"
    static var isDiscoverable = false
    static var openAppWhenRun = false
    @Dependency(key: "TaskFlowNotes") private var handler: any TaskFlowNoteIntentHandling
    @Parameter(title: "Note ID") var noteID: String
    @Parameter(title: "Item") var itemID: Int
    @Parameter(title: "Source Line") var expectedSource: String
    @Parameter(title: "Checked") var checked: Bool
    init() { noteID = ""; itemID = 0; expectedSource = ""; checked = false }
    init(noteID: UUID, itemID: Int, expectedSource: String, checked: Bool) {
        self.noteID = noteID.uuidString
        self.itemID = itemID
        self.expectedSource = expectedSource
        self.checked = checked
    }
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: noteID) else { throw NSError(domain: "TaskFlow.Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "This note is unavailable."]) }
        try handler.setChecked(noteID: id, itemID: itemID, expectedSource: expectedSource, checked: checked)
        return .result()
    }
}


struct TaskFlowSharedShoppingDetails: Codable, Hashable {
    var fields: [String: String] = [:]
    var isFavorite = false
    var repeatAfterDays: Int? = nil
}

/// Travels with the reminder so shopping participants can read the same details.
/// Only a valid terminal envelope is removed; ordinary note text is untouched.
enum ShoppingReminderNotes {
    private static let marker = "\n\n[TaskFlow Shopping v1] "
    static func decode(_ notes: String) -> (text: String, details: TaskFlowSharedShoppingDetails?) {
        guard let range = notes.range(of: marker, options: .backwards),
              let data = Data(base64Encoded: String(notes[range.upperBound...])),
              let details = try? JSONDecoder().decode(TaskFlowSharedShoppingDetails.self, from: data) else { return (notes, nil) }
        return (String(notes[..<range.lowerBound]), details)
    }
    static func encode(_ notes: String, details: TaskFlowSharedShoppingDetails?) -> String {
        let text = decode(notes).text
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let details, let data = try? encoder.encode(details) else { return text }
        return text + marker + data.base64EncodedString()
    }
}


@MainActor
enum EpisodeWidgetActionHandler {
    static var reconcile: (() async -> Void)?
    static func reconcileIfAvailable() async { await reconcile?() }
}

struct MarkWidgetEpisodeWatchedIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Episode Watched"
    static var openAppWhenRun = false
    @Parameter(title: "Task") var taskID: String
    @Parameter(title: "Metadata") var metadataID: String
    @Parameter(title: "Show") var showID: Int
    @Parameter(title: "Episode") var episodeID: Int
    init() {}
    init(taskID: String, metadataID: String, showID: Int, episodeID: Int) {
        self.taskID = taskID; self.metadataID = metadataID; self.showID = showID; self.episodeID = episodeID
    }
    func perform() async throws -> some IntentResult {
        let store = EKEventStore()
        let authorization = EKEventStore.authorizationStatus(for: .reminder)
        guard authorization == .fullAccess,
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder, !reminder.isCompleted,
              (reminder.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? reminder.calendarItemIdentifier) == metadataID else { throw CocoaError(.fileReadNoSuchFile) }
        let metadata = TaskFlowSharedWidgetMetadata.metadata(for: taskID, externalID: reminder.calendarItemExternalIdentifier)
        let fields = WatchedEpisodeActionStore.applying(WatchedEpisodeActionStore.pending(), fields: metadata.specializedFields ?? [:], taskID: taskID, metadataID: metadataID)
        guard ReadingMedia.markingEpisodeWatched(fields, showID: showID, episodeID: episodeID) != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        try WatchedEpisodeActionStore.record(WatchedEpisodeAction(taskID: taskID, metadataID: metadataID, showID: showID, episodeID: episodeID))
        await EpisodeNotificationActions.retire(taskID: taskID, showID: showID, episodeID: episodeID)
        await EpisodeWidgetActionHandler.reconcileIfAvailable()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
