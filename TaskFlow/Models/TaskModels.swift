import Foundation
import os
import SwiftUI

struct TaskList: Identifiable, Hashable {
    let id: String
    var title: String
    var color: Color
}

struct EventCalendar: Identifiable, Hashable {
    let id: String
    var title: String
    var color: Color
    var allowsModifications = false
    var supportsAvailability = true
}

enum EventAvailability: String, CaseIterable, Identifiable, Codable {
    case busy = "Busy"
    case free = "Free"
    case tentative = "Tentative"
    case unavailable = "Unavailable"

    var id: String { rawValue }
}

enum LocationProximity: String, CaseIterable, Codable, Identifiable {
    case onArrival = "On Arrival"
    case onDeparture = "On Departure"

    var id: String { rawValue }
}

enum EventAlarmOption: Int, CaseIterable, Identifiable, Codable {
    case none = -1
    case atTime = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case oneDay = 1440

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .atTime: "At time of event"
        case .fiveMinutes: "5 minutes before"
        case .fifteenMinutes: "15 minutes before"
        case .thirtyMinutes: "30 minutes before"
        case .oneHour: "1 hour before"
        case .twoHours: "2 hours before"
        case .oneDay: "1 day before"
        }
    }
}

struct EventParticipant: Identifiable, Hashable {
    var id: String { (name.isEmpty ? email : name) + "-" + role }
    var name: String
    var email: String
    var role: String
    var status: String
    var isCurrentUser: Bool = false
}

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    var calendarID: String
    var title: String
    var location: String?
    var notes: String?
    var url: URL?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var availability: String? = nil
    var alarmOffsetMinutes: Int? = nil
    var timeZoneIdentifier: String? = nil
    var recurrenceSummary: String? = nil
    var recurrence: RecurrenceRule? = nil
    var calendarSource: String? = nil
    var organizerName: String? = nil
    var attendees: [EventParticipant] = []
    var attachments: [TaskAttachment] = []
    var structuredLocation: TaskLocation? = nil
    var tags: [String] = []

    var onlineMeeting: OnlineMeetingInfo? {
        OnlineMeetingInfo.detect(in: self)
    }

    /// Occurrences of a recurring event share `id`, so lists spanning multiple days key rows by occurrence.
    var occurrenceKey: String { "\(id)-\(startDate.timeIntervalSince1970)" }
}

struct CalendarEventConflict: Identifiable, Hashable {
    let first: CalendarEvent
    let second: CalendarEvent
    let start: Date
    let end: Date
    var id: String { first.occurrenceKey + "|" + second.occurrenceKey }
}

enum EventConflictChecker {
    static func pairs(in events: [CalendarEvent], from start: Date, to end: Date, includeAllDay: Bool = true, limit: Int = 2_001) -> [CalendarEventConflict] {
        guard end > start, limit > 0 else { return [] }
        var seen = Set<String>()
        let busy = events.filter { $0.availability != "Free" && (includeAllDay || !$0.isAllDay) && $0.endDate > start && $0.startDate < end && $0.endDate > $0.startDate && seen.insert($0.occurrenceKey).inserted }
            .sorted { $0.startDate == $1.startDate ? $0.occurrenceKey < $1.occurrenceKey : $0.startDate < $1.startDate }
        var results: [CalendarEventConflict] = []
        for i in busy.indices {
            var j = i + 1
            while j < busy.count && busy[j].startDate < busy[i].endDate {
                let lower = max(start, busy[i].startDate, busy[j].startDate)
                let upper = min(end, busy[i].endDate, busy[j].endDate)
                if upper > lower {
                    results.append(CalendarEventConflict(first: busy[i], second: busy[j], start: lower, end: upper))
                    if results.count >= limit { return results.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start } }
                }
                j += 1
            }
        }
        return results.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    static func overlaps(start: Date, end: Date, events: [CalendarEvent], excludingID: String? = nil, excludingStart: Date? = nil, availability: String = "Busy") -> [CalendarEvent] {
        guard end > start, availability != "Free" else { return [] }
        return events.filter { event in
            let sameOccurrence = event.id == excludingID && (excludingStart == nil || event.startDate == excludingStart)
            return !sameOccurrence && event.availability != "Free" && event.startDate < end && event.endDate > start
        }.sorted { $0.startDate < $1.startDate }
    }
}

struct OnlineMeetingInfo: Hashable {
    var url: URL
    var provider: OnlineMeetingProvider

    var appURL: URL? {
        provider.appURL(for: url)
    }

    static func detect(in event: CalendarEvent) -> OnlineMeetingInfo? {
        var candidates: [URL] = []

        if let url = event.url {
            candidates.append(url)
            candidates.append(contentsOf: URL.embeddedMeetingURLs(in: url))
        }

        [event.location, event.notes].compactMap { $0 }.forEach { text in
            candidates.append(contentsOf: URL.meetingCandidates(in: text))
        }

        let meetings: [OnlineMeetingInfo] = candidates.compactMap { url in
            guard let provider = OnlineMeetingProvider(url: url) else { return nil }
            return OnlineMeetingInfo(url: url, provider: provider)
        }

        return meetings.first { $0.provider != .generic } ?? meetings.first
    }
}

enum OnlineMeetingProvider: Hashable {
    case zoom
    case teams
    case googleMeet
    case webex
    case faceTime
    case chime
    case blueJeans
    case goToMeeting
    case generic

    var searchLabel: String {
        switch self {
        case .zoom: "zoom meeting"
        case .teams: "microsoft teams meeting"
        case .googleMeet: "google meet"
        case .webex: "webex meeting"
        case .faceTime: "facetime"
        case .chime: "amazon chime"
        case .blueJeans: "bluejeans meeting"
        case .goToMeeting: "gotomeeting"
        case .generic: "online meeting"
        }
    }

    init?(url: URL) {
        let host = (url.host ?? "").lowercased()
        let absoluteString = url.absoluteString.lowercased()

        if host.contains("zoom.us") {
            self = .zoom
        } else if host == "teams.microsoft.com" ||
            host.hasSuffix(".teams.microsoft.com") ||
            host == "teams.live.com" ||
            host.hasSuffix(".teams.live.com") ||
            host == "teams.cloud.microsoft" ||
            host.hasSuffix(".teams.cloud.microsoft") ||
            absoluteString.contains("msteams:") {
            self = .teams
        } else if host == "meet.google.com" {
            self = .googleMeet
        } else if host.contains("webex.com") {
            self = .webex
        } else if host == "facetime.apple.com" || absoluteString.hasPrefix("facetime:") || absoluteString.hasPrefix("facetime-audio:") {
            self = .faceTime
        } else if host.contains("chime.aws") {
            self = .chime
        } else if host.contains("bluejeans.com") {
            self = .blueJeans
        } else if host.contains("gotomeeting.com") || host.contains("goto.com") {
            self = .goToMeeting
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            self = .generic
        } else {
            return nil
        }
    }

    var buttonTitle: String {
        switch self {
        case .zoom: "Join Zoom"
        case .teams: "Join Teams"
        case .googleMeet: "Join Meet"
        case .webex: "Join Webex"
        case .faceTime: "Join FaceTime"
        case .chime: "Join Chime"
        case .blueJeans: "Join BlueJeans"
        case .goToMeeting: "Join GoTo"
        case .generic: "Join Meeting"
        }
    }

