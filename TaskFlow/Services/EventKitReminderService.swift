@preconcurrency import EventKit
import Foundation
import CoreLocation
import SwiftUI

enum ReminderAccessState: Equatable {
    case unknown
    case granted
    case denied
    case restricted

    var message: String {
        switch self {
        case .unknown: "TaskFlow Studio needs Reminders access to load and save tasks."
        case .granted: "Reminders access granted."
        case .denied: "Reminders access is denied. Enable it in Settings to sync with Apple Reminders."
        case .restricted: "Reminders access is restricted on this device."
        }
    }
}

enum EventCalendarAccessState: String, Equatable {
    case unknown = "Not Requested"
    case granted = "Granted"
    case denied = "Denied"
    case restricted = "Restricted"

    var message: String {
        switch self {
        case .unknown: "TaskFlow Studio needs Calendar access to show events alongside due tasks."
        case .granted: "Calendar access granted."
        case .denied: "Calendar access is denied. Enable it in Settings to show events."
        case .restricted: "Calendar access is restricted on this device."
        }
    }
}

@MainActor
final class EventKitReminderService {
    private let store = EKEventStore()
    private let calendar = Calendar(identifier: .gregorian)
    private var pendingMetadata: [(String, String, TaskDraft)] = []

    var authorizationState: ReminderAccessState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .writeOnly: .denied
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    var eventAuthorizationState: EventCalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .denied
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    func requestAccess() async -> ReminderAccessState {
        guard authorizationState == .unknown else { return authorizationState }

        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await withCheckedContinuation { continuation in
                store.requestFullAccessToReminders { isGranted, _ in
                    continuation.resume(returning: isGranted)
                }
            }
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { isGranted, _ in
                    continuation.resume(returning: isGranted)
                }
            }
        }

        return granted ? .granted : authorizationState
    }

    func requestEventAccess() async -> EventCalendarAccessState {
        guard eventAuthorizationState == .unknown || EKEventStore.authorizationStatus(for: .event) == .writeOnly else { return eventAuthorizationState }

        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { isGranted, _ in
                    continuation.resume(returning: isGranted)
                }
            }
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { isGranted, _ in
                    continuation.resume(returning: isGranted)
                }
            }
        }

        return granted ? .granted : eventAuthorizationState
    }

    /// Shared with Apple's event editor so it edits the same store TaskFlow reads from.
    var eventStore: EKEventStore { store }

    /// An existing event for editing, or a new one prefilled from a draft, for `EKEventEditViewController`.
    private func existingEvent(for draft: EventDraft) -> EKEvent? {
        guard let id = draft.eventID else { return nil }
        if let original = draft.originalStartDate {
            let predicate = store.predicateForEvents(withStart: original.addingTimeInterval(-1), end: original.addingTimeInterval(1), calendars: nil)
            return store.events(matching: predicate).first { $0.eventIdentifier == id && $0.startDate == original }
        }
        return store.event(withIdentifier: id)
    }

    func systemEvent(for draft: EventDraft) -> EKEvent {
        let event = existingEvent(for: draft) ?? EKEvent(eventStore: store)
        let oldAlarm = draft.eventID == nil ? nil : Self.eventAlarmOffset(event.alarms ?? [], start: event.startDate)
        event.title = draft.normalizedTitle
        event.notes = draft.normalizedNotes
        event.location = draft.normalizedLocation
        event.isAllDay = draft.isAllDay
        event.startDate = draft.isAllDay ? Calendar.current.startOfDay(for: draft.startDate) : draft.startDate
        event.endDate = draft.isAllDay ? (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(draft.endDate, draft.startDate))) ?? draft.endDate) : max(draft.endDate, draft.startDate.addingTimeInterval(60))
        event.calendar = eventCalendar(withID: draft.calendarID) ?? store.defaultCalendarForNewEvents
        if let calendar = event.calendar, !calendar.supportedEventAvailabilities.isEmpty { event.availability = ekAvailability(from: draft.availability) }
        event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier)
        if draft.eventID == nil || oldAlarm != draft.alarmOffsetMinutes { event.alarms = draft.alarmOffsetMinutes.map { [EKAlarm(relativeOffset: -TimeInterval($0) * 60)] } }
        if draft.eventID == nil { event.recurrenceRules = draft.recurrence.map { [eventKitRule(from: $0)] } }
        return event
    }
    /// Calendar identifiers can differ by device. Only map an unambiguous account/list name.
    func cloudListIdentities() -> [String: String] {
        guard authorizationState == .granted else { return [:] }
        let pairs = store.calendars(for: .reminder).map { calendar in
            let parts = [String(calendar.source.sourceType.rawValue), calendar.source.title, calendar.title]
            let identity = "cloud-list:" + ((try? JSONEncoder().encode(parts)) ?? Data()).base64EncodedString()
            return (calendar.calendarIdentifier, identity)
        }
        let counts = Dictionary(grouping: pairs, by: { $0.1 }).mapValues(\.count)
        return Dictionary(pairs.filter { counts[$0.1] == 1 }, uniquingKeysWith: { first, _ in first })
    }

    func cloudEventCalendarIdentities() -> [String: String] {
        guard eventAuthorizationState == .granted else { return [:] }
        let pairs = store.calendars(for: .event).compactMap { calendar -> (String, String)? in
            let parts = [String(calendar.source.sourceType.rawValue), calendar.source.title, calendar.title]
            guard let data = try? JSONEncoder().encode(parts) else { return nil }
            return (calendar.calendarIdentifier, "cloud-calendar:" + data.base64EncodedString())
        }
        let counts = Dictionary(grouping: pairs, by: { $0.1 }).mapValues(\.count)
        return Dictionary(pairs.filter { counts[$0.1] == 1 }, uniquingKeysWith: { first, _ in first })
    }

    func loadLists() -> [TaskList] {
        store.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .map {
                TaskList(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    color: Color(cgColor: $0.cgColor)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func loadEventCalendars() -> [EventCalendar] {
        guard eventAuthorizationState == .granted else { return [] }
        return store.calendars(for: .event)
            .map {
                EventCalendar(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    color: Color(cgColor: $0.cgColor),
                    allowsModifications: $0.allowsContentModifications,
                    supportsAvailability: !$0.supportedEventAvailabilities.isEmpty
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func loadEvents(from startDate: Date, to endDate: Date, calendarIDs: Set<String>) -> [CalendarEvent] {
        guard eventAuthorizationState == .granted, !calendarIDs.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return store.events(matching: predicate)
            .compactMap { event -> EKEvent? in
                // These are implicitly unwrapped and can be nil for events in flux (e.g. mid-sync); reading nil traps.
                event.eventIdentifier == nil || event.calendar == nil || event.startDate == nil || event.endDate == nil ? nil : event
            }
            .map {
                CalendarEvent(
                    id: $0.eventIdentifier,
                    calendarID: $0.calendar.calendarIdentifier,
                    title: $0.title,
                    location: $0.location,
                    notes: $0.notes,
                    url: $0.url,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    availability: $0.availability == .free ? "Free" : $0.availability == .busy ? "Busy" : $0.availability == .tentative ? "Tentative" : $0.availability == .unavailable ? "Unavailable" : nil,
                    alarmOffsetMinutes: Self.eventAlarmOffset($0.alarms ?? [], start: $0.startDate),
                    timeZoneIdentifier: $0.timeZone?.identifier,
                    recurrenceSummary: $0.recurrenceRules?.first.map { recurrenceRule(from: $0).summary },
                    recurrence: $0.recurrenceRules?.first.map(recurrenceRule(from:)),
                    calendarSource: $0.calendar.source.title,
                    organizerName: $0.organizer?.name,
                    attendees: $0.attendees?.compactMap { p in
                        EventParticipant(
                            name: p.name ?? "Participant",
                            email: p.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                            role: p.participantRole == .chair ? "Organizer" : p.participantRole == .required ? "Required" : p.participantRole == .optional ? "Optional" : "Participant",
                            status: p.participantStatus == .accepted ? "Accepted" : p.participantStatus == .declined ? "Declined" : p.participantStatus == .tentative ? "Tentative" : "Pending",
                            isCurrentUser: p.isCurrentUser
                        )
                    } ?? [],
                    attachments: [],
                    structuredLocation: $0.structuredLocation.map { loc in
                        TaskLocation(
                            title: loc.title ?? "",
                            address: loc.title ?? "",
                            latitude: loc.geoLocation?.coordinate.latitude,
                            longitude: loc.geoLocation?.coordinate.longitude
                        )
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    @discardableResult
    func availabilityOptions(calendarID: String) -> [EventAvailability] {
        guard eventAuthorizationState == .granted, let calendar = eventCalendar(withID: calendarID) else { return [] }
        let supported = calendar.supportedEventAvailabilities
        return EventAvailability.allCases.filter {
            switch $0 {
            case .busy: return supported.contains(.busy)
            case .free: return supported.contains(.free)
            case .tentative: return supported.contains(.tentative)
            case .unavailable: return supported.contains(.unavailable)
            }
        }
    }

    func setAvailability(_ value: EventAvailability, for item: CalendarEvent) throws -> String {
        guard eventAuthorizationState == .granted,
              let calendar = eventCalendar(withID: item.calendarID), calendar.allowsContentModifications,
              availabilityOptions(calendarID: item.calendarID).contains(value) else {
            throw NSError(domain: "TaskFlow.Calendar", code: 3, userInfo: [NSLocalizedDescriptionKey: "This calendar does not allow that availability setting."])
        }
        let predicate = store.predicateForEvents(withStart: item.startDate.addingTimeInterval(-1), end: max(item.endDate, item.startDate.addingTimeInterval(1)), calendars: [calendar])
        guard let event = store.events(matching: predicate).first(where: { $0.eventIdentifier == item.id && $0.startDate == item.startDate }) else {
            throw NSError(domain: "TaskFlow.Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "This event is no longer available. Refresh the calendar and try again."])
        }
        event.availability = ekAvailability(from: value.rawValue)
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? item.id
    }

    func saveEvent(_ draft: EventDraft, commit: Bool = true) throws -> String {
        do { return try saveEventImpl(draft, commit: commit) }
        catch { store.reset(); throw error }
    }

    private func saveEventImpl(_ draft: EventDraft, commit: Bool) throws -> String {
        let event: EKEvent
        if draft.eventID != nil {
            guard let existingEvent = existingEvent(for: draft) else {
                throw NSError(
                    domain: "TaskFlow.EventKitReminderService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The calendar event could not be found."]
                )
            }
            event = existingEvent
        } else {
            event = EKEvent(eventStore: store)
        }

        guard let targetCalendar = eventCalendar(withID: draft.calendarID), targetCalendar.allowsContentModifications,
              event.calendar == nil || event.calendar.allowsContentModifications else {
            throw NSError(domain: "TaskFlow.Calendar", code: 2, userInfo: [NSLocalizedDescriptionKey: "This calendar is read-only or no longer available."])
        }
        let originalAlarmOffset = draft.eventID == nil ? nil : Self.eventAlarmOffset(event.alarms ?? [], start: event.startDate)
        event.title = draft.normalizedTitle
        event.notes = draft.normalizedNotes
        event.location = draft.normalizedLocation
        event.isAllDay = draft.isAllDay
        if !targetCalendar.supportedEventAvailabilities.isEmpty {
            event.availability = ekAvailability(from: draft.availability)
        }
        if let tz = TimeZone(identifier: draft.timeZoneIdentifier) {
            event.timeZone = tz
        }
        event.startDate = draft.isAllDay ? Calendar.current.startOfDay(for: draft.startDate) : draft.startDate

        if draft.isAllDay {
            let endDay = Calendar.current.startOfDay(for: draft.endDate)
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: max(endDay, event.startDate)) ?? event.startDate
        } else {
            guard draft.endDate > draft.startDate else {
                throw NSError(domain: "TaskFlow.Calendar", code: 4, userInfo: [NSLocalizedDescriptionKey: "End time must be after start time."])
            }
            event.endDate = draft.endDate
        }

        if draft.eventID == nil || originalAlarmOffset != draft.alarmOffsetMinutes {
            event.alarms = draft.alarmOffsetMinutes.map { [EKAlarm(relativeOffset: -TimeInterval($0) * 60)] }
        }

        let originalRule = event.recurrenceRules?.first.map(recurrenceRule(from:))
        if originalRule != draft.recurrence { event.recurrenceRules = draft.recurrence.map { [eventKitRule(from: $0)] } }

        if let loc = draft.structuredLocation {
            let structured = EKStructuredLocation(title: loc.displayTitle)
            if let lat = loc.latitude, let lon = loc.longitude {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            event.structuredLocation = structured
        } else { event.structuredLocation = nil }

        event.calendar = targetCalendar
        try store.save(event, span: .thisEvent, commit: commit)
        return event.eventIdentifier ?? event.calendarItemIdentifier
    }

    func saveEvents(_ drafts: [EventDraft]) throws -> [String] {
        do {
            let ids = try drafts.map { try saveEventImpl($0, commit: false) }
            try store.commit()
            return ids
        } catch {
            store.reset()
            throw error
        }
    }

    func deleteEvent(_ event: CalendarEvent, scope: EventDeletionScope) throws {
        guard eventAuthorizationState == .granted else { throw CocoaError(.fileWriteNoPermission) }
        guard let existing = existingEvent(for: EventDraft(event: event)) else { return } // Already removed elsewhere.
        guard existing.calendar.allowsContentModifications else { throw CocoaError(.fileWriteNoPermission) }
        do {
            try store.remove(existing, span: scope == .thisEvent ? .thisEvent : .futureEvents, commit: true)
        } catch {
            store.reset()
            throw error
        }
    }

    func deleteEvents(ids: [String]) throws {
        do {
            for id in ids {
                if let event = store.event(withIdentifier: id) {
                    try store.remove(event, span: .thisEvent, commit: false)
                }
            }
            try store.commit()
        } catch {
            // Drop staged removals so a later commit cannot apply a half-finished batch.
            store.reset()
            throw error
        }
    }

    private func ekAvailability(from availability: String) -> EKEventAvailability {
        switch availability {
        case "Free": return .free
        case "Busy": return .busy
        case "Tentative": return .tentative
        case "Unavailable": return .unavailable
        default: return .busy
        }
    }

    static func alarmMinutes(_ seconds: TimeInterval) -> Int? {
        Int(exactly: (seconds / 60).rounded(.towardZero))
    }

    static func decodeTimeAlarms(_ alarms: [EKAlarm]) -> (Int?, [ReminderAlert]) {
        let timeAlarms = alarms.filter { $0.structuredLocation == nil }
        let primary = timeAlarms.firstIndex { $0.absoluteDate == nil && alarmMinutes(-$0.relativeOffset) != nil }
        let offset = primary.flatMap { alarmMinutes(-timeAlarms[$0].relativeOffset) }
        let additional: [ReminderAlert] = timeAlarms.enumerated().compactMap { index, alarm in
            guard index != primary else { return nil }
            if let date = alarm.absoluteDate { return date.timeIntervalSince1970.isFinite ? .absolute(date) : nil }
            guard let minutes = alarmMinutes(-alarm.relativeOffset) else { return nil }
            return .relative(minutesBefore: minutes)
        }
        return (offset, additional)
    }

    static func decodeLocation(_ alarms: [EKAlarm]) -> TaskLocation? {
        guard let alarm = alarms.first(where: { $0.structuredLocation != nil }), let location = alarm.structuredLocation else { return nil }
        return TaskLocation(title: location.title ?? "", address: location.title ?? "", latitude: location.geoLocation?.coordinate.latitude, longitude: location.geoLocation?.coordinate.longitude, proximity: alarm.proximity == .leave ? .onDeparture : .onArrival, radius: location.radius)
    }

    static func eventAlarmOffset(_ alarms: [EKAlarm], start: Date) -> Int? {
        guard let alarm = alarms.first(where: { $0.structuredLocation == nil }) else { return nil }
        if let date = alarm.absoluteDate { return alarmMinutes(start.timeIntervalSince(date)) }
        return alarmMinutes(-alarm.relativeOffset)
    }

    func updateList(id: String, title: String, color: Color) throws {
        guard let list = calendar(withID: id), list.allowsContentModifications else {
            throw NSError(domain: "TaskFlow.Reminders", code: 6, userInfo: [NSLocalizedDescriptionKey: "This list is unavailable or read-only."])
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        list.title = trimmed
        if let cgColor = color.cgColor { list.cgColor = cgColor }
        try store.saveCalendar(list, commit: true)
    }

    func createList(named title: String) throws {
        let reminderList = EKCalendar(for: .reminder, eventStore: store)
        reminderList.title = title
        reminderList.source = bestReminderSource()
        reminderList.cgColor = CGColor(red: 0.16, green: 0.46, blue: 0.92, alpha: 1)
        try store.saveCalendar(reminderList, commit: true)
    }

    func loadTasks(metadataStore: MetadataStore) async -> [TaskItem] {
        let predicate = store.predicateForReminders(in: nil)
        let reminders = await withUnsafeContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        let items = metadataStore.performBatchUpdates { reminders.map { reminder in
            let id = reminder.calendarItemIdentifier
            let metadataID = Self.metadataID(for: reminder)
            var metadata = metadataStore.metadata(for: id, cloudID: metadataID)
            if !reminder.isCompleted && metadata.status == .done {
                metadata.status = .notStarted
                metadataStore.setMetadata(metadata, for: metadataID)
            }
            let dueDate = reminder.dueDateComponents?.date
            let hasDueTime = reminder.dueDateComponents?.hour != nil
            let isOverdue = Self.isOverdue(dueDate: dueDate, hasDueTime: hasDueTime, isCompleted: reminder.isCompleted)

            let (alarmOffset, additionalAlerts) = Self.decodeTimeAlarms(reminder.alarms ?? [])
            let location = Self.decodeLocation(reminder.alarms ?? []) ?? metadata.location

            let parentID = metadata.parentID
            let shoppingNotes = ShoppingReminderNotes.decode(reminder.notes ?? "")

            return TaskItem(
                id: id,
                metadataID: metadataID,
                listID: reminder.calendar.calendarIdentifier,
                title: reminder.title,
                notes: shoppingNotes.text,
                dueDate: dueDate,
                hasDueTime: hasDueTime,
                alarmOffsetMinutes: alarmOffset,
                additionalAlerts: additionalAlerts,
                startDate: reminder.startDateComponents?.date,
                hasStartTime: reminder.startDateComponents?.hour != nil,
                url: reminder.url,
                durationMinutes: metadata.durationMinutes,
                location: location,
                isCompleted: reminder.isCompleted,
                completedAt: reminder.completionDate,
                isFlagged: metadata.isFlagged,
                status: reminder.isCompleted ? .done : Self.displayStatus(for: metadata.status, isOverdue: isOverdue),
                priority: TaskPriority(eventKitValue: reminder.priority),
                recurrence: reminder.recurrenceRules?.first.map(recurrenceRule(from:)),
                tags: metadata.tags,
                attachments: metadata.attachments,
                comments: metadata.comments,
                parentID: parentID,
                blockedByTaskIDs: metadata.blockedByTaskIDs,
                createdAt: reminder.creationDate,
                modifiedAt: reminder.lastModifiedDate,
                sharedShoppingDetails: shoppingNotes.details
            )
        } }

        // Subtasks whose parent reminder was deleted would otherwise be hidden from every root list.
        let existingIDs = Set(items.map(\.id))
        return items.map { item in
            guard let parentID = item.parentID, !existingIDs.contains(parentID) else { return item }
            var orphan = item
            orphan.parentID = nil
            return orphan
        }
        .sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func metadataIdentifier(forReminderID id: String) -> String {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return id }
        return Self.metadataID(for: reminder)
    }

    func saveTask(_ draft: TaskDraft, metadataStore: MetadataStore, commit: Bool = true, shoppingDetails: SpecializedTaskDetails? = nil) throws -> String {
        do { return try saveTaskImpl(draft, metadataStore: metadataStore, commit: commit, shoppingDetails: shoppingDetails) }
        catch { store.reset(); throw error }
    }

    private func saveTaskImpl(_ draft: TaskDraft, metadataStore: MetadataStore, commit: Bool, shoppingDetails: SpecializedTaskDetails?) throws -> String {
        guard draft.hasValidURL else {
            throw NSError(domain: "TaskFlow.Reminders", code: 5, userInfo: [NSLocalizedDescriptionKey: "Enter a complete reminder URL."])
        }
        let reminder = reminder(for: draft)
        reminder.title = draft.title.isEmpty ? "Untitled Task" : draft.title
        let shared = shoppingDetails ?? ShoppingReminderNotes.decode(reminder.notes ?? "").details
        let notes = ShoppingReminderNotes.encode(draft.notes, details: shared)
        reminder.notes = notes.isEmpty ? nil : notes
        guard let targetList = calendar(withID: draft.listID), targetList.allowsContentModifications else {
            throw NSError(domain: "TaskFlow.Reminders", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose an available, editable reminder list."])
        }
        reminder.calendar = targetList
        reminder.url = draft.url
        if TaskPriority(eventKitValue: reminder.priority) != draft.priority { reminder.priority = draft.priority.eventKitValue }
        let completed = draft.isCompleted || draft.status == .done
        if reminder.isCompleted != completed { reminder.isCompleted = completed }
        let existingRule = reminder.recurrenceRules?.first.map(recurrenceRule(from:))
        if existingRule != draft.recurrence { reminder.recurrenceRules = draft.recurrence.map { [eventKitRule(from: $0)] } }

        let previousDue = reminder.dueDateComponents?.date
        let previousStart = reminder.startDateComponents?.date
        if let dueDate = draft.dueDate {
            let startTracksDue = previousStart == previousDue && draft.startDate == previousStart
            let start = startTracksDue ? dueDate : (draft.startDate ?? dueDate)
            guard start <= dueDate || (!draft.hasDueTime && Calendar.current.isDate(start, inSameDayAs: dueDate)) else {
                throw NSError(domain: "TaskFlow.Reminders", code: 4, userInfo: [NSLocalizedDescriptionKey: "The start date must be on or before the due date."])
            }
            let startHasTime = draft.startDate == nil || startTracksDue ? draft.hasDueTime : draft.hasStartTime
            if previousStart != start || (reminder.startDateComponents?.hour != nil) != startHasTime {
                reminder.startDateComponents = dateComponents(for: start, includeTime: startHasTime)
            }
            if previousDue != dueDate || (reminder.dueDateComponents?.hour != nil) != draft.hasDueTime {
                reminder.dueDateComponents = dateComponents(for: dueDate, includeTime: draft.hasDueTime)
            }
        } else {
            if previousStart != draft.startDate || (reminder.startDateComponents?.hour != nil) != draft.hasStartTime {
                reminder.startDateComponents = draft.startDate.map { dateComponents(for: $0, includeTime: draft.hasStartTime) }
            }
            reminder.dueDateComponents = nil
        }

        let originalTimeAlarms = (reminder.alarms ?? []).filter { $0.structuredLocation == nil }
        let originalAlerts = Self.decodeTimeAlarms(originalTimeAlarms)
        var alarms: [EKAlarm] = []
        if let offset = draft.alarmOffsetMinutes, draft.dueDate != nil {
            alarms.append(EKAlarm(relativeOffset: -TimeInterval(offset * 60)))
        }
        for alert in draft.additionalAlerts {
            switch alert {
            case .relative(let minutes): if draft.dueDate != nil { alarms.append(EKAlarm(relativeOffset: -TimeInterval(minutes * 60))) }
            case .absolute(let date): alarms.append(EKAlarm(absoluteDate: date))
            }
        }

        if originalAlerts.0 == draft.alarmOffsetMinutes && originalAlerts.1 == draft.additionalAlerts && (draft.dueDate != nil || originalTimeAlarms.allSatisfy({ $0.absoluteDate != nil })) {
            alarms = originalTimeAlarms
        }
        let existingGeofences = (reminder.alarms ?? []).filter { $0.structuredLocation != nil }
        let originalMetadata = metadataStore.metadata(for: reminder.calendarItemIdentifier, cloudID: Self.metadataID(for: reminder))
        if draft.location == (Self.decodeLocation(existingGeofences) ?? originalMetadata.location), !existingGeofences.isEmpty {
            alarms.append(contentsOf: existingGeofences)
        } else if let loc = draft.location {
            let structured = EKStructuredLocation(title: loc.displayTitle)
            if let lat = loc.latitude, let lon = loc.longitude {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            structured.radius = max(0, loc.radius)

            if loc.latitude != nil && loc.longitude != nil {
                let geofenceAlarm = EKAlarm()
                geofenceAlarm.structuredLocation = structured
                geofenceAlarm.proximity = (loc.proximity == .onDeparture) ? .leave : .enter
                alarms.append(geofenceAlarm)
            }
        }
        reminder.alarms = alarms.isEmpty ? nil : alarms

        try store.save(reminder, commit: commit)

        let metadataID = Self.metadataID(for: reminder)
        if commit {
            persistMetadata(draft, id: reminder.calendarItemIdentifier, metadataID: metadataID, store: metadataStore)
        } else { pendingMetadata.append((reminder.calendarItemIdentifier, metadataID, draft)) }
        return reminder.calendarItemIdentifier
    }

    private func persistMetadata(_ draft: TaskDraft, id: String, metadataID: String, store: MetadataStore) {
        var metadata = store.metadata(for: id, cloudID: metadataID)
        metadata.durationMinutes = draft.durationMinutes
        metadata.location = draft.location
        metadata.isFlagged = draft.isFlagged
        if draft.status != .overdue {
            metadata.status = draft.status
        }
        metadata.tags = draft.tags
        metadata.attachments = draft.attachments
        metadata.parentID = draft.parentID
        metadata.blockedByTaskIDs = draft.blockedByTaskIDs
        store.setMetadata(metadata, for: metadataID)
    }

    private static func displayStatus(for metadataStatus: TaskStatus, isOverdue: Bool) -> TaskStatus {
        if isOverdue && metadataStatus == .notStarted {
            return .overdue
        }
        return metadataStatus
    }

    func saveTasks(_ drafts: [TaskDraft], metadataStore: MetadataStore) throws {
        pendingMetadata = []
        defer { pendingMetadata = [] }
        do {
            for draft in drafts { _ = try saveTask(draft, metadataStore: metadataStore, commit: false) }
            try store.commit()
            metadataStore.performBatchUpdates {
                for (id, metadataID, draft) in pendingMetadata { persistMetadata(draft, id: id, metadataID: metadataID, store: metadataStore) }
            }
        } catch {
            store.reset()
            throw error
        }
    }

    func deleteTask(id: String, metadataStore: MetadataStore) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        let metadataID = Self.metadataID(for: reminder)
        try store.remove(reminder, commit: true)
        metadataStore.removeMetadata(for: id)
        metadataStore.removeMetadata(for: metadataID)
    }

    func deleteTasks(ids: [String], metadataStore: MetadataStore) throws {
        var removed: [(String, String)] = []
        do {
            for id in ids {
                if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
                    let metadataID = Self.metadataID(for: reminder)
                    try store.remove(reminder, commit: false)
                    removed.append((id, metadataID))
                }
            }
            try store.commit()
            metadataStore.performBatchUpdates {
                for (id, metadataID) in removed {
                    metadataStore.removeMetadata(for: id)
                    metadataStore.removeMetadata(for: metadataID)
                }
            }
        } catch { store.reset(); throw error }
    }

    func restoreDeletedTask(_ task: TaskItem, metadataStore: MetadataStore) throws {
        var draft = TaskDraft(task: task)
        draft.reminderID = nil
        let newID = try saveTask(draft, metadataStore: metadataStore, shoppingDetails: task.sharedShoppingDetails)
        guard let reminder = store.calendarItem(withIdentifier: newID) as? EKReminder else { return }
        let cloudID = Self.metadataID(for: reminder)
        var metadata = metadataStore.metadata(for: newID, cloudID: cloudID)
        metadata.comments = task.comments
        metadataStore.setMetadata(metadata, for: cloudID)
        if let details = metadataStore.specializedTasks[task.metadataID] ?? metadataStore.specializedTasks[task.id] {
            var specialized = metadataStore.specializedTasks
            specialized[cloudID] = details
            metadataStore.specializedTasks = specialized
        }
        // EventKit assigns a new ID; preserve links from subtasks, dependencies, and notes.
        var snapshot = metadataStore.currentSnapshot()
        for key in Array(snapshot.taskMetadata.keys) {
            guard var related = snapshot.taskMetadata[key] else { continue }
            if related.parentID == task.id { related.parentID = newID }
            related.blockedByTaskIDs = related.blockedByTaskIDs.map { $0 == task.id ? newID : $0 }
            snapshot.taskMetadata[key] = related
        }
        for index in snapshot.quickNotes.indices where snapshot.quickNotes[index].linkedTaskID == task.id {
            snapshot.quickNotes[index].linkedTaskID = newID
        }
        snapshot.cloudUpdatedAt = Date()
        metadataStore.replace(with: snapshot)
    }

    func setCompleted(_ completed: Bool, task: TaskItem, metadataStore: MetadataStore, shoppingDetails: SpecializedTaskDetails? = nil) throws {
        var draft = TaskDraft(task: task)
        draft.isCompleted = completed
        draft.status = completed ? .done : .active
        _ = try saveTask(draft, metadataStore: metadataStore, shoppingDetails: shoppingDetails)
    }

    private func reminder(for draft: TaskDraft) -> EKReminder {
        if let id = draft.reminderID, let existing = store.calendarItem(withIdentifier: id) as? EKReminder {
            return existing
        }
        return EKReminder(eventStore: store)
    }

    private static func metadataID(for reminder: EKReminder) -> String {
        reminder.calendarItemExternalIdentifier
    }

    private func calendar(withID id: String) -> EKCalendar? {
        store.calendars(for: .reminder).first { $0.calendarIdentifier == id }
    }

    private func eventCalendar(withID id: String) -> EKCalendar? {
        store.calendars(for: .event).first {
            $0.calendarIdentifier == id && $0.allowsContentModifications
        }
    }

    private func dateComponents(for date: Date, includeTime: Bool) -> DateComponents {
        var components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: date)
        components.calendar = calendar
        components.timeZone = .current
        if !includeTime {
            components.hour = nil
            components.minute = nil
        }
        return components
    }

    private func recurrenceRule(from rule: EKRecurrenceRule) -> RecurrenceRule {
        RecurrenceRule(
            frequency: RecurrenceFrequency(rule.frequency),
            interval: max(rule.interval, 1),
            weekdays: rule.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue }.sorted() ?? [],
            monthDays: rule.daysOfTheMonth?.map(\.intValue).sorted() ?? [],
            months: rule.monthsOfTheYear?.map(\.intValue).sorted() ?? [],
            end: recurrenceEnd(from: rule.recurrenceEnd)
        )
    }

    private func recurrenceEnd(from end: EKRecurrenceEnd?) -> RecurrenceEnd {
        guard let end else { return .never }
        if let endDate = end.endDate {
            return .onDate(endDate)
        }
        if end.occurrenceCount > 0 {
            return .afterOccurrences(Int(end.occurrenceCount))
        }
        return .never
    }

    private func eventKitRule(from rule: RecurrenceRule) -> EKRecurrenceRule {
        EKRecurrenceRule(
            recurrenceWith: rule.frequency.eventKitValue,
            interval: max(rule.interval, 1),
            daysOfTheWeek: daysOfTheWeek(for: rule),
            daysOfTheMonth: rule.frequency == .monthly ? rule.monthDays.map(NSNumber.init(value:)) : nil,
            monthsOfTheYear: rule.frequency == .yearly ? rule.months.map(NSNumber.init(value:)) : nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: eventKitEnd(from: rule.end)
        )
    }

    private func daysOfTheWeek(for rule: RecurrenceRule) -> [EKRecurrenceDayOfWeek]? {
        guard rule.frequency == .weekly || rule.frequency == .monthly || rule.frequency == .yearly else { return nil }
        let validDays = rule.weekdays.filter { (1...7).contains($0) }
        guard !validDays.isEmpty else { return nil }
        return validDays.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0) ?? .sunday) }
    }

    private func eventKitEnd(from end: RecurrenceEnd) -> EKRecurrenceEnd? {
        switch end {
        case .never:
            return nil
        case .onDate(let date):
            return EKRecurrenceEnd(end: date)
        case .afterOccurrences(let count):
            return EKRecurrenceEnd(occurrenceCount: max(count, 1))
        }
    }

    private static func isOverdue(dueDate: Date?, hasDueTime: Bool, isCompleted: Bool, now: Date = Date()) -> Bool {
        guard !isCompleted, let dueDate else { return false }
        if hasDueTime {
            return dueDate < now
        }
        let calendar = Calendar.current
        return calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: now)
    }

    private func bestReminderSource() -> EKSource? {
        store.defaultCalendarForNewReminders()?.source ??
            store.sources.first(where: { $0.sourceType == .calDAV }) ??
            store.sources.first(where: { $0.sourceType == .local }) ??
            store.sources.first
    }
}

private extension RecurrenceFrequency {
    init(_ frequency: EKRecurrenceFrequency) {
        switch frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        @unknown default: self = .weekly
        }
    }

    var eventKitValue: EKRecurrenceFrequency {
        switch self {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
    }
}
