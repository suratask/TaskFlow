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
        } catch { eventSaveStatus = FriendlyError.message(for: error) }
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
            eventSaveStatus = "Could not delete the event: " + FriendlyError.message(for: error)
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
            eventSaveStatus = "Could not save: " + FriendlyError.message(for: error)
            errorMessage = FriendlyError.message(for: error)
            return false
        }
    }
    func availabilityOptions(for calendarID: String) -> [EventAvailability] {
        reminderService.availabilityOptions(calendarID: calendarID)
    }
    func conflictCheckEvents(from start: Date, to end: Date) -> [CalendarEvent] {
        guard eventAccessState == .granted, usesCalendars, end > start else { return [] }
        let calendarIDs = Set(reminderService.loadEventCalendars().map(\.id))
            .subtracting(excludedAvailabilityCalendarIDs)
            .subtracting(disabledEventCalendarIDs)
        return reminderService.loadEvents(from: start, to: end, calendarIDs: calendarIDs)
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
            eventSaveStatus = "Could not save: " + FriendlyError.message(for: error)
            errorMessage = FriendlyError.message(for: error)
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
            eventSaveStatus = "Could not save: " + FriendlyError.message(for: error)
            errorMessage = FriendlyError.message(for: error)
            return false
        }
    }
    func useMyCalendars() async {
        if eventAccessState != .granted { await requestEventCalendarAccess() }
        guard eventAccessState == .granted else { return }
        selectedEventCalendarIDs = Set(eventCalendars.map(\.id))
        await refreshCalendarEvents()
    }
    func requestEventCalendarAccess() async {
        _ = await reminderService.requestEventAccess()
        updateCalendarAccessState()
        reloadEventCalendars()
        await refreshCalendarEvents()
    }
    func updateCalendarAccessState() {
        switch reminderService.eventAuthorizationState {
        case .unknown: eventAccessState = .unknown
        case .granted: eventAccessState = .granted
        case .denied: eventAccessState = .denied
        case .restricted: eventAccessState = .restricted
        }
    }
    func setEventCalendar(_ calendar: EventCalendar, isSelected: Bool) {
        if isSelected {
            selectedEventCalendarIDs.insert(calendar.id)
        } else {
            selectedEventCalendarIDs.remove(calendar.id)
        }
        Task { await refreshCalendarEvents() }
    }

    // MARK: Calendars in TaskFlow

    /// Calendars the user hasn't turned off in Settings; empty when Calendars are off entirely.
    var enabledEventCalendars: [EventCalendar] {
        usesCalendars ? allEventCalendars.filter { !disabledEventCalendarIDs.contains($0.id) } : []
    }
    /// Calendars whose events load: chosen in the calendar view's filter and turned on in Settings.
    var shownEventCalendarIDs: Set<String> {
        usesCalendars ? selectedEventCalendarIDs.subtracting(disabledEventCalendarIDs) : []
    }
    /// The Calendar tab and sidebar row appear only once calendars are in use: access granted, Calendars on,
    /// and at least one calendar on. Connecting Calendar happens in Settings › Calendar or during setup.
    var showsCalendarFeature: Bool { showsCalendarEvents }
    /// Calendar is optional: event features (tiles, timelines, New Event, linking) appear only while this is true,
    /// and views stay task-only otherwise instead of asking for access. Settings and the Calendar tab offer access.
    var showsCalendarEvents: Bool {
        usesCalendars && eventAccessState == .granted && !eventCalendars.isEmpty
    }
    /// New events need a calendar that is turned on and accepts changes.
    var canCreateEvents: Bool { showsCalendarEvents && !writableEventCalendars.isEmpty }
    func isEventCalendarEnabled(_ id: String) -> Bool { !disabledEventCalendarIDs.contains(id) }
    func reloadEventCalendars() {
        allEventCalendars = eventAccessState == .granted ? reminderService.loadEventCalendars() : []
        eventCalendars = enabledEventCalendars
    }
    func setUsesCalendars(_ enabled: Bool) {
        usesCalendars = enabled
        // Turning Calendars back on with nothing chosen in the calendar filter would still show no events.
        if enabled && shownEventCalendarIDs.isEmpty { selectedEventCalendarIDs.formUnion(enabledEventCalendars.map(\.id)) }
        applyEventCalendarAvailability()
    }
    func setEventCalendar(_ calendar: EventCalendar, isEnabled: Bool) {
        if isEnabled {
            disabledEventCalendarIDs.remove(calendar.id)
            selectedEventCalendarIDs.insert(calendar.id)
        } else {
            disabledEventCalendarIDs.insert(calendar.id)
        }
        applyEventCalendarAvailability()
    }
    private func applyEventCalendarAvailability() {
        eventCalendars = enabledEventCalendars
        if !showsCalendarFeature && taskViewMode == .calendar { taskViewMode = .list }
        WidgetCenter.shared.reloadAllTimelines()
        Task { await refreshCalendarEvents() }
    }
    func refreshCalendarEvents(invalidateCache: Bool = true) async {
        let interval = TaskFlowPerformance.begin("Calendar fetch")
        defer { TaskFlowPerformance.end("Calendar fetch", interval) }
        if invalidateCache { calendarEventCache.removeAll(); calendarCacheOrder.removeAll() }
        let shownCalendarIDs = shownEventCalendarIDs
        guard reminderService.eventAuthorizationState == .granted, !shownCalendarIDs.isEmpty else {
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
                let key = CalendarFetchKey(start: start, end: end, calendars: shownCalendarIDs)
                if let cached = calendarEventCache[key] { result += cached }
                else {
                    let events = reminderService.loadEvents(from: start, to: end, calendarIDs: shownCalendarIDs)
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
}