    var icon: String {
        switch self {
        case .faceTime: "video.circle.fill"
        default: "video.fill"
        }
    }

    func appURL(for url: URL) -> URL? {
        switch self {
        case .teams:
            guard url.scheme?.lowercased() != "msteams" else { return url }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "msteams"
            return components?.url
        default:
            return nil
        }
    }
}

private extension URL {
    static func meetingCandidates(in text: String) -> [URL] {
        var urls = detectedURLs(in: text)
        urls.append(contentsOf: urls.flatMap(embeddedMeetingURLs))
        urls.append(contentsOf: bareMeetingURLs(in: text))
        return urls
    }

    static func detectedURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }

    static func bareMeetingURLs(in text: String) -> [URL] {
        let domains = [
            "zoom.us",
            "teams.microsoft.com",
            "teams.live.com",
            "teams.cloud.microsoft",
            "meet.google.com",
            "webex.com",
            "facetime.apple.com",
            "chime.aws",
            "bluejeans.com",
            "gotomeeting.com",
            "goto.com"
        ]
        let escapedDomains = domains.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?i)\b((?:"# + escapedDomains + #")[^\s<>"']*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let rawValue = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}>"))
            return URL(string: "https://\(rawValue)")
        }
    }

    static func embeddedMeetingURLs(in url: URL) -> [URL] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }

        return (components.queryItems ?? []).flatMap { item -> [URL] in
            guard let value = item.value?.removingPercentEncoding else { return [] }
            return meetingCandidates(in: value)
        }
    }
}

struct EventDraft: Identifiable, Hashable {
    let id = UUID()
    var eventID: String?
    var originalStartDate: Date? = nil
    var calendarID: String
    var title = ""
    var notes = ""
    var location = ""
    var startDate: Date
    var endDate: Date
    var isAllDay = false
    var availability: String = "Busy"
    var alarmOffsetMinutes: Int? = nil
    var recurrence: RecurrenceRule? = nil
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var structuredLocation: TaskLocation? = nil
    var tags: [String] = []

    var normalizedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Event" : trimmed
    }

    var normalizedLocation: String? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedNotes: String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    init(
        eventID: String? = nil,
        calendarID: String,
        title: String = "",
        notes: String = "",
        location: String = "",
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        availability: String = "Busy",
        alarmOffsetMinutes: Int? = nil,
        recurrence: RecurrenceRule? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        structuredLocation: TaskLocation? = nil,
        tags: [String] = []
    ) {
        self.eventID = eventID
        self.calendarID = calendarID
        self.title = title
        self.notes = notes
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.availability = availability
        self.alarmOffsetMinutes = alarmOffsetMinutes
        self.recurrence = recurrence
        self.timeZoneIdentifier = timeZoneIdentifier
        self.structuredLocation = structuredLocation
        self.tags = tags
    }

    init(event: CalendarEvent) {
        self.init(
            eventID: event.id,
            calendarID: event.calendarID,
            title: event.title,
            notes: event.notes ?? "",
            location: event.location ?? "",
            startDate: event.startDate,
            endDate: event.isAllDay ? (Calendar.current.date(byAdding: .day, value: -1, to: event.endDate) ?? event.endDate) : event.endDate,
            isAllDay: event.isAllDay,
            availability: event.availability ?? "Busy",
            alarmOffsetMinutes: event.alarmOffsetMinutes,
            recurrence: event.recurrence,
            timeZoneIdentifier: event.timeZoneIdentifier ?? TimeZone.current.identifier,
            structuredLocation: event.structuredLocation,
            tags: event.tags
        )
        originalStartDate = event.startDate
    }
}

struct TaskLocation: Codable, Hashable, Identifiable {
    var id: String {
        "\(title)|\(address)|\(latitude.map { String($0) } ?? "")|\(longitude.map { String($0) } ?? "")|\(proximity.rawValue)"
    }

    var title: String
    var address: String
    var latitude: Double?
    var longitude: Double?
    var proximity: LocationProximity = .onArrival
    var radius: Double = 100

    var displayTitle: String {
        title.isEmpty ? address : title
    }

    var displayAddress: String {
        address.isEmpty ? title : address
    }

    init(title: String, address: String, latitude: Double? = nil, longitude: Double? = nil, proximity: LocationProximity = .onArrival, radius: Double = 100) {
        self.title = title
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.proximity = proximity
        self.radius = radius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        address = try container.decode(String.self, forKey: .address)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        proximity = try container.decodeIfPresent(LocationProximity.self, forKey: .proximity) ?? .onArrival
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? 100
    }
}

enum MapNavigation {
    static func url(for location: TaskLocation) -> URL? {
        if let latitude = location.latitude, let longitude = location.longitude {
            return url(destination: "\(latitude),\(longitude)", label: location.displayTitle)
        }
        return url(for: location.displayAddress)
    }

    static func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return url(destination: trimmed, label: trimmed)
    }

    private static func url(destination: String, label: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "maps.apple.com"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: destination),
            URLQueryItem(name: "q", value: label),
            URLQueryItem(name: "dirflg", value: "d")
        ]
        return components.url
    }
}

struct TaskItem: Identifiable, Hashable {
    let id: String
    var metadataID: String
    var listID: String
    var title: String
    var notes: String
    var dueDate: Date?
    var hasDueTime: Bool
    var alarmOffsetMinutes: Int? = nil
    var additionalAlerts: [ReminderAlert] = []
    var startDate: Date? = nil
    var hasStartTime = false
    var url: URL? = nil
    var durationMinutes: Int?
    var location: TaskLocation?
    var isCompleted: Bool
    var completedAt: Date?
    var isFlagged: Bool
    var status: TaskStatus
    var priority: TaskPriority
    var recurrence: RecurrenceRule?
    var tags: [String]
    var attachments: [TaskAttachment]
    var comments: [TaskComment]
    var parentID: String?
    var blockedByTaskIDs: [String]
    var createdAt: Date?
    var modifiedAt: Date?
    var sharedShoppingDetails: SpecializedTaskDetails? = nil
}

extension TaskItem {
    var shareText: String {
        var lines = [title]

        if let dueDate {
            let due = dueDate.formatted(date: .abbreviated, time: hasDueTime ? .shortened : .omitted)
            lines.append("Due: \(due)")
        }

        if priority != .none {
            lines.append("Priority: \(priority.rawValue)")
        }

        if status != .notStarted {
            lines.append("Status: \(status.rawValue)")
        }

        if isFlagged {
            lines.append("Flagged")
        }

        if !tags.isEmpty {
            lines.append(tags.map { "#\($0)" }.joined(separator: " "))
        }

        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append(notes)
        }

        return lines.joined(separator: "\n")
    }
}

struct TaskAttachment: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case url
        case file
        case photo
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var urlString: String?
    var localPath: String?
    var createdAt = Date()

    var icon: String {
        switch kind {
        case .url: "link"
        case .file: "doc.fill"
        case .photo: "photo.fill"
        }
    }
}

