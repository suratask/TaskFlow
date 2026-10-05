import SwiftUI
import MapKit
import PhotosUI
import UniformTypeIdentifiers

struct TaskEditorView: View {
    @State private var isSaving = false
    @State private var attachmentImports = 0
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @State var draft: TaskDraft
    /// When set, the editor shows an existing task in place (Reminders-style) and saves changes as you make them.
    var task: TaskItem? = nil
    var showsDoneButton = false

    @State private var lastSavedDraft: TaskDraft?
    @State private var autosaveWork: Task<Void, Never>?
    @State private var isConfirmingDelete = false
    @State private var previewDocument: AttachmentPreviewDocument?
    @Environment(\.openURL) private var openURL

    @State private var showsMoreOptions = false
    @State private var repeats = false
    @State private var recurrence = RecurrenceRule(frequency: .daily, interval: 1)
    @State private var recurrenceEndMode = RecurrenceEndMode.never
    @State private var recurrenceEndDate = Date().addingTimeInterval(86400 * 30)
    @State private var recurrenceOccurrenceCount = 10
    @State private var monthDaysText = ""
    @State private var monthsText = ""

    @State private var isFileImporterPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @FocusState private var focusedField: EditorField?

    private enum EditorField: Hashable {
        case title
        case notes
        case location
    }

    private enum RecurrenceEndMode: String, CaseIterable, Identifiable {
        case never = "Never"
        case onDate = "On Date"
        case afterCount = "After Count"

        var id: String { rawValue }
    }

    var body: some View {
        if repository.listProfile(draft.listID).type == .shopping {
            if task != nil { ShoppingItemEditor(repository: repository, draft: draft, task: task) }
            else { NavigationStack { ShoppingItemEditor(repository: repository, draft: draft, task: task) } }
        } else if task != nil {
            editorForm
        } else {
            NavigationStack { editorForm }
        }
    }

    private var isEditingInPlace: Bool { task != nil }

