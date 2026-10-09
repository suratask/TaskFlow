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

/// Creates and edits events with Apple's own Calendar editor (`EKEventEditViewController`).
struct EventAvailabilityControl: View {
    let options: [EventAvailability]
    let value: String
    var isSaving = false
    let onSelect: (EventAvailability) -> Void

    var body: some View {
        HStack {
            ForEach(options.filter { $0 == .busy || $0 == .free }) { option in
                Button { onSelect(option) } label: {
                    Label(option.rawValue, systemImage: value == option.rawValue ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(option == .free ? .green : .blue)
                .accessibilityAddTraits(value == option.rawValue ? .isSelected : [])
            }
            let others = options.filter { $0 != .busy && $0 != .free }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { option in
                        Button(option.rawValue, systemImage: value == option.rawValue ? "checkmark" : "circle") { onSelect(option) }
                    }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("More availability options, currently " + value)
            }
            if isSaving { ProgressView().controlSize(.small) }
        }
        .disabled(isSaving)
    }
}

struct CalendarEventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @State private var draft: EventDraft
    private let originalStart: Date
    @State private var conflicts: [CalendarEvent] = []
    @State private var showsConflictConfirmation = false
    @State private var showsSystemEditor = false
    @State private var pendingSystemOutcome: SystemEventEditorOutcome?
    @State private var isSaving = false
    @State private var saveError: String?

    init(repository: TaskRepository, draft: EventDraft) {
        self.repository = repository
        _draft = State(initialValue: draft)
        originalStart = draft.startDate
    }