enum TaskTagColor: String, CaseIterable, Codable, Identifiable {
    case indigo
    case blue
    case teal
    case mint
    case cyan
    case green
    case lime
    case yellow
    case orange
    case coral
    case red
    case pink
    case purple
    case lavender
    case navy
    case brown
    case gray
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indigo: "Indigo"
        case .blue: "Blue"
        case .teal: "Teal"
        case .mint: "Mint"
        case .cyan: "Cyan"
        case .green: "Green"
        case .lime: "Lime"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .coral: "Coral"
        case .red: "Red"
        case .pink: "Pink"
        case .purple: "Purple"
        case .lavender: "Lavender"
        case .navy: "Navy"
        case .brown: "Brown"
        case .gray: "Gray"
        case .black: "Black"
        }
    }

    var color: Color {
        switch self {
        case .indigo: .indigo
        case .blue: .blue
        case .teal: .teal
        case .mint: .mint
        case .cyan: .cyan
        case .green: .green
        case .lime: Color(red: 0.45, green: 0.72, blue: 0.14)
        case .yellow: .yellow
        case .orange: .orange
        case .coral: Color(red: 0.96, green: 0.38, blue: 0.32)
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .lavender: Color(red: 0.62, green: 0.46, blue: 0.92)
        case .navy: Color(red: 0.10, green: 0.22, blue: 0.46)
        case .brown: .brown
        case .gray: .gray
        case .black: .black
        }
    }
}

struct SavedTag: Identifiable, Codable, Hashable {
    var id: String { name.lowercased() }
    var name: String
    var color: TaskTagColor = .indigo
}

struct RecurrenceRule: Codable, Hashable {
    var frequency: RecurrenceFrequency = .weekly
    var interval = 1
    var weekdays: [Int] = []
    var monthDays: [Int] = []
    var months: [Int] = []
    var end: RecurrenceEnd = .never

    var summary: String {
        var parts = ["Every \(intervalDescription)"]
        if frequency == .weekly, !weekdays.isEmpty {
            parts.append("on \(weekdays.map(Self.weekdayName).joined(separator: ", "))")
        }
        if frequency == .monthly, !monthDays.isEmpty {
            parts.append("on day \(monthDays.map(String.init).joined(separator: ", "))")
        }
        if frequency == .yearly, !months.isEmpty {
            parts.append("in \(months.map(Self.monthName).joined(separator: ", "))")
        }
        switch end {
        case .never:
            break
        case .onDate(let date):
            parts.append("until \(date.formatted(date: .abbreviated, time: .omitted))")
        case .afterOccurrences(let count):
            parts.append("for \(count) times")
        }
        return parts.joined(separator: " ")
    }

    private var intervalDescription: String {
        let unit = frequency.unitName(plural: interval != 1)
        return interval == 1 ? unit : "\(interval) \(unit)"
    }

    private static func weekdayName(_ value: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        guard (1...7).contains(value) else { return "\(value)" }
        return symbols[value - 1]
    }

    private static func monthName(_ value: Int) -> String {
        let symbols = Calendar.current.shortMonthSymbols
        guard (1...12).contains(value) else { return "\(value)" }
        return symbols[value - 1]
    }
}

enum RecurrenceFrequency: String, CaseIterable, Codable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"

    var id: String { rawValue }

    func unitName(plural: Bool) -> String {
        switch self {
        case .daily: plural ? "days" : "day"
        case .weekly: plural ? "weeks" : "week"
        case .monthly: plural ? "months" : "month"
        case .yearly: plural ? "years" : "year"
        }
    }
}

enum RecurrenceEnd: Codable, Hashable {
    case never
    case onDate(Date)
    case afterOccurrences(Int)
}

struct TaskComment: Identifiable, Codable, Hashable {
    var editedAt: Date? = nil
    var id = UUID()
    var text: String
    var createdAt = Date()
    var isResolved = false
}

enum QuickNoteFormat: String, CaseIterable, Codable, Hashable, Identifiable {
    case plain
    case bullets
    case checklist
    case quote
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Plain"
        case .bullets: "Bullets"
        case .checklist: "Checklist"
        case .quote: "Quote"
        case .markdown: "Rich Text"
        }
    }

    var icon: String {
        switch self {
        case .plain: "text.alignleft"
        case .bullets: "list.bullet"
        case .checklist: "checklist"
        case .quote: "quote.opening"
        case .markdown: "textformat"
        }
    }
}

enum QuickNoteLayout: String, CaseIterable, Codable, Hashable, Identifiable {
    case standard
    case compact
    case prominent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .compact: "Compact"
        case .prominent: "Prominent"
        }
    }

    var icon: String {
        switch self {
        case .standard: "rectangle"
        case .compact: "rectangle.compress.vertical"
        case .prominent: "rectangle.inset.filled"
        }
    }
}