    private var editorForm: some View {
            Form {
                if let task {
                    Section {
                        Button {
                            Task { await repository.toggleCompletion(for: task) }
                        } label: {
                            Label {
                                Text(task.isCompleted ? "Completed" : "Mark as Completed")
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: task.isCompleted ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                }

                Section {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focusedField, equals: .title)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focusedField, equals: .notes)
                    TextField("URL", text: $draft.urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if !draft.hasValidURL { Text("Enter a complete URL, including https://.").foregroundStyle(.red) }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { draft.dueDate != nil },
                        set: { draft.dueDate = $0 ? (draft.dueDate ?? Calendar.current.startOfDay(for: Date())) : nil }
                    )) {
                        Label("Date", systemImage: "calendar")
                    }
                    if draft.dueDate != nil {
                        DatePicker("Due Date", selection: dueDateBinding, displayedComponents: [.date])
                    }
                    Toggle(isOn: $draft.hasDueTime) {
                        Label("Time", systemImage: "clock")
                    }
                    .disabled(draft.dueDate == nil)
                    if draft.dueDate != nil && draft.hasDueTime {
                        DatePicker("Due Time", selection: dueDateBinding, displayedComponents: [.hourAndMinute])
                    }
                }

                Section {
                    Picker(selection: $draft.listID) {
                        ForEach(repository.lists) { Text($0.title).tag($0.id) }
                    } label: {
                        Label("List", systemImage: "list.bullet")
                    }
                    Picker(selection: $draft.priority) {
                        ForEach(TaskPriority.allCases) { Text($0.rawValue).tag($0) }
                    } label: {
                        Label("Priority", systemImage: "exclamationmark")
                    }
                    Toggle(isOn: $draft.isFlagged) {
                        Label("Flag", systemImage: "flag")
                    }
                    Picker(selection: $draft.status) {
                        ForEach(TaskStatus.editableCases) { Text($0.rawValue).tag($0) }
                    } label: {
                        Label("Status", systemImage: "circle.dashed")
                    }
                }

                if let task, repository.listProfile(draft.listID).type != .standard {
                    Section {
                        NavigationLink {
                            SpecializedTaskEditor(repository: repository, task: task, type: repository.listProfile(draft.listID).type)
                        } label: {
                            Label(repository.listProfile(draft.listID).type.rawValue + " Details", systemImage: repository.listProfile(draft.listID).type.icon)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        Form {
                            ReminderOptionsCard(draft: $draft)
                            repeatCard
                            tagsCard
                            attachmentsCard
                        }
                        .taskFlowThemedBackground()
                        .navigationTitle("Details")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent {
                            Text(detailsSummary)
                        } label: {
                            Label("Details", systemImage: "slider.horizontal.3")
                        }
                    }
                } footer: {
                    Text("Repeat, alerts, start date, location, tags, and attachments.")
                }

                if let task {
                    Section {
                        NavigationLink {
                            TaskSubtasksScreen(repository: repository, parentID: task.id)
                        } label: {
                            Label("Subtasks", systemImage: "list.bullet.indent")
                                .badge(repository.subtasks(for: task).count)
                        }
                        NavigationLink {
                            TaskDependenciesScreen(repository: repository, taskID: task.id)
                        } label: {
                            Label("Dependencies", systemImage: "arrow.triangle.branch")
                                .badge(task.blockedByTaskIDs.count)
                        }
                        NavigationLink {
                            TaskCommentsScreen(repository: repository, taskID: task.id)
                        } label: {
                            Label("Comments", systemImage: "bubble.left.and.bubble.right")
                                .badge(task.comments.count)
                        }
                    }

                    Section {
                        Button("Delete Task", role: .destructive) { isConfirmingDelete = true }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $previewDocument) { document in
                AttachmentQuickLookPreview(url: document.url).ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                importFiles(result)
            }
            .onChange(of: selectedPhotos) { _, newItems in
                importPhotos(newItems)
            }
            .onAppear {
                setupRecurrenceState()
                if isEditingInPlace {
                    lastSavedDraft = finalizedDraft()
                } else if draft.reminderID == nil {
                    focusedField = .title
                }
            }
            .onChange(of: finalizedDraft()) { _, newValue in
                scheduleAutosave(newValue)
            }
            .onChange(of: task) { _, latest in
                refreshFromRepository(latest)
            }
            .onDisappear {
                guard isEditingInPlace else { return }
                autosaveWork?.cancel()
                let pending = finalizedDraft()
                if pending != lastSavedDraft && canSave {
                    Task { await repository.saveTask(pending) }
                }
            }
            .confirmationDialog("Delete this task?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Task", role: .destructive) {
                    guard let task else { return }
                    autosaveWork?.cancel()
                    lastSavedDraft = finalizedDraft()
                    Task { await repository.deleteTask(task) }
                    dismiss()
                }
            }
            .interactiveDismissDisabled(isSaving)
            .taskFlowThemedBackground()
            .navigationTitle(editorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let task {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: task.shareText) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share task")
                    }
                    if showsDoneButton {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(attachmentImports > 0 ? "Importing…" : "Done") { dismiss() }.disabled(attachmentImports > 0)
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(attachmentImports > 0 ? "Importing…" : (draft.reminderID == nil ? "Add" : "Done")) { save() }
                            .disabled(!canSave || isSaving || attachmentImports > 0)
                    }
                }
            }
    }