    var body: some View {
        NavigationStack {
            Group {
            if repository.eventAccessState == .granted {
                Form {
                    Section {
                        TextField("Event title", text: $draft.title)
                        Picker("Calendar", selection: $draft.calendarID) {
                            ForEach(repository.writableEventCalendars) { calendar in
                                Text(calendar.title).tag(calendar.id)
                            }
                        }
                        Toggle("All Day", isOn: $draft.isAllDay)
                        DatePicker("Starts", selection: $draft.startDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        DatePicker("Ends", selection: $draft.endDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                    let options = repository.availabilityOptions(for: draft.calendarID)
                    if !options.isEmpty {
                        Section {
                            EventAvailabilityControl(options: options, value: draft.availability) { draft.availability = $0.rawValue }
                        } header: { Text("Show As · " + draft.availability) } footer: { Text("Busy, Tentative and Unavailable block time. Free does not.") }
                    }
                    Section {
                        if draft.endDate < draft.startDate || (!draft.isAllDay && draft.endDate == draft.startDate) {
                            Label("End time must be after start time", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else if conflicts.isEmpty {
                            Label(!repository.calendarAffectsAvailability(draft.calendarID) ? "This calendar does not affect availability" : draft.availability == "Free" ? "Free events do not block time" : "No overlapping busy events", systemImage: "checkmark.circle").foregroundStyle(.green)
                        } else {
                            Label("\(conflicts.count) overlapping event\(conflicts.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            ForEach(conflicts, id: \.occurrenceKey) { event in
                                VStack(alignment: .leading) {
                                    Text(event.title).font(.headline)
                                    Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + event.endDate.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Text(repository.eventCalendars.first { $0.id == event.calendarID }?.title ?? "Calendar").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("Conflict Check") } footer: { Text("Checks calendars enabled under Settings → Calendars → Affects Availability, including hidden calendars. Invitee availability is not included.") }
                    Section {
                        TextField("Location", text: $draft.location)
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                        Button("More Event Options", systemImage: "slider.horizontal.3") { showsSystemEditor = true }
                    } footer: { Text("Use the system editor for alerts, repeat settings and other calendar options.") }
                }
                .disabled(isSaving)
                .taskFlowThemedBackground()
                .onAppear {
                    let options = repository.availabilityOptions(for: draft.calendarID)
                    if !options.isEmpty && !options.contains(where: { $0.rawValue == draft.availability }) { draft.availability = options.first?.rawValue ?? "Busy" }
                    checkConflicts()
                }
                .onChange(of: draft.location) { _, _ in draft.structuredLocation = nil }
                .onChange(of: conflictQueryKey) { _, _ in checkConflicts() }
                .onChange(of: draft.calendarID) { _, id in
                    let options = repository.availabilityOptions(for: id)
                    if !options.contains(where: { $0.rawValue == draft.availability }) { draft.availability = options.first?.rawValue ?? "Busy" }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            checkConflicts()
                            if conflicts.isEmpty { save() } else { showsConflictConfirmation = true }
                        }
                        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.endDate < draft.startDate || (!draft.isAllDay && draft.endDate == draft.startDate))
                    }
                }
                .confirmationDialog("This event overlaps \(conflicts.count) other event\(conflicts.count == 1 ? "" : "s").", isPresented: $showsConflictConfirmation, titleVisibility: .visible) {
                    Button("Save Anyway") { save() }
                    Button("Keep Editing", role: .cancel) {}
                }
                .sheet(isPresented: $showsSystemEditor, onDismiss: completeSystemEditor) {
                    SystemEventEditor(store: repository.eventStore, event: repository.systemEvent(for: draft), originalStart: originalStart) { outcome in
                        pendingSystemOutcome = outcome
                        showsSystemEditor = false
                    }.ignoresSafeArea()
                }
            } else {
                ContentUnavailableView {
                    Label("Calendar Access Needed", systemImage: "calendar.badge.exclamationmark")
                } description: { Text(repository.eventAccessState.message) } actions: {
                    if repository.eventAccessState == .unknown {
                        Button("Continue") { Task { await repository.requestEventCalendarAccess() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
            }
        .navigationTitle(draft.eventID == nil ? "New Event" : "Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) } }
        .alert("Could Not Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        }
    }

    private func completeSystemEditor() {
        guard let outcome = pendingSystemOutcome else { return }
        pendingSystemOutcome = nil
        switch outcome {
        case .canceled: break
        case .saved(let id):
            dismiss()
            Task { await repository.systemEventEditorDidFinish(savedEventID: id, tags: draft.tags) }
        case .deleted(let deletion):
            dismiss()
            Task { await repository.eventDeletionDidComplete(deletion) }
        }
    }

    private var conflictQueryKey: String { "\(draft.startDate.timeIntervalSince1970)|\(draft.endDate.timeIntervalSince1970)|\(draft.isAllDay)|\(draft.calendarID)|\(draft.availability)|\(repository.excludedAvailabilityCalendarIDs.sorted())" }
    private func checkConflicts() { conflicts = repository.eventConflicts(for: draft, originalStart: originalStart) }
    private func save() {
        isSaving = true
        Task {
            if await repository.saveEvent(draft) { dismiss() }
            else { saveError = repository.eventSaveStatus }
            isSaving = false
        }
    }
}

struct SystemEventEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    let event: EKEvent
    let originalStart: Date
    let onFinish: (SystemEventEditorOutcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(eventID: event.eventIdentifier ?? event.calendarItemIdentifier, originalStart: originalStart, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let eventID: String
        let originalStart: Date
        let onFinish: (SystemEventEditorOutcome) -> Void
        private var didFinish = false
        init(eventID: String, originalStart: Date, onFinish: @escaping (SystemEventEditorOutcome) -> Void) {
            self.eventID = eventID; self.originalStart = originalStart; self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            guard !didFinish else { return }
            didFinish = true
            // The event was prefilled from TaskFlow's draft; discard those unsaved edits so the shared store stays clean.
            if action == .canceled { controller.event?.rollback() }
            switch action {
            case .canceled: onFinish(.canceled)
            case .saved: onFinish(.saved(controller.event?.eventIdentifier))
            case .deleted: onFinish(.deleted(EventDeletion(eventID: eventID, startDate: originalStart, scope: .thisEvent)))
            @unknown default: onFinish(.canceled)
            }
        }
    }
}

struct CalendarEventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var repository: TaskRepository
    let event: CalendarEvent
    let color: Color
    @State private var editDraft: EventDraft?
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var dismissAfterEditor = false
    @State private var showsAlternateTimes = false
    @State private var isEventActivityActive = false
    @State private var eventActivityError: String?
    @State private var isSavingAvailability = false
    @State private var availabilityError: String?
    @State private var detailConflicts: [CalendarEvent] = []
    @State private var localAvailability: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentEvent.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        if let location = currentEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                            Text(location).foregroundStyle(.secondary)
                        }
                        Text(dateText).padding(.top, 6)
                        Text(currentEvent.isAllDay ? "All day" : "\(timeText) (\(durationText))")
                            .foregroundStyle(.secondary)
                        if let recurrence = currentEvent.recurrenceSummary {
                            Text(recurrence).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if supportsAvailability {
                    Section("Show As · " + (currentEvent.availability ?? "Busy")) {
                        if canEdit {
                            EventAvailabilityControl(options: repository.availabilityOptions(for: currentEvent.calendarID), value: currentEvent.availability ?? "Busy", isSaving: isSavingAvailability) { updateAvailability($0.rawValue) }
                        } else { Text(currentEvent.availability ?? "Busy") }
                    }
                }
                Section {
                    if detailConflicts.isEmpty {
                        Label(!repository.calendarAffectsAvailability(currentEvent.calendarID) ? "This calendar does not affect availability" : currentEvent.availability == "Free" ? "Free events do not block time" : "No overlapping busy events", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        ForEach(detailConflicts, id: \.occurrenceKey) { item in
                            VStack(alignment: .leading) {
                                Label(item.title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text(item.isAllDay ? "All day" : item.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + item.endDate.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if canEdit { Button("Change Event Time", systemImage: "calendar.badge.clock") { editDraft = EventDraft(event: currentEvent) } }
                    }
                } header: { Text("Conflict Check") } footer: { Text("Checks overlapping events on calendars enabled under Settings → Calendars → Affects Availability.") }

                if let meeting = currentEvent.onlineMeeting {
                    Section {
                        Button(meeting.provider.buttonTitle, systemImage: meeting.provider.icon) { joinMeeting(meeting) }
                    }
                }

                Section {
                    LabeledContent("Calendar") {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 10, height: 10)
                            Text(calendarTitle)
                        }
                    }
                    if let source = currentEvent.calendarSource { LabeledContent("Account", value: source) }
                    LabeledContent("Time Zone", value: currentEvent.timeZoneIdentifier ?? TimeZone.current.identifier)
                }

                if let location = currentEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                    Section("Location") {
                        Button {
                            openLocation(location)
                        } label: {
                            Label(location, systemImage: "map")
                        }
                        .accessibilityHint("Opens directions in Maps")
                    }
                }

                if let url = currentEvent.url {
                    Section("URL") {
                        Link(destination: url) { Label(url.host ?? url.absoluteString, systemImage: "safari").lineLimit(1) }
                    }
                }

                if let notes = currentEvent.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Section("Notes") {
                        Text(notes).textSelection(.enabled)
                    }
                }

                if !currentEvent.attendees.isEmpty || currentEvent.organizerName != nil {
                    Section("Invitees") {
                        if let organizer = currentEvent.organizerName {
                            LabeledContent(organizer, value: "Organizer")
                        }
                        ForEach(currentEvent.attendees) { attendee in
                            LabeledContent {
                                Text(attendee.status)
                            } label: {
                                Text(attendee.name)
                                if !attendee.email.isEmpty { Text(attendee.email) }
                            }
                        }
                        Button("Find Alternate Times", systemImage: "calendar.badge.clock") { showsAlternateTimes = true }
                    }
                }

                let linkedTasks = repository.tasks.filter { currentEvent.notes?.contains("TaskFlow linked task: \($0.id)") == true }
                if !linkedTasks.isEmpty {
                    Section("Linked Tasks") {
                        ForEach(linkedTasks) { task in
                            Button { repository.openTask(id: task.id); dismiss() } label: { Label(task.title, systemImage: "checklist") }
                        }
                    }
                }

                if !currentEvent.id.isEmpty {
                    Section("Tags") {
                        TagSelectionEditor(
                            savedTags: repository.savedTags,
                            selectedTags: Binding(
                                get: { currentEvent.tags },
                                set: { tags in Task { await repository.setEventTags(tags, for: currentEvent.id) } }
                            ),
                            colorForTag: repository.color(forTag:),
                            onCreate: repository.saveTag
                        )
                    }
                }

                if canOfferEventActivity {
                    Section {
                        Toggle("Lock Screen Countdown", isOn: Binding(
                            get: { isEventActivityActive },
                            set: { _ in Task { await toggleEventActivity() } }
                        ))
                    } footer: {
                        Text("Shows this event\u{2019}s countdown on the Lock Screen and in the Dynamic Island.")
                    }
                }
                if canEdit {
                    Section {
                        Button("Delete Event", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
                    }
                }
            }
            .disabled(isDeleting)
            .overlay { if isDeleting { ProgressView("Deleting event…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius)) } }
            .listStyle(.insetGrouped)
            .taskFlowThemedBackground()
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isEventActivityActive = EventLiveActivityCoordinator.isActive(eventID: currentEvent.id)
                detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            }
            .alert("Could Not Update Availability", isPresented: Binding(get: { availabilityError != nil }, set: { if !$0 { availabilityError = nil } })) {
                Button("OK", role: .cancel) { availabilityError = nil }
            } message: { Text(availabilityError ?? "") }
            .onChange(of: repository.excludedAvailabilityCalendarIDs) { _, _ in
                detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            }
            .onChange(of: repository.calendarEvents) { _, _ in
                isEventActivityActive = EventLiveActivityCoordinator.isActive(eventID: currentEvent.id)
                detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            }
            .alert("Live Activity", isPresented: Binding(get: { eventActivityError != nil }, set: { if !$0 { eventActivityError = nil } })) {
                Button("OK", role: .cancel) { eventActivityError = nil }
            } message: {
                Text(eventActivityError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(isDeleting)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share event")
                    if canEdit {
                        Button("Edit") { editDraft = EventDraft(event: currentEvent) }.disabled(isDeleting)
                    }
                }
            }
            .confirmationDialog("Delete \(currentEvent.title)?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button(isRecurring ? "Delete This Event Only" : "Delete Event", role: .destructive) { delete(.thisEvent) }
                if isRecurring { Button("Delete This and Future Events", role: .destructive) { delete(.thisAndFuture) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isRecurring ? "Choose whether to delete this occurrence or this occurrence and all future events in the series. This change syncs with your calendar account." : "This removes the event from its calendar and synced devices.")
            }
            .alert("Could Not Delete Event", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                Button("Try Again") { deletionError = nil; confirmsDeletion = true }
                Button("Cancel", role: .cancel) { deletionError = nil }
            } message: { Text(deletionError ?? "") }
            .onChange(of: repository.lastEventDeletion) { _, deletion in
                guard let deletion, deletion.includes(event) else { return }
                if editDraft != nil { dismissAfterEditor = true; editDraft = nil }
                else { dismiss() }
            }
            .sheet(item: $editDraft, onDismiss: {
                if dismissAfterEditor { dismissAfterEditor = false; dismiss() }
            }) { draft in
                CalendarEventEditorView(repository: repository, draft: draft)
            }
            .sheet(isPresented: $showsAlternateTimes) {
                EventAvailabilitySuggestions(repository: repository, event: currentEvent, accent: color)
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private var isRecurring: Bool { currentEvent.recurrence != nil || currentEvent.recurrenceSummary != nil }
    private func delete(_ scope: EventDeletionScope) {
        guard !isDeleting else { return }
        let selected = currentEvent
        isDeleting = true
        Task {
            if !(await repository.deleteCalendarEvent(selected, scope: scope)) { deletionError = repository.eventSaveStatus }
            isDeleting = false
        }
    }

    private var canOfferEventActivity: Bool {
        !currentEvent.isAllDay && currentEvent.endDate > Date() && currentEvent.startDate < Date().addingTimeInterval(8 * 60 * 60)
    }

    @MainActor
    private func toggleEventActivity() async {
        if isEventActivityActive {
            await EventLiveActivityCoordinator.end(eventID: currentEvent.id)
            isEventActivityActive = false
            return
        }
        do {
            try await EventLiveActivityCoordinator.start(eventID: currentEvent.id, title: currentEvent.title,
                                                         calendarTitle: calendarTitle, location: currentEvent.location,
                                                         startDate: currentEvent.startDate, endDate: currentEvent.endDate)
            isEventActivityActive = true
        } catch {
            eventActivityError = error.localizedDescription
        }
    }

    private func updateAvailability(_ newAvailability: String) {
        guard let value = EventAvailability(rawValue: newAvailability), newAvailability != currentEvent.availability else { return }
        isSavingAvailability = true
        Task {
            if await repository.setEventAvailability(value, for: currentEvent) { localAvailability = value.rawValue }
            else { availabilityError = repository.eventSaveStatus }
            detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            isSavingAvailability = false
        }
    }

    private var supportsAvailability: Bool {
        repository.eventCalendars.first(where: { $0.id == currentEvent.calendarID })?.supportsAvailability ?? (currentEvent.availability != nil)
    }

    private var currentEvent: CalendarEvent {
        if let cached = repository.calendarEvents.first(where: { $0.id == event.id && $0.startDate == event.startDate }) { return cached }
        var fallback = event
        if let localAvailability { fallback.availability = localAvailability }
        return fallback
    }

    private var calendarTitle: String {
        repository.eventCalendars.first { $0.id == currentEvent.calendarID }?.title ?? "Calendar"
    }

    private var canEdit: Bool {
        repository.eventAccessState == .granted && repository.writableEventCalendars.contains { $0.id == currentEvent.calendarID }
    }

    private var dateText: String {
        // EventKit uses an exclusive midnight end date for all-day events.
        let displayEnd = currentEvent.isAllDay ? max(currentEvent.startDate, currentEvent.endDate.addingTimeInterval(-1)) : currentEvent.endDate
        if Calendar.current.isDate(currentEvent.startDate, inSameDayAs: displayEnd) {
            return currentEvent.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
        return "\(currentEvent.startDate.formatted(date: .abbreviated, time: .omitted)) – \(displayEnd.formatted(date: .abbreviated, time: .omitted))"
    }

    private var timeText: String {
        currentEvent.isAllDay ? "All day" : "\(currentEvent.startDate.formatted(date: .omitted, time: .shortened)) – \(currentEvent.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private var durationText: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: currentEvent.startDate, to: currentEvent.endDate)
        if let hour = components.hour, let minute = components.minute {
            if hour == 0 { return "\(minute) min" }
            if minute == 0 { return "\(hour) hr" }
            return "\(hour) hr \(minute) min"
        }
        return ""
    }

    private var shareText: String {
        [currentEvent.title, dateText, timeText, currentEvent.location].compactMap { $0 }.joined(separator: "\n")
    }

    private func openLocation(_ location: String) {
        if let url = MapNavigation.url(for: location) { openURL(url) }
    }

    private func joinMeeting(_ meeting: OnlineMeetingInfo) {
        guard let appURL = meeting.appURL else { openURL(meeting.url); return }
        openURL(appURL) { accepted in if !accepted { openURL(meeting.url) } }
    }
}

struct EventAvailabilitySuggestions: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let event: CalendarEvent
    let accent: Color
    @AppStorage("TaskFlow.calendar.workspace") private var planningData = Data()
    @State private var suggestions: [CalendarPlanningSlot] = []

    private var settings: CalendarWorkspaceSettings {
        (try? JSONDecoder().decode(CalendarWorkspaceSettings.self, from: planningData)) ?? CalendarWorkspaceSettings()
    }
    private var duration: Int { max(15, Int(event.endDate.timeIntervalSince(event.startDate) / 60)) }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 14, to: event.startDate) ?? event.startDate }
    private var shareText: String {
        let options = suggestions.prefix(5).map { $0.start.formatted(date: .complete, time: .shortened) }
        return "Suggested alternate times for \(event.title):\n" + options.map { "• \($0)" }.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Suggestions use calendars that affect availability, working hours, buffers, and timed tasks. Share a few options with attendees to coordinate a new time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Available times") {
                    if suggestions.isEmpty {
                        ContentUnavailableView("No alternate times found", systemImage: "calendar.badge.exclamationmark", description: Text("Check calendar access and working hours, or widen your planning settings."))
                    }
                    ForEach(suggestions) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(slot.start.formatted(date: .complete, time: .shortened)).font(.headline)
                            Text("Until \(slot.end.formatted(date: .omitted, time: .shortened))\(slot.preferred ? " · Preferred focus time" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                if !suggestions.isEmpty {
                    Section {
                        ShareLink(item: shareText) {
                            Label("Share proposed times", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Meeting Options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                let calendar = Calendar.current
                let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.startDate)) ?? event.startDate
                suggestions = Array(CalendarPlanningEngine.slots(
                    from: start,
                    through: end,
                    duration: duration,
                    settings: settings,
                    events: repository.planningEvents(from: start.addingTimeInterval(-86400), to: end),
                    tasks: repository.tasks
                ).prefix(8))
            }
        }
        .tint(accent)
    }
}