struct QuickNote: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var text: String
    var createdAt = Date()
    var isResolved = false
    var isPinned = false
    var tags: [String] = []
    var linkedTaskID: String?
    var linkedEventID: String?
    var format: QuickNoteFormat = .plain
    var layout: QuickNoteLayout = .standard
    var drawingData: Data?
    var attachments: [TaskAttachment] = []
    var folder: String = ""
    var versions: [NoteRevision] = []
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        text: String,
        createdAt: Date = Date(),
        isResolved: Bool = false,
        tags: [String] = [],
        linkedTaskID: String? = nil,
        linkedEventID: String? = nil,
        format: QuickNoteFormat = .plain,
        layout: QuickNoteLayout = .standard,
        drawingData: Data? = nil,
        attachments: [TaskAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.isResolved = isResolved
        self.tags = tags
        self.linkedTaskID = linkedTaskID
        self.linkedEventID = linkedEventID
        self.format = format
        self.layout = layout
        self.drawingData = drawingData
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isResolved = try container.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        linkedTaskID = try container.decodeIfPresent(String.self, forKey: .linkedTaskID)
        linkedEventID = try container.decodeIfPresent(String.self, forKey: .linkedEventID)
        format = try container.decodeIfPresent(QuickNoteFormat.self, forKey: .format) ?? .plain
        layout = try container.decodeIfPresent(QuickNoteLayout.self, forKey: .layout) ?? .standard
        drawingData = try container.decodeIfPresent(Data.self, forKey: .drawingData)
        attachments = try container.decodeIfPresent([TaskAttachment].self, forKey: .attachments) ?? []
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        versions = try container.decodeIfPresent([NoteRevision].self, forKey: .versions) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct TaskMetadata: Codable, Hashable {
    var durationMinutes: Int?
    var location: TaskLocation?
    var isFlagged = false
    var status: TaskStatus = .notStarted
    var tags: [String] = []
    var attachments: [TaskAttachment] = []
    var comments: [TaskComment] = []
    var parentID: String?
    var blockedByTaskIDs: [String] = []

    init(
        durationMinutes: Int? = nil,
        location: TaskLocation? = nil,
        isFlagged: Bool = false,
        status: TaskStatus = .notStarted,
        tags: [String] = [],
        attachments: [TaskAttachment] = [],
        comments: [TaskComment] = [],
        parentID: String? = nil,
        blockedByTaskIDs: [String] = []
    ) {
        self.durationMinutes = durationMinutes
        self.location = location
        self.isFlagged = isFlagged
        self.status = status
        self.tags = tags
        self.attachments = attachments
        self.comments = comments
        self.parentID = parentID
        self.blockedByTaskIDs = blockedByTaskIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        location = try container.decodeIfPresent(TaskLocation.self, forKey: .location)
        isFlagged = try container.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .notStarted
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        attachments = try container.decodeIfPresent([TaskAttachment].self, forKey: .attachments) ?? []
        comments = try container.decodeIfPresent([TaskComment].self, forKey: .comments) ?? []
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        blockedByTaskIDs = try container.decodeIfPresent([String].self, forKey: .blockedByTaskIDs) ?? []
    }
}

enum TaskStatus: String, CaseIterable, Codable, Identifiable {
    case notStarted = "Not Started"
    case active = "Active"
    case waiting = "Waiting"
    case blocked = "Blocked"
    case overdue = "Overdue"
    case done = "Done"

    var id: String { rawValue }

    static var editableCases: [TaskStatus] {
        allCases.filter { $0 != .overdue }
    }
}

enum TaskPriority: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    var eventKitValue: Int {
        switch self {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    init(eventKitValue: Int) {
        switch eventKitValue {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

struct TaskDraft: Identifiable, Hashable {
    var reminderID: String?
    var id: String { reminderID ?? "new-\(parentID ?? listID)" }
    var listID: String
    var title = ""
    var notes = ""
    var dueDate: Date?
    var hasDueTime = true
    var alarmOffsetMinutes: Int? = nil
    var additionalAlerts: [ReminderAlert] = []
    var startDate: Date? = nil
    var hasStartTime = false
    var urlText = ""
    var url: URL? {
        get { URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        set { urlText = newValue?.absoluteString ?? "" }
    }
    var hasValidURL: Bool { urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url?.scheme != nil }
    var durationMinutes: Int?
    var location: TaskLocation?
    var isCompleted = false
    var isFlagged = false
    var status: TaskStatus = .notStarted
    var priority: TaskPriority = .none
    var recurrence: RecurrenceRule?
    var tags: [String] = []
    var attachments: [TaskAttachment] = []
    var parentID: String?
    var blockedByTaskIDs: [String] = []

    init(listID: String) {
        self.listID = listID
    }

    init(task: TaskItem) {
        reminderID = task.id
        listID = task.listID
        title = task.title
        notes = task.notes
        dueDate = task.dueDate
        hasDueTime = task.hasDueTime
        alarmOffsetMinutes = task.alarmOffsetMinutes
        additionalAlerts = task.additionalAlerts
        startDate = task.startDate
        hasStartTime = task.hasStartTime
        url = task.url
        durationMinutes = task.durationMinutes
        location = task.location
        isCompleted = task.isCompleted
        isFlagged = task.isFlagged
        status = task.status
        priority = task.priority
        recurrence = task.recurrence
        tags = task.tags
        attachments = task.attachments
        parentID = task.parentID
        blockedByTaskIDs = task.blockedByTaskIDs
    }
}

struct SmartListDefinition: Identifiable, Codable, Hashable {
    static let defaultIcon = "line.3.horizontal.decrease.circle.fill"

    var id = UUID()
    var title: String
    var icon = Self.defaultIcon
    var status: TaskStatus?
    var priority: TaskPriority?
    var dateRange: SmartDateRange?
    var requiredTag: String?
    var listID: String?
    var flaggedOnly = false
    var blockedOnly = false
    var includeCompleted = false
    var matchMode: SmartListMatchMode = .all
    var rules: [SmartTaskFilterRule] = []

    init(
        id: UUID = UUID(),
        title: String,
        icon: String = Self.defaultIcon,
        status: TaskStatus? = nil,
        priority: TaskPriority? = nil,
        dateRange: SmartDateRange? = nil,
        requiredTag: String? = nil,
        listID: String? = nil,
        flaggedOnly: Bool = false,
        blockedOnly: Bool = false,
        includeCompleted: Bool = false,
        matchMode: SmartListMatchMode = .all,
        rules: [SmartTaskFilterRule] = []
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.status = status
        self.priority = priority
        self.dateRange = dateRange
        self.requiredTag = requiredTag
        self.listID = listID
        self.flaggedOnly = flaggedOnly
        self.blockedOnly = blockedOnly
        self.includeCompleted = includeCompleted
        self.matchMode = matchMode
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? Self.defaultIcon
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status)
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority)
        dateRange = try container.decodeIfPresent(SmartDateRange.self, forKey: .dateRange)
        requiredTag = try container.decodeIfPresent(String.self, forKey: .requiredTag)
        listID = try container.decodeIfPresent(String.self, forKey: .listID)
        flaggedOnly = try container.decodeIfPresent(Bool.self, forKey: .flaggedOnly) ?? false
        blockedOnly = try container.decodeIfPresent(Bool.self, forKey: .blockedOnly) ?? false
        includeCompleted = try container.decodeIfPresent(Bool.self, forKey: .includeCompleted) ?? false
        matchMode = try container.decodeIfPresent(SmartListMatchMode.self, forKey: .matchMode) ?? .all
        rules = try container.decodeIfPresent([SmartTaskFilterRule].self, forKey: .rules) ?? []
    }

    func matches(_ task: TaskItem) -> Bool {
        if !includeCompleted && task.isCompleted { return false }
        if let status {
            let dependencyBlocked = blockedOnly && !task.blockedByTaskIDs.isEmpty
            if task.status != status && !dependencyBlocked { return false }
        }
        if let priority, task.priority != priority { return false }
        if let dateRange, !dateRange.matches(task) { return false }
        if let requiredTag, !task.tags.contains(where: { $0.localizedCaseInsensitiveCompare(requiredTag) == .orderedSame }) { return false }
        if let listID, task.listID != listID { return false }
        if flaggedOnly && !task.isFlagged { return false }
        if blockedOnly && status == nil && task.blockedByTaskIDs.isEmpty { return false }
        guard !rules.isEmpty else { return true }
        let outcomes = rules.map { $0.matches(task) }
        return matchMode == .all ? outcomes.allSatisfy { $0 } : outcomes.contains(true)
    }
}

enum SmartListMatchMode: String, Codable, CaseIterable, Identifiable {
    case all = "All rules (AND)"
    case any = "Any rule (OR)"
    var id: String { rawValue }
}

struct SmartTaskFilterRule: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case status = "Status"
        case priority = "Priority"
        case due = "Due date"
        case tag = "Tag"
        case list = "List"
        var id: String { rawValue }
    }

    var id = UUID()
    var field: Field = .status
    var value = TaskStatus.notStarted.rawValue

    func matches(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch field {
        case .status: return task.status.rawValue == value
        case .priority: return task.priority.rawValue == value
        case .tag: return task.tags.contains { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
        case .list: return task.listID == value
        case .due:
            switch value {
            case "Overdue": return task.isOverdue(now: now, calendar: calendar)
            case "Today": return task.dueDate.map { calendar.isDateInToday($0) } ?? false
            case "Tomorrow": return task.dueDate.map { calendar.isDateInTomorrow($0) } ?? false
            case "Next 7 days": return task.isDue(inNextDays: 7, now: now, calendar: calendar)
            case "Next 14 days": return task.isDue(inNextDays: 14, now: now, calendar: calendar)
            case "Next 30 days": return task.isDue(inNextDays: 30, now: now, calendar: calendar)
            case "No date": return task.dueDate == nil
            default: return true
            }
        }
    }

    var choices: [String] {
        switch field {
        case .status: TaskStatus.editableCases.map(\.rawValue)
        case .priority: TaskPriority.allCases.map(\.rawValue)
        case .due: ["Overdue", "Today", "Tomorrow", "Next 7 days", "Next 14 days", "Next 30 days", "No date"]
        case .tag, .list: []
        }
    }
}

extension SmartListDefinition {
    var sharedWidgetDefinition: TaskFlowSharedSmartListDefinition {
        TaskFlowSharedSmartListDefinition(
            id: id.uuidString,
            title: title,
            icon: icon,
            status: status?.rawValue,
            priority: priority?.rawValue,
            dateRange: dateRange?.rawValue,
            requiredTag: requiredTag,
            listID: listID,
            flaggedOnly: flaggedOnly,
            blockedOnly: blockedOnly,
            includeCompleted: includeCompleted,
            matchMode: matchMode.rawValue,
            rules: rules.map { TaskFlowSharedSmartTaskRule(field: $0.field.rawValue, value: $0.value) }
        )
    }
}

enum SmartDateRange: String, CaseIterable, Codable, Identifiable {
    case overdue = "Overdue"
    case today = "Today"
    case tomorrow = "Tomorrow"
    case next7Days = "Next 7 Days"
    case next30Days = "Next 30 Days"
    case noDate = "No Date"

    var id: String { rawValue }

    func matches(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .noDate:
            return task.dueDate == nil
        case .overdue:
            return task.isOverdue(now: now, calendar: calendar)
        case .today:
            guard let dueDate = task.dueDate else { return false }
            return calendar.isDateInToday(dueDate)
        case .tomorrow:
            guard let dueDate = task.dueDate else { return false }
            return calendar.isDateInTomorrow(dueDate)
        case .next7Days:
            return task.isDue(inNextDays: 7, now: now, calendar: calendar)
        case .next30Days:
            return task.isDue(inNextDays: 30, now: now, calendar: calendar)
        }
    }
}

extension TaskItem {
    func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !isCompleted, let dueDate else { return false }
        if hasDueTime {
            return dueDate < now
        }
        return calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: now)
    }

    func isDue(inNextDays days: Int, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let dueDate else { return false }
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        guard dueDay >= today else { return false }
        let end = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return dueDay < end
    }
}

