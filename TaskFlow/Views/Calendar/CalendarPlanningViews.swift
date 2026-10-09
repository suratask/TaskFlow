import ActivityKit
import Combine
import EventKit
import EventKitUI
import MapKit
import SwiftUI
import TipKit
#if canImport(UIKit)
import UIKit
#endif

struct CalendarPlanningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @Binding var settings: CalendarWorkspaceSettings
    @State private var taskID = ""
    @State private var duration = 30
    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
    @State private var slots: [CalendarPlanningSlot] = []
    @State private var selected: CalendarPlanningSlot?
    @State private var calendarID = ""
    @State private var status = ""
    @State private var saving = false
    @State private var searched = false
    @State private var conflicts: [String] = []
    @State private var reviewEvents: [CalendarEvent] = []
    @State private var editEvent: EventDraft?
    @State private var showsMultiTaskPlanner = false

    private var task: TaskItem? { repository.tasks.first { $0.id == taskID } }
    private var rangeEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: cappedEnd)) ?? cappedEnd }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan tasks") {
                    Button("Build a Day Plan", systemImage: "calendar.badge.clock") { showsMultiTaskPlanner = true }
                    Picker("Task", selection: $taskID) {
                        Text("Choose a task").tag("")
                        ForEach(repository.tasks.filter { !$0.isCompleted }) { Text($0.title).tag($0.id) }
                    }
                    Stepper("Duration: \(duration) minutes", value: $duration, in: 15...480, step: 15)
                    DatePicker("From", selection: $start, in: Date()..., displayedComponents: .date)
                    DatePicker("Through", selection: $end, in: start...(Calendar.current.date(byAdding: .day, value: 89, to: start) ?? start), displayedComponents: .date)
                    Picker("Calendar", selection: $calendarID) {
                        ForEach(repository.writableEventCalendars) { Text($0.title).tag($0.id) }
                    }
                    if repository.writableEventCalendars.isEmpty {
                        Text("Enable Calendar access and choose a writable calendar to schedule a block.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Find Open Slots") { findSlots() }
                        .disabled(task == nil || saving || calendarID.isEmpty || end < start)
                    Text("Checks all available calendars and timed tasks. Free events do not block time. Task deadlines stay unchanged. Suggestions cover up to 30 days.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if searched {
                    Section("Suggested times") {
                        if slots.isEmpty { Text("No available slots. Try a shorter duration, a wider date range, or different working hours.") }
                        ForEach(slots.prefix(12)) { slot in
                            Button {
                                selected = slot
                                status = ""
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(slot.start.formatted(date: .abbreviated, time: .shortened))
                                        Text("Until \(slot.end.formatted(date: .omitted, time: .shortened))\(slot.preferred ? " · Preferred focus time" : "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected == slot { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                    }
                }
                if let selected, let task {
                    Section("Preview") {
                        Text(task.title).font(.headline)
                        LabeledContent("Starts", value: selected.start.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Ends", value: selected.end.formatted(date: .abbreviated, time: .shortened))
                        Text("Creates a linked calendar event. Your task and its deadline remain unchanged.").font(.footnote)
                        Button(saving ? "Saving…" : "Create Time Block") { apply(selected, task: task) }
                            .disabled(saving)
                    }
                }
                if !status.isEmpty { Section { Text(status).accessibilityLabel(status) } }
                Section("Schedule review") {
                    Button("Check Conflicts in Date Range") { review() }.disabled(end < start)
                    ForEach(Array(conflicts.enumerated()), id: \.offset) { _, message in
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if !conflicts.isEmpty {
                        Button("Find Another Time for Selected Task") { findSlots() }.disabled(task == nil)
                        Button("Keep Schedule Unchanged") { conflicts = []; reviewEvents = []; status = "Schedule unchanged." }
                        ForEach(reviewEvents) { event in
                            Button("Edit " + event.title) { editEvent = EventDraft(event: event) }
                                .disabled(!repository.writableEventCalendars.contains { $0.id == event.calendarID })
                        }
                    }
                    Text("Read-only events must be changed by their calendar owner.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(item: $editEvent, onDismiss: { invalidate(); review() }) { draft in CalendarEventEditorView(repository: repository, draft: draft) }
            .sheet(isPresented: $showsMultiTaskPlanner) { MultiTaskPlanningSheet(repository: repository, settings: settings, calendarID: calendarID) }
            .taskFlowThemedBackground()
            .navigationTitle("Plan & Review")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(saving) } }
            .onChange(of: taskID) { _, _ in duration = max(15, task?.durationMinutes ?? 30); invalidate() }
            .onChange(of: duration) { _, _ in invalidate() }
            .onChange(of: start) { _, _ in if end < start { end = start }; invalidate() }
            .onChange(of: end) { _, _ in invalidate() }
            .onChange(of: calendarID) { _, _ in selected = nil }
            .task { calendarID = repository.makeEventDraft().calendarID }
            .interactiveDismissDisabled(saving)
        }
    }

    private func invalidate() { slots = []; selected = nil; searched = false; status = "" }
    private var cappedEnd: Date { min(end, Calendar.current.date(byAdding: .day, value: 30, to: start) ?? end) }
    private func findSlots() {
        selected = nil
        searched = true
        slots = CalendarPlanningEngine.slots(from: start, through: cappedEnd, duration: duration, settings: settings, events: repository.planningEvents(from: start.addingTimeInterval(-86400), to: rangeEnd), tasks: repository.tasks.filter { $0.id != taskID })
    }
    private func review() {
        reviewEvents = repository.planningEvents(from: start, to: rangeEnd)
        conflicts = CalendarPlanningEngine.conflicts(events: reviewEvents, tasks: repository.tasks.filter { guard let due = $0.dueDate else { return false }; return due >= start && due < rangeEnd }, settings: settings)
        status = conflicts.isEmpty ? "No conflicts found in this date range." : "\(conflicts.count) scheduling issues found."
    }
    private func apply(_ slot: CalendarPlanningSlot, task: TaskItem) {
        let fresh = CalendarPlanningEngine.slots(from: slot.start, through: slot.start, duration: duration, settings: settings, events: repository.planningEvents(from: slot.start.addingTimeInterval(-86400), to: slot.end.addingTimeInterval(86400)), tasks: repository.tasks.filter { $0.id != task.id })
        guard fresh.contains(where: { $0.start == slot.start }) else {
            status = "This time is no longer available. Find open slots again."
            selected = nil
            return
        }
        saving = true
        var draft = repository.makeEventDraft(startDate: slot.start, endDate: slot.end)
        draft.calendarID = calendarID
        draft.title = task.title
        draft.notes = "TaskFlow linked task: \(task.id)"
        Task {
            let success = await repository.saveEvent(draft)
            saving = false
            status = success ? "Time block saved." : (repository.errorMessage ?? "Unable to save. Try again.")
            if success { selected = nil; slots = []; searched = false }
        }
    }
}

struct CalendarPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: CalendarWorkspaceSettings
    var body: some View {
        NavigationStack {
            Form {
                Section("Working hours") {
                    Stepper("Start: \(settings.workStart):00", value: $settings.workStart, in: 0...22)
                    Stepper("End: \(settings.workEnd):00", value: $settings.workEnd, in: min(settings.workStart + 1, 23)...23)
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { settings.weekdays.contains(day) }, set: { enabled in
                            if enabled { settings.weekdays.insert(day) } else { settings.weekdays.remove(day) }
                        }))
                    }
                }
                Section("Preferred focus times") {
                    Stepper("Start: \(settings.focusStart):00", value: $settings.focusStart, in: 0...22)
                    Stepper("End: \(settings.focusEnd):00", value: $settings.focusEnd, in: min(settings.focusStart + 1, 23)...23)
                    Stepper("Meeting buffer: \(settings.bufferMinutes) min", value: $settings.bufferMinutes, in: 0...60, step: 5)
                }
                Section("Layout") {
                    Toggle("Compact spacing", isOn: $settings.compact)
                    VStack(alignment: .leading) {
                        Text("Hour height: \(Int(settings.hourHeight)) points")
                        Slider(value: $settings.hourHeight, in: 60...140, step: 10)
                    }
                    Toggle("Show week number", isOn: $settings.showWeekNumbers)
                    Toggle("Show working hours only", isOn: $settings.hideNonworkingHours)
                    Text("All-day items remain visible. Timed events that overlap working hours remain visible.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Calendar Preferences")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings.workStart) { _, value in settings.workEnd = max(value + 1, settings.workEnd) }
            .onChange(of: settings.focusStart) { _, value in settings.focusEnd = max(value + 1, settings.focusEnd) }
        }
    }
}

struct MultiTaskPlanningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let settings: CalendarWorkspaceSettings
    let calendarID: String
    @State private var selectedIDs = Set<String>()
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var proposals: [(task: TaskItem, slot: CalendarPlanningSlot)] = []
    @State private var status = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Choose work") {
                    DatePicker("Start day", selection: $startDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    ForEach(repository.rootTasks.filter { !$0.isCompleted }.sorted { priorityRank($0) < priorityRank($1) }) { task in
                        Toggle(isOn: Binding(get: { selectedIDs.contains(task.id) }, set: { enabled in
                            if enabled { selectedIDs.insert(task.id) } else { selectedIDs.remove(task.id) }
                            proposals = []
                        })) {
                            VStack(alignment: .leading) {
                                Text(task.title)
                                Text("\(task.priority.rawValue) priority · \(task.durationMinutes ?? 30) min\(task.dueDate.map { " · due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Tasks are ordered by priority and deadline. Suggested blocks respect working hours, events, existing timed tasks, and your buffer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Suggest a Day Plan") { makePlan() }
                        .disabled(selectedIDs.isEmpty || calendarID.isEmpty || isSaving)
                }
                if !proposals.isEmpty {
                    Section("Review proposed schedule") {
                        ForEach(proposals, id: \.task.id) { proposal in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proposal.task.title).font(.headline)
                                Text("\(proposal.slot.start.formatted(date: .abbreviated, time: .shortened)) – \(proposal.slot.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Button(isSaving ? "Saving…" : "Apply Schedule") { applyPlan() }
                            .disabled(isSaving)
                        Text("Creates linked calendar blocks. Task deadlines remain unchanged. You can undo each calendar change in TaskFlow.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !status.isEmpty { Section { Text(status) } }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Schedule Time Blocks")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(isSaving) } }
            .onChange(of: startDate) { _, _ in proposals = [] }
        }
    }

    private func priorityRank(_ task: TaskItem) -> Int {
        let deadline = task.dueDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
        return (task.priority == .high ? 0 : task.priority == .medium ? 1 : task.priority == .low ? 2 : 3) * 1000000000 + Int(min(deadline / 86400, 900000000))
    }

    private func makePlan() {
        let tasks = repository.rootTasks.filter { selectedIDs.contains($0.id) && !$0.isCompleted }.sorted { priorityRank($0) < priorityRank($1) }
        var scheduledEvents = repository.planningEvents(from: startDate.addingTimeInterval(-86400), to: startDate.addingTimeInterval(86400 * 31))
        var planned: [(task: TaskItem, slot: CalendarPlanningSlot)] = []
        for task in tasks {
            let length = max(15, task.durationMinutes ?? 30)
            let candidates = CalendarPlanningEngine.slots(from: startDate, through: Calendar.current.date(byAdding: .day, value: 30, to: startDate) ?? startDate, duration: length, settings: settings, events: scheduledEvents, tasks: repository.tasks.filter { $0.id != task.id && !selectedIDs.contains($0.id) })
            let beforeDeadline = candidates.filter { slot in
                guard let dueDate = task.dueDate else { return true }
                if task.hasDueTime { return slot.end <= dueDate }
                let dueDayEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: dueDate)) ?? dueDate
                return slot.end <= dueDayEnd
            }
            guard let slot = beforeDeadline.first else { continue }
            planned.append((task, slot))
            scheduledEvents.append(CalendarEvent(id: "proposal-\(task.id)", calendarID: calendarID, title: task.title, startDate: slot.start, endDate: slot.end, isAllDay: false, availability: "Busy"))
        }
        proposals = planned
        status = planned.count == tasks.count ? "All selected tasks fit." : "\(tasks.count - planned.count) task(s) could not fit in the next 30 days. Shorten estimates or adjust working hours."
    }

    private func applyPlan() {
        guard !proposals.isEmpty else { return }
        isSaving = true
        let drafts = proposals.map { proposal -> EventDraft in
            var draft = repository.makeEventDraft(startDate: proposal.slot.start, endDate: proposal.slot.end)
            draft.calendarID = calendarID
            draft.title = proposal.task.title
            draft.notes = "TaskFlow linked task: \(proposal.task.id)"
            return draft
        }
        Task {
            let succeeded = await repository.saveEvents(drafts)
            isSaving = false
            if succeeded { dismiss() } else { status = repository.errorMessage ?? "Could not apply the proposed schedule." }
        }
    }
}

struct CalendarConflictCheckerPage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.date(byAdding: .day, value: 6, to: Date()) ?? Date()
    @State private var includeAllDay = true
    @State private var conflicts: [CalendarEventConflict] = []
    @State private var isScanning = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var editDraft: EventDraft?
    @State private var detailsEvent: CalendarEvent?
    @State private var moveEvent: CalendarEvent?
    @State private var undoAvailability: (CalendarEvent, EventAvailability)?
    @State private var undoMove: EventDraft?

    private var rangeStart: Date { Calendar.current.startOfDay(for: start) }
    private var rangeEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end }
    private var scanKey: String { "\(rangeStart)|\(rangeEnd)|\(includeAllDay)|\(repository.eventAccessState)|\(repository.excludedAvailabilityCalendarIDs.sorted())" }
    private var dayGroups: [(date: Date, items: [CalendarEventConflict])] {
        Dictionary(grouping: Array(conflicts.prefix(200)), by: { Calendar.current.startOfDay(for: $0.start) })
            .map { (date: $0.key, items: $0.value) }.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                filters
                if repository.eventAccessState != .granted {
                    Section {
                        ContentUnavailableView("Calendar Access Needed", systemImage: "calendar.badge.exclamationmark", description: Text(repository.eventAccessState.message))
                        if repository.eventAccessState == .unknown {
                            Button("Continue") { Task { await repository.requestEventCalendarAccess(); scan() } }
                        } else {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                } else if end < start {
                    Section { Label("Choose an end date on or after the start date", systemImage: "exclamationmark.triangle") }
                } else if isScanning {
                    Section { ProgressView("Checking calendars…") }
                } else if conflicts.isEmpty {
                    Section { ContentUnavailableView("No Conflicts", systemImage: "checkmark.circle", description: Text("No busy events overlap in this date range. Free events do not block time.")) }
                } else {
                    Section {
                        Label("\(conflicts.count >= 2_001 ? "At least " : "")\(conflicts.count) overlapping event pairs", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        if conflicts.count > 200 { Text("Showing the first 200 pairs. Narrow the date range to review more.").font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(dayGroups, id: \.date) { group in
                        Section(group.date.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.items) { conflict in conflictCard(conflict) }
                        }
                    }
                }
                if undoAvailability != nil || undoMove != nil {
                    Section { Button("Undo Last Resolution", systemImage: "arrow.uturn.backward") { undo() }.disabled(isSaving) }
                }
            }
            .listStyle(.insetGrouped)
            .taskFlowThemedBackground()
            .navigationTitle("Conflict Checker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise") { scan() }.disabled(isSaving) }
            }
            .task(id: scanKey) { scan() }
            .refreshable { scan() }
            // EventKit posts bursts (including for our own saves); a scan is a synchronous 90-day fetch.
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in scan() }
            .sheet(item: $editDraft, onDismiss: { scan() }) { draft in CalendarEventEditorView(repository: repository, draft: draft) }
            .sheet(item: $detailsEvent, onDismiss: { scan() }) { event in CalendarEventDetailView(repository: repository, event: event, color: color(event)) }
            .sheet(item: $moveEvent, onDismiss: { scan() }) { event in
                ConflictRescheduleSheet(repository: repository, event: event) { previous in
                    undoAvailability = nil
                    undoMove = previous
                    scan()
                }
            }
            .alert("Could Not Resolve Conflict", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var filters: some View {
        Section {
            Menu("Date Range") {
                ForEach([7, 14, 30], id: \.self) { days in
                    Button("Next \(days) Days") {
                        start = Date()
                        end = Calendar.current.date(byAdding: .day, value: days - 1, to: start) ?? start
                    }
                }
            }
            DatePicker("From", selection: $start, displayedComponents: .date)
            DatePicker("Through", selection: $end, in: start..., displayedComponents: .date)
            Toggle("Include All-Day Events", isOn: $includeAllDay)
        } footer: { Text("Checks calendars enabled under Settings → Calendars → Affects Availability, including hidden calendars. Free events are excluded. Invitee schedules are not available. Limit each scan to 90 days.") }
    }

    private func conflictCard(_ conflict: CalendarEventConflict) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Overlap: \(conflict.start.formatted(date: .omitted, time: .shortened))–\(conflict.end.formatted(date: .omitted, time: .shortened))", systemImage: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            eventRow(conflict.first)
            Divider()
            eventRow(conflict.second)
        }.padding(.vertical, 6)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { detailsEvent = event } label: {
                HStack(alignment: .top) {
                    Circle().fill(color(event)).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.headline).foregroundStyle(.primary)
                        Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + event.endDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Text((repository.eventCalendars.first { $0.id == event.calendarID }?.title ?? "Calendar") + " · " + (event.availability ?? "Busy")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            if repository.writableEventCalendars.contains(where: { $0.id == event.calendarID }) {
                ViewThatFits(in: .horizontal) {
                    HStack { resolutionButtons(event) }
                    VStack(alignment: .leading) { resolutionButtons(event) }
                }.disabled(isSaving)
            } else { Text("Read-only calendar · resolve by changing the other event").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func resolutionButtons(_ event: CalendarEvent) -> some View {
        if repository.availabilityOptions(for: event.calendarID).contains(.free) {
            Button("Mark Free") { markFree(event) }.buttonStyle(.bordered).tint(.green)
        }
        Button("Edit Time") { editDraft = EventDraft(event: event) }.buttonStyle(.bordered)
        if !event.isAllDay { Button("Find Time") { moveEvent = event }.buttonStyle(.bordered) }
    }

    private func color(_ event: CalendarEvent) -> Color { repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue }
    private func scan() {
        guard !isSaving else { return }
        guard end >= start else { conflicts = []; return }
        guard rangeEnd.timeIntervalSince(rangeStart) <= 91 * 86400 else { conflicts = []; error = "Choose a date range of 90 days or fewer."; return }
        isScanning = true
        let events = repository.conflictCheckEvents(from: rangeStart, to: rangeEnd)
        conflicts = EventConflictChecker.pairs(in: events, from: rangeStart, to: rangeEnd, includeAllDay: includeAllDay)
        isScanning = false
    }
    private func markFree(_ event: CalendarEvent) {
        isSaving = true
        Task {
            if await repository.setEventAvailability(.free, for: event) {
                let updated = repository.conflictCheckEvents(from: event.startDate, to: event.endDate).first { $0.id == repository.lastAvailabilityEventID && $0.startDate == event.startDate }
                undoAvailability = updated.flatMap { updated in EventAvailability(rawValue: event.availability ?? "Busy").map { (updated, $0) } }
                undoMove = nil
            } else { error = repository.eventSaveStatus }
            isSaving = false
            scan()
        }
    }
    private func undo() {
        isSaving = true
        Task {
            let succeeded: Bool
            if let (event, previous) = undoAvailability { succeeded = await repository.setEventAvailability(previous, for: event) }
            else if let previous = undoMove { succeeded = await repository.saveEvent(previous) }
            else { isSaving = false; return }
            if succeeded { undoAvailability = nil; undoMove = nil }
            else { error = repository.eventSaveStatus }
            isSaving = false
            scan()
        }
    }
}

struct ConflictRescheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let event: CalendarEvent
    let onSaved: (EventDraft) -> Void
    @AppStorage("TaskFlow.calendar.workspace") private var settingsData = Data()
    @State private var slots: [CalendarPlanningSlot] = []
    @State private var selected: CalendarPlanningSlot?
    @State private var isSaving = false
    @State private var error: String?
    private var settings: CalendarWorkspaceSettings { (try? JSONDecoder().decode(CalendarWorkspaceSettings.self, from: settingsData)) ?? CalendarWorkspaceSettings() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title).font(.headline)
                    Text("Choose an open time in the next 14 days. Suggestions respect working hours, buffers, timed tasks and calendars that affect availability. The event keeps its exact duration.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Open Times") {
                    if slots.isEmpty { ContentUnavailableView("No Open Times", systemImage: "calendar.badge.exclamationmark", description: Text("Use Edit Time to pick a different date, or adjust your calendar working hours.")) }
                    ForEach(slots) { slot in
                        Button { selected = slot } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(slot.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                                    Text("Until " + slot.start.addingTimeInterval(event.endDate.timeIntervalSince(event.startDate)).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == slot.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Find Open Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Saving…" : "Move Event") { move() }.disabled(selected == nil || isSaving) }
            }
            .task {
                let start = max(Date(), event.startDate)
                let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start
                let events = repository.conflictCheckEvents(from: start.addingTimeInterval(-86400), to: end).filter { !($0.id == event.id && $0.startDate == event.startDate) }
                slots = Array(CalendarPlanningEngine.slots(from: start, through: end, duration: max(1, Int(ceil(event.endDate.timeIntervalSince(event.startDate) / 60))), settings: settings, events: events, tasks: repository.tasks).prefix(12))
            }
            .alert("Time Is Not Available", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func move() {
        guard let selected else { return }
        var draft = EventDraft(event: event)
        draft.startDate = selected.start
        draft.endDate = selected.start.addingTimeInterval(event.endDate.timeIntervalSince(event.startDate))
        let freshEvents = repository.conflictCheckEvents(from: selected.start.addingTimeInterval(-86400), to: draft.endDate.addingTimeInterval(86400)).filter { !($0.id == event.id && $0.startDate == event.startDate) }
        let validSlots = CalendarPlanningEngine.slots(from: selected.start, through: selected.start, duration: max(1, Int(ceil(event.endDate.timeIntervalSince(event.startDate) / 60))), settings: settings, events: freshEvents, tasks: repository.tasks)
        guard validSlots.contains(where: { $0.start == selected.start }), repository.eventConflicts(for: draft, originalStart: event.startDate).isEmpty else {
            error = "This time is no longer open with your current events, tasks and buffers. Choose a different slot."; return
        }
        isSaving = true
        Task {
            if await repository.saveEvent(draft) {
                var previous = EventDraft(event: event)
                previous.eventID = repository.lastSavedEventID
                previous.originalStartDate = selected.start
                onSaved(previous)
                dismiss()
            }
            else { error = repository.eventSaveStatus }
            isSaving = false
        }
    }
}
