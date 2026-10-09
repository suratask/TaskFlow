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

struct QuickCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let onTask: (TaskDraft) -> Void
    let onEvent: (EventDraft) -> Void
    @State private var input = ""
    @State private var parsedTitle = ""
    @State private var dueDate: Date?
    @State private var reminderMinutes: Int?
    @State private var captureKind = "Task"
    @State private var selectedListID = ""
    @State private var selectedCalendarID = ""
    @State private var eventEndDate = Date().addingTimeInterval(3600)
    @State private var parsed = QuickAddParse()

    init(repository: TaskRepository, onTask: @escaping (TaskDraft) -> Void, onEvent: @escaping (EventDraft) -> Void, initialText: String = "", initialKind: String = "Task") {
        self.repository = repository
        self.onTask = onTask
        self.onEvent = onEvent
        _input = State(initialValue: initialText)
        _parsedTitle = State(initialValue: initialText)
        _captureKind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Picker("Create", selection: $captureKind) {
                        Text("Task").tag("Task")
                        Text("Event").tag("Event")
                    }.pickerStyle(.segmented)
                    TextField("Describe it: Call the dentist Friday at 9", text: $input, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: input) { _, value in parse(value) }
                    QuickAddHighlights(text: input, parse: parsed)
                    Text("Try “Pay rent tomorrow 9am #bills !high @Home”. You can also dictate with the keyboard microphone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Preview") {
                    TextField("Title", text: $parsedTitle, axis: .vertical)
                    if captureKind == "Task" {
                        Picker("List", selection: $selectedListID) {
                            ForEach(repository.lists) { Text($0.title).tag($0.id) }
                        }
                        Toggle("Due date", isOn: Binding(get: { dueDate != nil }, set: { enabled in
                            if enabled, dueDate == nil { dueDate = Calendar.current.startOfDay(for: Date()) }
                            if !enabled { dueDate = nil; reminderMinutes = nil }
                        }))
                        if let dueDate {
                            DatePicker("Due", selection: Binding(get: { dueDate }, set: { self.dueDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                            Picker("Remind", selection: Binding(get: { reminderMinutes ?? 0 }, set: { reminderMinutes = $0 == 0 ? nil : $0 })) {
                                Text("At due time").tag(0)
                                Text("5 minutes before").tag(5)
                                Text("15 minutes before").tag(15)
                                Text("30 minutes before").tag(30)
                                Text("1 hour before").tag(60)
                            }
                        }
                    } else {
                        Picker("Calendar", selection: $selectedCalendarID) {
                            ForEach(repository.writableEventCalendars) { Text($0.title).tag($0.id) }
                        }
                        if let dueDate {
                            DatePicker("Starts", selection: Binding(get: { dueDate }, set: { self.dueDate = $0; eventEndDate = max(eventEndDate, $0.addingTimeInterval(1800)) }), displayedComponents: [.date, .hourAndMinute])
                            DatePicker("Ends", selection: $eventEndDate, in: (dueDate.addingTimeInterval(60))..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                    if !input.isEmpty {
                        Label(dueDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No date recognized", systemImage: dueDate == nil ? "calendar.badge.questionmark" : "calendar")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Quick Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { savePreview() }
                        .disabled(parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (captureKind == "Event" && repository.writableEventCalendars.isEmpty))
                }
            }
            .onAppear {
                selectedListID = repository.makeDraft().listID
                selectedCalendarID = repository.makeEventDraft().calendarID
                if !input.isEmpty { parse(input) }
            }
        }
    }

    private func parse(_ text: String) {
        // Shared natural-language parser: dates and times, #tags, !priority, @list, "remind me … before".
        let result = QuickAddParser.parse(text, lists: repository.lists.map { (id: $0.id, title: $0.title) })
        parsed = result
        dueDate = result.dueDate
        reminderMinutes = result.alarmMinutes
        if let listID = result.listID { selectedListID = listID }
        parsedTitle = result.title.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : result.title
        if let dueDate { eventEndDate = dueDate.addingTimeInterval(3600) }
    }

    private func savePreview() {
        if captureKind == "Task" {
            var draft = repository.makeDraft()
            draft.listID = selectedListID
            draft.title = parsedTitle
            draft.dueDate = dueDate
            draft.hasDueTime = dueDate.map { Calendar.current.dateComponents([.hour, .minute], from: $0).hour != 0 || Calendar.current.dateComponents([.hour, .minute], from: $0).minute != 0 } ?? false
            draft.alarmOffsetMinutes = reminderMinutes
            draft.tags = parsed.tags
            if let priority = parsed.priority { draft.priority = priority }
            draft.isFlagged = draft.isFlagged || parsed.isFlagged
            onTask(draft)
        } else {
            var draft = repository.makeEventDraft(startDate: dueDate ?? Date(), endDate: eventEndDate)
            draft.calendarID = selectedCalendarID
            draft.title = parsedTitle
            draft.alarmOffsetMinutes = reminderMinutes
            onEvent(draft)
        }
        dismiss()
    }
}