enum PinnedTaskIdentifier {
    static let allTasks = "__taskflow_all_tasks"
    static let upNext = "__taskflow_up_next"
}

enum TaskScope: Hashable, Identifiable, Codable {
    case all
    case inbox
    case notes
    case list(String)
    case smart(UUID)
    case flagged
    case today
    case completed
    case next7Days
    case upNext
    case planMyDay

    var id: String {
        switch self {
        case .all: "all"
        case .inbox: "inbox"
        case .notes: "notes"
        case .list(let id): "list-\(id)"
        case .smart(let id): "smart-\(id.uuidString)"
        case .flagged: "flagged"
        case .today: "today"
        case .completed: "completed"
        case .next7Days: "next-7-days"
        case .upNext: "up-next"
        case .planMyDay: "plan-my-day"
        }
    }
}

enum SmartRescheduleOption: String, CaseIterable, Identifiable {
    case laterToday = "Later Today"
    case tomorrowMorning = "Tomorrow Morning"
    case nextOpenGap = "Next Open Gap"
    case deferOneWeek = "Defer 1 Week"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .laterToday: "clock.badge"
        case .tomorrowMorning: "sunrise.fill"
        case .nextOpenGap: "calendar.badge.clock"
        case .deferOneWeek: "calendar.badge.plus"
        }
    }
}

struct DayTimeGap: Identifiable, Hashable {
    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    let start: Date
    let end: Date
    let nextTitle: String?

    var minutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    var durationText: String {
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(minutes)m"
    }

    var title: String {
        if let nextTitle, !nextTitle.isEmpty {
            return "\(durationText) free before \(nextTitle)"
        }
        return "\(durationText) open after \(start.formatted(date: .omitted, time: .shortened))"
    }
}

struct CalendarWorkspaceSettings: Codable, Equatable {
    var workStart = 9
    var workEnd = 17
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var focusStart = 9
    var focusEnd = 12
    var bufferMinutes = 15
    var compact = false
    var showWeekNumbers = false
    var hideNonworkingHours = false
    var hourHeight: Double = 72

    init() {}

    /// Synced or older values can be out of range; hour grids and steppers build
    /// ranges from them, and an inverted range traps.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalendarWorkspaceSettings()
        workStart = min(max(try container.decodeIfPresent(Int.self, forKey: .workStart) ?? defaults.workStart, 0), 22)
        workEnd = min(max(try container.decodeIfPresent(Int.self, forKey: .workEnd) ?? defaults.workEnd, workStart + 1), 23)
        weekdays = (try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? defaults.weekdays).filter { (1...7).contains($0) }
        focusStart = min(max(try container.decodeIfPresent(Int.self, forKey: .focusStart) ?? defaults.focusStart, 0), 22)
        focusEnd = min(max(try container.decodeIfPresent(Int.self, forKey: .focusEnd) ?? defaults.focusEnd, focusStart + 1), 23)
        bufferMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .bufferMinutes) ?? defaults.bufferMinutes, 0), 60)
        compact = try container.decodeIfPresent(Bool.self, forKey: .compact) ?? defaults.compact
        showWeekNumbers = try container.decodeIfPresent(Bool.self, forKey: .showWeekNumbers) ?? defaults.showWeekNumbers
        hideNonworkingHours = try container.decodeIfPresent(Bool.self, forKey: .hideNonworkingHours) ?? defaults.hideNonworkingHours
        let height = try container.decodeIfPresent(Double.self, forKey: .hourHeight) ?? defaults.hourHeight
        hourHeight = height.isFinite ? min(max(height, 60), 140) : defaults.hourHeight
    }
}

struct SavedCalendarContext: Codable, Identifiable {
    var id = UUID()
    var name: String
    var mode: String
    var calendarIDs: Set<String>
    var listIDs: Set<String>
    var query: String
    var start: Date?
    var end: Date?
}

struct CalendarPlanningSlot: Identifiable, Equatable {
    var start: Date
    var end: Date
    var preferred: Bool
    var id: Date { start }
}