    /// Saves in-place edits shortly after the user stops typing, the way Reminders does.
    private func scheduleAutosave(_ pending: TaskDraft) {
        guard isEditingInPlace, pending != lastSavedDraft, canSave else { return }
        autosaveWork?.cancel()
        autosaveWork = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if await repository.saveTask(pending) {
                lastSavedDraft = pending
            }
        }
    }

    /// Picks up changes made elsewhere (completing from a list, widgets) unless the user has unsaved edits.
    private func refreshFromRepository(_ latest: TaskItem?) {
        guard let latest, finalizedDraft() == lastSavedDraft else { return }
        draft = TaskDraft(task: latest)
        setupRecurrenceState()
        lastSavedDraft = finalizedDraft()
    }

    private var dueDateBinding: Binding<Date> {
        Binding(get: { draft.dueDate ?? Date() }, set: { draft.dueDate = $0 })
    }

    private var detailsSummary: String {
        var parts: [String] = []
        if repeats { parts.append("Repeats") }
        if draft.alarmOffsetMinutes != nil || !draft.additionalAlerts.isEmpty { parts.append("Alert") }
        if draft.location != nil { parts.append("Location") }
        if !draft.tags.isEmpty { parts.append("\(draft.tags.count) tag\(draft.tags.count == 1 ? "" : "s")") }
        if !draft.attachments.isEmpty { parts.append("\(draft.attachments.count) file\(draft.attachments.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    private var editorTitle: String {
        if isEditingInPlace { return "Details" }
        return draft.reminderID == nil ? "New Task" : "Edit Task"
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.listID.isEmpty && draft.hasValidURL
    }

    // MARK: - Detail sections

    @ViewBuilder
    private var repeatCard: some View {
        Section("Repeat") {
            Toggle("Repeat", isOn: $repeats)
            if repeats {
                Picker("Frequency", selection: $recurrence.frequency) {
                    ForEach(RecurrenceFrequency.allCases) { freq in
                        Text(freq.rawValue).tag(freq)
                    }
                }
                Stepper("Every \(recurrence.interval) \(recurrence.frequency.unitName(plural: recurrence.interval != 1))", value: $recurrence.interval, in: 1...99)
                if recurrence.frequency == .weekly {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { recurrence.weekdays.contains(day) }, set: { enabled in
                            if enabled { recurrence.weekdays = Array(Set(recurrence.weekdays + [day])).sorted() }
                            else { recurrence.weekdays.removeAll { $0 == day } }
                        }))
                    }
                }
                if recurrence.frequency == .monthly {
                    TextField("Days of month, e.g. 1, 15, -1", text: $monthDaysText)
                }
                if recurrence.frequency == .yearly {
                    TextField("Months, e.g. 1, 6, 12", text: $monthsText)
                }
                Picker("End Repeat", selection: $recurrenceEndMode) {
                    ForEach(RecurrenceEndMode.allCases) { Text($0.rawValue).tag($0) }
                }
                if recurrenceEndMode == .onDate {
                    DatePicker("End Date", selection: $recurrenceEndDate, displayedComponents: .date)
                }
                if recurrenceEndMode == .afterCount {
                    Stepper("After \(recurrenceOccurrenceCount) times", value: $recurrenceOccurrenceCount, in: 1...999)
                }
            }
        }
    }

    @ViewBuilder
    private var tagsCard: some View {
        Section("Tags") {
            TagSelectionEditor(
                savedTags: repository.savedTags,
                selectedTags: $draft.tags,
                colorForTag: repository.color(forTag:),
                onCreate: repository.saveTag
            )
        }
    }

    @ViewBuilder
    private var attachmentsCard: some View {
        Section("Attachments") {
            ForEach(draft.attachments) { att in
                Button {
                    if att.kind == .url, let url = repository.attachmentURL(for: att) {
                        openURL(url)
                    } else if let url = repository.attachmentURL(for: att) {
                        previewDocument = AttachmentPreviewDocument(url: url)
                    } else if let link = att.urlString, let url = URL(string: link) {
                        openURL(url)
                    }
                } label: {
                    Label(att.title, systemImage: att.icon).lineLimit(1)
                }
                .tint(.primary)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            draft.attachments.removeAll { $0.id == att.id }
                        }
                    }
            }
            PhotosPicker(selection: $selectedPhotos, matching: .images) {
                Label("Add Photo", systemImage: "photo")
            }
            Button("Add File", systemImage: "doc") { isFileImporterPresented = true }
        }
    }

    // MARK: - Helper Actions

    private func setupRecurrenceState() {
        if let rule = draft.recurrence {
            repeats = true
            recurrence = rule
            monthDaysText = rule.monthDays.map(String.init).joined(separator: ", ")
            monthsText = rule.months.map(String.init).joined(separator: ", ")
            switch rule.end {
            case .never:
                recurrenceEndMode = .never
            case .onDate(let date):
                recurrenceEndMode = .onDate
                recurrenceEndDate = date
            case .afterOccurrences(let count):
                recurrenceEndMode = .afterCount
                recurrenceOccurrenceCount = count
            }
        } else {
            repeats = false
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let finalDraft = finalizedDraft()
        Task {
            defer { isSaving = false }
            if await repository.saveTask(finalDraft) { dismiss() }
        }
    }

    /// The draft with the repeat controls folded into its recurrence rule.
    private func finalizedDraft() -> TaskDraft {
        var finalDraft = draft
        if repeats {
            var rule = recurrence
            if rule.frequency == .monthly {
                rule.monthDays = Array(Set(monthDaysText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...31).contains($0) || (-31 ... -1).contains($0) })).sorted()
            }
            if rule.frequency == .yearly {
                rule.months = Array(Set(monthsText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...12).contains($0) })).sorted()
            }
            switch recurrenceEndMode {
            case .never:
                rule.end = .never
            case .onDate:
                rule.end = .onDate(recurrenceEndDate)
            case .afterCount:
                rule.end = .afterOccurrences(recurrenceOccurrenceCount)
            }
            finalDraft.recurrence = rule
        } else {
            finalDraft.recurrence = nil
        }
        return finalDraft
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        attachmentImports += 1
        Task {
            defer { attachmentImports -= 1 }
            do {
                for url in try result.get() {
                    let attachment = try await repository.importFileAttachmentAsync(from: url)
                    draft.attachments.append(attachment)
                }
            } catch { repository.errorMessage = error.localizedDescription }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        attachmentImports += 1
        Task {
            defer { attachmentImports -= 1 }
            do {
                for item in items {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let attachment = try await repository.importPhotoAttachmentAsync(data: data, suggestedName: "photo.jpg")
                    draft.attachments.append(attachment)
                }
            } catch { repository.errorMessage = error.localizedDescription }
        }
    }

}