enum CalendarPlanningEngine {
    static func slots(from start: Date, through end: Date, duration: Int, settings: CalendarWorkspaceSettings, events: [CalendarEvent], tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> [CalendarPlanningSlot] {
        guard (1...1440).contains(duration), (0...23).contains(settings.workStart), (1...24).contains(settings.workEnd), settings.workStart < settings.workEnd, start <= end, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end.timeIntervalSince(start) <= 366 * 86400 else { return [] }
        var result: [CalendarPlanningSlot] = []
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            if settings.weekdays.contains(calendar.component(.weekday, from: day)),
               let lower = calendar.date(bySettingHour: settings.workStart, minute: 0, second: 0, of: day),
               let upper = calendar.date(bySettingHour: settings.workEnd, minute: 0, second: 0, of: day) {
                var candidate = lower
                while candidate.addingTimeInterval(Double(duration * 60)) <= upper {
                    let finish = candidate.addingTimeInterval(Double(duration * 60))
                    let buffer = Double(max(0, settings.bufferMinutes)) * 60
                    let eventConflict = events.contains { $0.availability != "Free" && $0.startDate < finish.addingTimeInterval(buffer) && $0.endDate.addingTimeInterval(buffer) > candidate }
                    let taskConflict = tasks.contains { task in
                        guard !task.isCompleted, task.hasDueTime, let due = task.dueDate else { return false }
                        return due < finish && due.addingTimeInterval(Double(max(1, task.durationMinutes ?? 30)) * 60) > candidate
                    }
                    if candidate >= max(now, start), !eventConflict, !taskConflict {
                        let hour = calendar.component(.hour, from: candidate)
                        let focusEnd = calendar.date(bySettingHour: settings.focusEnd, minute: 0, second: 0, of: day) ?? upper
                        result.append(CalendarPlanningSlot(start: candidate, end: finish, preferred: hour >= settings.focusStart && finish <= focusEnd))
                    }
                    candidate = candidate.addingTimeInterval(900)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted { $0.preferred != $1.preferred ? $0.preferred : $0.start < $1.start }
    }

    static func conflicts(events: [CalendarEvent], tasks: [TaskItem], settings: CalendarWorkspaceSettings, calendar: Calendar = .current) -> [String] {
        let timed = events.filter { !$0.isAllDay && $0.availability != "Free" }.sorted { $0.startDate < $1.startDate }
        var messages: [String] = []
        for (index, event) in timed.enumerated() {
            for other in timed.dropFirst(index + 1) {
                guard event.calendarID == other.calendarID else { continue }
                let gap = other.startDate.timeIntervalSince(event.endDate)
                if gap >= Double(max(0, settings.bufferMinutes)) * 60 { break }
                if gap < 0 {
                    messages.append("\(event.title) overlaps \(other.title) on \(other.startDate.formatted(date: .abbreviated, time: .shortened)).")
                } else {
                    messages.append("\(event.title) and \(other.title) have only \(Int(gap / 60)) minutes between them.")
                }
            }
        }
        for task in tasks where !task.isCompleted && task.hasDueTime {
            guard let due = task.dueDate else { continue }
            let startHour = calendar.component(.hour, from: due)
            let end = due.addingTimeInterval(Double(max(1, task.durationMinutes ?? 30)) * 60)
            let workEnd = calendar.date(bySettingHour: settings.workEnd, minute: 0, second: 0, of: due) ?? due
            if !settings.weekdays.contains(calendar.component(.weekday, from: due)) || startHour < settings.workStart || end > workEnd {
                messages.append("\(task.title) is outside working hours on \(due.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        return messages
    }
}


enum ReminderAlert: Codable, Hashable {
    case relative(minutesBefore: Int)
    case absolute(Date)
    var title: String {
        switch self {
        case .relative(let minutes): return minutes == 0 ? "At due time" : minutes < 0 ? "\(-minutes) minutes after" : "\(minutes) minutes before"
        case .absolute(let date): return date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}


/// Optional TaskFlow metadata; native reminder titles, dates, and completion stay in EventKit.
enum SpecializedListType: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard", shopping = "Shopping & Groceries", projects = "Projects & Work"
    case household = "Household & Chores", packing = "Packing & Travel", bills = "Bills & Renewals"
    case reading = "Reading & Watch Later", errands = "Errands", appointments = "Appointments & Follow-ups"
    case routines = "Routines & Checklists"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .standard: "list.bullet"
        case .shopping: "cart"
        case .projects: "briefcase"
        case .household: "house"
        case .packing: "suitcase"
        case .bills: "creditcard"
        case .reading: "book"
        case .errands: "mappin.and.ellipse"
        case .appointments: "calendar"
        case .routines: "checklist"
        }
    }
    var groupField: String {
        switch self {
        case .shopping: "Category"
        case .projects: "Section"
        case .household: "Room"
        case .packing: "Category"
        case .bills: "Provider"
        case .reading: "Progress"
        case .errands: "Destination"
        case .appointments: "Contact"
        case .routines: "Section"
        case .standard: "Section"
        }
    }
    var fields: [String] {
        switch self {
        case .standard: []
        case .shopping: ["Quantity", "Unit", "Category", "Store", "Price", "Substitute"]
        case .projects: ["Section", "Milestone", "Outcome", "Blocked Reason", "Next Action"]
        case .household: ["Room", "Instructions", "Season"] 
        case .packing: ["Quantity", "Category", "Essential"] 
        case .bills: ["Amount", "Currency", "Provider", "Payment Link", "Renewal Date", "Notice Date", "Cancellation Deadline", "Payment Confirmation"]
        case .reading: ["Creator", "Format", "Source Link", "Rating", "Progress Detail", "Estimated Minutes", "Thumbnail URL"]
        case .errands: ["Destination", "Opening Hours", "Before Leaving", "Shopping List ID"]
        case .appointments: ["Contact", "Questions", "Preparation", "Follow-up Date", "Outcome"]
        case .routines: ["Section", "Step Order", "Instructions", "Timer Minutes", "Required"]
        }
    }
    /// Bill dates that get automatic reminders.
    static let billDeadlineFields = ["Renewal Date", "Notice Date", "Cancellation Deadline"]
    var stages: [String] {
        switch self {
        case .packing: ["Not Prepared", "Prepared", "Packed"]
        case .bills: ["Unpaid", "Paid", "Canceled"]
        case .reading: ["Saved", "In Progress", "Finished"]
        default: []
        }
    }
}

struct SpecializedListProfile: Codable, Hashable {
    var type: SpecializedListType = .standard
    var settings: [String: String] = [:]
}
typealias SpecializedTaskDetails = TaskFlowSharedShoppingDetails

extension TaskFlowSharedShoppingDetails {
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func dateValue(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text)
    }
    var summary: String {
        [fields["Quantity"], fields["Unit"], fields["Store"], fields["Destination"], fields["Progress"], fields["Stage"], fields["Amount"], fields["Currency"], fields["Creator"], fields["Milestone"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
struct SpecializedListTemplate: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var listID: String
    var items: [Item]
    struct Item: Codable, Hashable {
        var title: String
        var notes: String
        var details: SpecializedTaskDetails
    }
}

/// Human-friendly presentation of the stored `yyyy-MM-dd` and amount fields.
enum SpecializedFieldFormat {
    /// Whole days from `now`'s day to `date`'s day; negative in the past.
    static func dayOffset(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "Oct 5 · in 3 days", "Today", "Yesterday", or nil for an empty or invalid value.
    static func date(_ text: String?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let text, let date = SpecializedTaskDetails.dateValue(text) else { return nil }
        let offset = dayOffset(date, now: now, calendar: calendar)
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let day = sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
            guard abs(offset) <= 60 else { return day }
            return day + " · " + (offset > 0 ? "in \(offset) days" : "\(-offset) days ago")
        }
    }

    /// Amount formatted in its ISO currency when recognized, otherwise as a plain number.
    static func amount(_ value: Double, currency: String?) -> String {
        let code = (currency ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.count == 3, Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code }) { return value.formatted(.currency(code: code)) }
        let number = value.formatted(.number.precision(.fractionLength(2)))
        return code.isEmpty ? number : number + " " + code
    }
}


struct ShoppingCaptureItem: Equatable {
    var title: String
    var quantity: String = ""
    var category: String
}
enum ShoppingCatalog {
    static let categories = ["Produce", "Dairy & Eggs", "Meat & Seafood", "Bakery", "Deli & Prepared Foods", "Pantry", "Frozen Foods", "Snacks & Candy", "Breakfast & Cereal", "Baking Supplies", "Condiments & Spices", "Canned & Jarred Goods", "Beverages", "Cleaning Supplies", "Paper & Disposable Goods", "Household", "Personal Care", "Health & Pharmacy", "Baby & Kids", "Pet Supplies", "Home Improvement", "Garden & Outdoor", "Clothing & Accessories", "Other"]
    static func canonicalCategory(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.localizedCaseInsensitiveCompare("Frozen") == .orderedSame { return "Frozen Foods" }
        if name.localizedCaseInsensitiveCompare("Snacks") == .orderedSame { return "Snacks & Candy" }
        return categories.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
    }
    static func category(for title: String) -> String {
        let normalized = title.lowercased()
        let phrases: [(String, [String])] = [
            ("Pet Supplies", ["dog food", "cat food", "pet food", "cat litter", "dog treats"]),
            ("Paper & Disposable Goods", ["paper towels", "toilet paper", "trash bags", "paper plates", "aluminum foil"]),
            ("Baby & Kids", ["baby food", "baby formula", "baby wipes"]),
            ("Frozen Foods", ["ice cream", "frozen "]),
            ("Deli & Prepared Foods", ["deli ", "rotisserie chicken", "prepared meal"]),
            ("Canned & Jarred Goods", ["canned ", "jarred "]),
            ("Breakfast & Cereal", ["breakfast bars"])]
        if let category = phrases.first(where: { $0.1.contains(where: { normalized.contains($0) }) })?.0 { return category }
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let rules: [(String, Set<String>)] = [
            ("Health & Pharmacy", ["medicine", "vitamins", "ibuprofen", "acetaminophen", "bandages"]),
            ("Baby & Kids", ["diapers", "formula", "pacifiers"]),
            ("Pet Supplies", ["kibble", "litter"]),
            ("Home Improvement", ["screws", "nails", "hammer", "screwdriver", "caulk", "insulation"]),
            ("Garden & Outdoor", ["soil", "mulch", "fertilizer", "plants"]),
            ("Clothing & Accessories", ["socks", "shirts", "pants", "gloves"]),
            ("Cleaning Supplies", ["detergent", "cleaner", "bleach", "disinfectant"]),
            ("Paper & Disposable Goods", ["tissues", "napkins", "foil"]),
            ("Breakfast & Cereal", ["cereal", "oatmeal", "granola"]),
            ("Baking Supplies", ["flour", "sugar", "yeast", "vanilla"]),
            ("Condiments & Spices", ["ketchup", "mustard", "mayonnaise", "dressing", "cinnamon", "paprika", "seasoning"]),
            ("Canned & Jarred Goods", ["soup", "pickles"]),
            ("Dairy & Eggs", ["milk", "eggs", "egg", "cheese", "yogurt", "butter", "cream"]),
            ("Produce", ["apple", "apples", "banana", "bananas", "lettuce", "tomato", "tomatoes", "potato", "potatoes", "onion", "onions", "carrots", "spinach"]),
            ("Meat & Seafood", ["chicken", "beef", "pork", "salmon", "fish", "shrimp"]),
            ("Bakery", ["bread", "bagels", "rolls", "tortillas"]),
            ("Beverages", ["coffee", "tea", "juice", "water", "soda"]),
            ("Household", ["detergent", "towels", "trash", "cleaner"]),
            ("Personal Care", ["toothpaste", "shampoo", "deodorant", "soap"]),
            ("Pantry", ["rice", "pasta", "flour", "sugar", "oil", "beans"]),
            ("Snacks & Candy", ["chips", "crackers", "cookies", "nuts", "candy", "chocolate"])]
        return rules.first { !$0.1.isDisjoint(with: words) }?.0 ?? "Other"
    }
    static func parse(_ text: String) -> [ShoppingCaptureItem] {
        text.components(separatedBy: .newlines).compactMap { line in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "•-" )).trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            let parts = clean.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if parts.count == 2, let value = Double(parts[0]), value.isFinite, value > 0 {
                let title = String(parts[1]); return ShoppingCaptureItem(title: title, quantity: String(parts[0]), category: category(for: title))
            }
            return ShoppingCaptureItem(title: clean, category: category(for: clean))
        }
    }
}

/// Checklist state stays in the note text, so sharing, undo, and cloud sync preserve it.
struct NoteRevision: Identifiable, Codable, Hashable {
    var id = UUID()
    var savedAt: Date
    var snapshot: QuickNote
    init(note: QuickNote, savedAt: Date = Date()) {
        self.savedAt = savedAt
        snapshot = note
        snapshot.versions = []
    }
}

struct NoteEditorRecovery: Identifiable, Codable, Equatable {
    var id: UUID
    var originalNoteID: UUID?
    var note: QuickNote
    var savedAt = Date()
    var pendingURL: String? = nil
}

extension QuickNote {
    var hasUnfinishedChecklist: Bool {
        NoteChecklist.items(in: text).contains { !$0.isChecked } && format == .checklist ||
        (format == .markdown && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") })
    }
    func versioned(replacing old: QuickNote, now: Date = Date(), forceCheckpoint: Bool = false) -> QuickNote {
        var result = self
        result.versions = old.versions
        if forceCheckpoint || old.versions.isEmpty || now.timeIntervalSince(old.versions.last!.savedAt) >= 60 {
            result.versions.append(NoteRevision(note: old, savedAt: now))
            result.versions = Array(result.versions.suffix(50))
            // Bound retained payload as well as count. Keep the most recent
            // checkpoint even when one individual drawing exceeds the budget.
            var retainedBytes = result.versions.reduce(0) { $0 + $1.snapshot.historyPayloadBytes }
            while result.versions.count > 1 && retainedBytes > 4 * 1024 * 1024 {
                retainedBytes -= result.versions.removeFirst().snapshot.historyPayloadBytes
            }
        }
        result.updatedAt = now
        return result
    }
}


struct NoteDocumentLine: Identifiable, Equatable {
    var id: Int
    var source: String
    var headingLevel: Int
    var checkbox: NoteChecklist.Item?
    var displayText: String {
        NoteRenderingCache.displayText(for: self)
    }
    fileprivate var uncachedDisplayText: String {
        let content = checkbox?.title ?? (headingLevel > 0 ? String(source.trimmingCharacters(in: .whitespaces).dropFirst(headingLevel + 1)) : source)
        return (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? content
    }
}

enum NoteDocument {
    static func lines(_ text: String, format: QuickNoteFormat) -> [NoteDocumentLine] {
        NoteRenderingCache.lines(text, format: format)
    }
    fileprivate static func uncachedLines(_ text: String, format: QuickNoteFormat) -> [NoteDocumentLine] {
        let checklist = Dictionary(uniqueKeysWithValues: NoteChecklist.items(in: text).map { ($0.id, $0) })
        return text.components(separatedBy: "\n").enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let count = trimmed.prefix { $0 == "#" }.count
            let heading = (1...6).contains(count) && trimmed.dropFirst(count).hasPrefix(" ") ? count : 0
            let checkbox = (format == .checklist || (format == .markdown && NoteChecklist.isCheckboxLine(line))) ? checklist[index] : nil
            return NoteDocumentLine(id: index, source: line, headingLevel: heading, checkbox: checkbox)
        }
    }
}

struct NoteSearchMatch: Identifiable, Equatable {
    var id: Int
    var lineID: Int
    var ordinalWithinLine: Int
}

enum NoteSearch {
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            guard !range.isEmpty else { break }
            matches.append(range)
            start = range.upperBound
        }
        return matches
    }
    static func matches(note: QuickNote, query: String) -> [NoteSearchMatch] {
        guard !query.isEmpty else { return [] }
        return NoteRenderingCache.matches(note: note, query: query)
    }
    fileprivate static func uncachedMatches(note: QuickNote, query: String) -> [NoteSearchMatch] {
        var matches: [NoteSearchMatch] = []
        let values = [(-1, note.title)] + NoteDocument.lines(note.text, format: note.format).map { ($0.id, $0.displayText) }
        for (id, text) in values {
            for index in ranges(in: text, query: query).indices {
                matches.append(NoteSearchMatch(id: matches.count, lineID: id, ordinalWithinLine: index))
            }
        }
        return matches
    }
}

enum NotesCollection: String, CaseIterable, Identifiable {
    case all = "All Notes"
    case pinned = "Pinned"
    case linked = "Linked to Tasks"
    case unfinished = "Unfinished Checklists"
    var id: String { rawValue }
}


extension NoteDocument {
    static func presentedLines(_ text: String, format: QuickNoteFormat, hideCompleted: Bool, completedLast: Bool, collapsed: Set<Int>) -> [NoteDocumentLine] {
        var output: [NoteDocumentLine] = []
        var section: [NoteDocumentLine] = []
        var hidden = false
        func flush() {
            if completedLast { output += section.filter { $0.checkbox?.isChecked != true } + section.filter { $0.checkbox?.isChecked == true } }
            else { output += section }
            section = []
        }
        for line in lines(text, format: format) {
            if line.headingLevel > 0 {
                flush()
                hidden = collapsed.contains(line.id)
                output.append(line)
            } else if !hidden && (!hideCompleted || line.checkbox?.isChecked != true) {
                section.append(line)
            }
        }
        flush()
        return output
    }
}

// NSCache bounds retained content and releases it under memory pressure. Keys use
// complete source strings, so edited notes cannot reuse stale parsed content.
private enum NoteRenderingCache {
    private final class Box<T>: NSObject { let value: T; init(_ value: T) { self.value = value } }
    private static let documents: NSCache<NSString, Box<[NoteDocumentLine]>> = {
        let cache = NSCache<NSString, Box<[NoteDocumentLine]>>()
        cache.countLimit = 32; cache.totalCostLimit = 2_000_000; return cache
    }()
    private static let text: NSCache<NSString, Box<String>> = {
        let cache = NSCache<NSString, Box<String>>()
        cache.countLimit = 512; cache.totalCostLimit = 1_000_000; return cache
    }()
    private static let searches: NSCache<NSArray, Box<[NoteSearchMatch]>> = {
        let cache = NSCache<NSArray, Box<[NoteSearchMatch]>>()
        cache.countLimit = 16; cache.totalCostLimit = 1_000_000; return cache
    }()
    static func lines(_ source: String, format: QuickNoteFormat) -> [NoteDocumentLine] {
        let key = (format.rawValue + "\n" + source) as NSString
        if let result = documents.object(forKey: key) { return result.value }
        let result = NoteDocument.uncachedLines(source, format: format)
        documents.setObject(Box(result), forKey: key, cost: source.utf8.count * 3)
        return result
    }
    static func displayText(for line: NoteDocumentLine) -> String {
        let key = (String(line.headingLevel) + "\n" + (line.checkbox?.title ?? line.source)) as NSString
        if let result = text.object(forKey: key) { return result.value }
        let result = line.uncachedDisplayText
        text.setObject(Box(result), forKey: key, cost: key.length * 4)
        return result
    }
    static func matches(note: QuickNote, query: String) -> [NoteSearchMatch] {
        let key = [note.title, note.text, note.format.rawValue, query] as NSArray
        if let result = searches.object(forKey: key) { return result.value }
        let result = NoteSearch.uncachedMatches(note: note, query: query)
        searches.setObject(Box(result), forKey: key, cost: note.text.utf8.count + result.count * 24)
        return result
    }
}

/// Instruments Points of Interest for comparing identical device workloads.
enum TaskFlowPerformance {
    private static let log = OSLog(subsystem: "com.surratt.TaskFlow", category: .pointsOfInterest)
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }
    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}

private extension QuickNote {
    var historyPayloadBytes: Int {
        title.utf8.count + text.utf8.count + (drawingData?.count ?? 0) +
        tags.reduce(0) { $0 + $1.utf8.count } + attachments.count * 512
    }
}

extension TaskAttachment {
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let input = trimmed.hasPrefix("//") ? "https:" + trimmed : (trimmed.contains("://") ? trimmed : "https://" + trimmed)
        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }), !host.contains("%"),
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        return components.url
    }
}

extension QuickNote {
    /// Called once when committing the URL field, so drafts retain stable IDs and
    /// repeated Save/Submit cannot create duplicate attachment records.
    func addingURLAttachment(_ text: String) -> QuickNote? {
        guard let url = TaskAttachment.webURL(from: text) else { return nil }
        var result = self
        if !attachments.contains(where: { $0.kind == .url && TaskAttachment.webURL(from: $0.urlString ?? "") == url }) {
            result.attachments.append(TaskAttachment(kind: .url, title: url.host ?? "Web link", urlString: url.absoluteString))
        }
        return result
    }
}

/// Preserve Markdown styling and explicit links while making bare URLs tappable.
enum NoteTextFormatting {
    private final class Box: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    private static let cache: NSCache<NSString, Box> = {
        let value = NSCache<NSString, Box>()
        value.countLimit = 512; value.totalCostLimit = 1_000_000
        return value
    }()
    static func inline(_ source: String) -> AttributedString {
        if let result = cache.object(forKey: source as NSString) { return result.value }
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let result = addingDetectedLinks(to: parsed)
        cache.setObject(Box(result), forKey: source as NSString, cost: source.utf8.count * 4)
        return result
    }
    static func addingDetectedLinks(to text: AttributedString) -> AttributedString {
        var result = text
        let plain = String(text.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..<plain.endIndex, in: plain)) {
            guard let url = match.url, let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            if result[lower..<upper].link == nil { result[lower..<upper].link = url }
        }
        return result
    }
}