private struct ReminderOptionsCard: View {
    @Binding var draft: TaskDraft
    @State private var locationQuery = ""
    @State private var results: [LocationLookupResult] = []
    @State private var searching = false
    @State private var searchError = ""
    var body: some View {
        Section("Alerts") {
            Picker("Alert", selection: $draft.alarmOffsetMinutes) {
                Text("None").tag(Optional<Int>.none)
                ForEach([0, 5, 15, 30, 60, 120, 1440], id: \.self) { value in
                    Text(ReminderAlert.relative(minutesBefore: value).title).tag(Optional(value))
                }
                if let current = draft.alarmOffsetMinutes, ![0, 5, 15, 30, 60, 120, 1440].contains(current) {
                    Text(ReminderAlert.relative(minutesBefore: current).title).tag(Optional(current))
                }
            }
            .disabled(draft.dueDate == nil)
            ForEach(draft.additionalAlerts.indices, id: \.self) { index in
                Group {
                    switch draft.additionalAlerts[index] {
                    case .absolute(let date):
                        DatePicker("Alert", selection: Binding(get: {
                            guard draft.additionalAlerts.indices.contains(index), case .absolute(let value) = draft.additionalAlerts[index] else { return date }
                            return value
                        }, set: {
                            guard draft.additionalAlerts.indices.contains(index) else { return }
                            draft.additionalAlerts[index] = .absolute($0)
                        }))
                    case .relative(let minutes):
                        Text(ReminderAlert.relative(minutesBefore: minutes).title)
                    }
                }
                .swipeActions {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        if draft.additionalAlerts.indices.contains(index) { draft.additionalAlerts.remove(at: index) }
                    }
                }
            }
            Button("Add Alert", systemImage: "plus") { draft.additionalAlerts.append(.absolute(draft.dueDate ?? Date().addingTimeInterval(3600))) }
        }

        Section("Start Date") {
            Toggle("Start Date", isOn: Binding(get: { draft.startDate != nil }, set: { draft.startDate = $0 ? min(Date(), draft.dueDate ?? Date()) : nil }))
            if draft.startDate != nil {
                DatePicker("Starts", selection: Binding(get: { draft.startDate ?? Date() }, set: { draft.startDate = $0 }), displayedComponents: draft.hasStartTime ? [.date, .hourAndMinute] : [.date])
                Toggle("Start Time", isOn: $draft.hasStartTime)
            }
        }

        Section {
            if let location = draft.location {
                Label(location.displayTitle, systemImage: "mappin.and.ellipse")
                if location.latitude != nil && location.longitude != nil {
                    Picker("Notify", selection: Binding(get: { draft.location?.proximity ?? .onArrival }, set: { draft.location?.proximity = $0 })) {
                        ForEach(LocationProximity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Radius: \(Int(location.radius)) m", value: Binding(get: { draft.location?.radius ?? 100 }, set: { draft.location?.radius = $0 }), in: 0...1000, step: 50)
                }
                Button("Remove Location", role: .destructive) { draft.location = nil }
            }
            HStack {
                TextField("Search place or address", text: $locationQuery)
                    .onSubmit { search() }
                    .submitLabel(.search)
                if searching { ProgressView() }
            }
            ForEach(results) { result in
                Button { draft.location = result.location; results = []; locationQuery = "" } label: { LocationLookupRow(result: result) }
                    .tint(.primary)
            }
        } header: {
            Text("Location")
        } footer: {
            if !searchError.isEmpty { Text(searchError) }
            else if draft.location != nil && draft.location?.latitude == nil { Text("Select a search result to enable arrival or departure alerts.") }
        }
    }
    private func search() {
        guard !searching, !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true
        searchError = ""
        Task {
            defer { searching = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = locationQuery
                let response = try await MKLocalSearch(request: request).start()
                results = response.mapItems.prefix(5).map(LocationLookupResult.init(mapItem:))
                if results.isEmpty { searchError = "No locations found. Try a more specific address." }
            } catch { searchError = error.localizedDescription }
        }
    }
}