enum EventDeletionScope: String, Equatable {
    case thisEvent
    case thisAndFuture
}

struct EventDeletion: Equatable {
    let token = UUID()
    let eventID: String
    let startDate: Date
    let scope: EventDeletionScope
    func includes(_ event: CalendarEvent) -> Bool {
        guard event.id == eventID else { return false }
        return scope == .thisEvent ? event.startDate == startDate : event.startDate >= startDate
    }
}

enum SystemEventEditorOutcome {
    case canceled
    case saved(String?)
    case deleted(EventDeletion)
}


enum ShoppingQuantity {
    static func value(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return 1 }
        guard let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return value
    }
    static func text(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...6)))
    }
    static func cost(_ fields: [String: String]) -> Double? {
        guard let quantity = value(fields["Quantity"]), let price = Double(fields["Price"] ?? ""), price.isFinite, price >= 0 else { return nil }
        let total = quantity * price
        return total.isFinite ? total : nil
    }
    static func key(title: String, fields: [String: String]) -> String {
        [title, fields["Store"] ?? "", fields["Unit"] ?? ""].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }.joined(separator: "\u{001F}")
    }
}


enum ShoppingPriceInput {
    static func value(_ text: String, locale: Locale = .current) -> Double? {
        let separator = locale.decimalSeparator ?? "."
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.replacingOccurrences(of: separator, with: ".").map { character in
            character.wholeNumberValue.map(String.init) ?? String(character)
        }.joined()
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        guard let value = Double(normalized), value.isFinite, value >= 0 else { return nil }
        return value
    }
}
