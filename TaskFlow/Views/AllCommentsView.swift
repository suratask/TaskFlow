import AVFoundation
import LinkPresentation
import QuickLookThumbnailing
import SafariServices
import Speech
import PhotosUI
import SwiftUI
import PencilKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct AllNotesView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var repository: TaskRepository
    @Binding var selectedCalendarEvent: CalendarEvent?
    @State private var listCache = NotesListCache()
    @State private var searchQuery = ""
    @State private var folderFilter = ""
    @State private var tagFilter = ""
    @State private var collection: NotesCollection = .all
    @State private var selectedNote: QuickNote?
    @State private var noteToMove: QuickNote?
    @State private var noteFilter: NotesFilter = .all
    @State private var quickNoteEditorDraft: QuickNoteEditorDraft?

    private var taskNotes: [TaskCommentItem] {
        listCache.taskNotes(key: cacheKey + [String(repository.tasksRevision)]) { calculateTaskNotes() }
    }

    private var cacheKey: [String] {
        [searchQuery, folderFilter, tagFilter, collection.rawValue, String(describing: repository.quickTagFilter), String(describing: repository.selectedTagFilter)]
    }

    private func calculateTaskNotes() -> [TaskCommentItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return repository.tasks.flatMap { task in
            task.comments.map { comment in
                TaskCommentItem(task: task, comment: comment)
            }
        }
        .filter { item in
            guard matchesActiveTagFilter(item.task.tags) else { return false }
            guard !query.isEmpty else { return true }
            return [
                item.comment.text,
                item.task.title,
                item.task.notes,
                item.task.tags.joined(separator: " "),
                item.task.attachments.map(\.title).joined(separator: " "),
                item.task.location?.displayTitle,
                item.task.location?.displayAddress
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
        .sorted { lhs, rhs in
            lhs.comment.createdAt > rhs.comment.createdAt
        }
    }

    private var quickNotes: [QuickNote] {
        listCache.notes(key: cacheKey + [String(repository.tasksRevision), String(repository.notesRevision)]) { calculateQuickNotes() }
    }

    private func calculateQuickNotes() -> [QuickNote] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return repository.quickNotes
            .filter { note in
                guard matchesActiveTagFilter(note.tags) else { return false }
                guard folderFilter.isEmpty || (folderFilter == "__unfiled" ? note.folder.isEmpty : note.folder == folderFilter) else { return false }
                guard tagFilter.isEmpty || note.tags.contains(tagFilter) else { return false }
                switch collection {
                case .all: break
                case .pinned: guard note.isPinned else { return false }
                case .linked:
                    guard note.linkedTaskID != nil || repository.linkedNoteURLs.contains(TaskFlowDeepLink.noteURL(note.id)) else { return false }
                case .unfinished: guard note.hasUnfinishedChecklist else { return false }
                }
                guard !query.isEmpty else { return true }
                return [
                    note.title,
                    note.folder,
                    note.text,
                    note.tags.joined(separator: " "),
                    note.attachments.map(\.title).joined(separator: " "),
                    note.attachments.map { [$0.urlString, $0.localPath].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ")
                ]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(query)
            }
            .sorted { $0.isPinned == $1.isPinned ? $0.createdAt > $1.createdAt : $0.isPinned }
    }

    private func matchesActiveTagFilter(_ tags: [String]) -> Bool {
        for filter in [repository.quickTagFilter, repository.selectedTagFilter].compactMap({ $0 }) {
            switch filter {
            case .tag(let name):
                guard tags.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return false }
            case .noTags:
                guard tags.isEmpty else { return false }
            }
        }
        return true
    }

    private var totalCount: Int {
        quickNotes.count + taskNotes.count
    }

    private var openCount: Int {
        quickNotes.filter { !$0.isResolved }.count + taskNotes.filter { !$0.comment.isResolved }.count
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $noteFilter) {
                    ForEach(NotesFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section("Collections") {
                Picker("Collection", selection: $collection) {
                    ForEach(NotesCollection.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Folder", selection: $folderFilter) {
                    Text("All Folders").tag("")
                    Text("Unfiled").tag("__unfiled")
                    ForEach(Array(Set(repository.quickNotes.map(\.folder))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Tag", selection: $tagFilter) {
                    Text("All Tags").tag("")
                    ForEach(Array(Set(repository.quickNotes.flatMap(\.tags))).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                NavigationLink {
                    AllTaskCommentsView(repository: repository)
                } label: {
                    Label("All Comments", systemImage: "text.bubble")
                        .badge(taskNotes.count)
                }
            } footer: {
                Text("\(totalCount) notes · \(openCount) open")
            }

            if !repository.noteDrafts.isEmpty {
                Section("Recoverable Drafts") {
                    ForEach(repository.noteDrafts) { recovery in
                        Button {
                            quickNoteEditorDraft = QuickNoteEditorDraft(recovery: recovery)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(recovery.note.title.isEmpty ? "Untitled draft" : recovery.note.title).font(.headline)
                                Text(recovery.savedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("Discard", role: .destructive) { repository.discardNoteDraft(id: recovery.id) } }
                    }
                }
            }
            if shouldShowQuickNotes {
                if quickNotes.isEmpty {
                    emptyQuickNotes
                } else {
                    Section("Quick Notes") {
                        ForEach(quickNotes) { note in
                            QuickNoteRow(
                                note: note,
                                color: repository.appTheme.secondary,
                                colorForTag: repository.color(forTag:),
                                linkedTask: linkedTask(for: note),
                                linkedEvent: linkedEvent(for: note),
                                attachmentURL: repository.attachmentURL(for:),
                                onSelect: {
                                    selectedNote = note
                                },
                                onChecklistChange: { id, checked in repository.setNoteChecklistItem(noteID: note.id, itemID: id, checked: checked) }
                            )
                            .swipeActions(edge: .leading) {
                                Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") { repository.toggleNotePin(note) }.tint(.orange)
                            }
                            .contextMenu {
                                Button("Move to Folder", systemImage: "folder") { noteToMove = note }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Move", systemImage: "folder") { noteToMove = note }.tint(.blue)
                                Button(role: .destructive) {
                                    Task { await repository.deleteQuickNote(note) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }

            if repository.isSearchActive && !repository.filteredCalendarEvents.isEmpty {
                Section("Calendar Events") {
                    ForEach(repository.filteredCalendarEvents, id: \.occurrenceKey) { event in
                        NotesCalendarEventSearchRow(event: event, color: eventColor(for: event.calendarID)) {
                            selectedCalendarEvent = event
                        }
                    }
                }
            }

            if shouldShowTaskNotes {
                if taskNotes.isEmpty {
                    emptyTaskNotes
                } else {
                    Section("Task Notes") {
                        ForEach(taskNotes) { item in
                            TaskNoteOverviewRow(
                                item: item,
                                listColor: listColor(for: item.task.listID),
                                isSelected: repository.selectedTaskID == item.task.id
                            ) {
                                selectTask(item.task)
                            }
                        }
                    }
                }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Notes")
        .listStyle(.insetGrouped)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = TaskFlowWebNotesConfiguration.websiteURL { Link("Open Notes in Browser", destination: url) }
                    if let undo = repository.noteUndo { Button("Undo " + undo.message, systemImage: "arrow.uturn.backward") { repository.restoreNote(undo) }.keyboardShortcut("z", modifiers: .command) }
                    if let redo = repository.noteRedo { Button("Redo " + redo.message, systemImage: "arrow.uturn.forward") { repository.restoreNote(redo, isRedo: true) }.keyboardShortcut("z", modifiers: [.command, .shift]) }
                } label: { Label("More", systemImage: "ellipsis") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    quickNoteEditorDraft = QuickNoteEditorDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("New quick note")
            }
        }
        .task { consumeNoteCaptureRequest(); openRequestedNote() }
        .onChange(of: repository.pendingOpenNoteID) { _, _ in openRequestedNote() }
        .onChange(of: repository.pendingNoteCapture) { _, _ in consumeNoteCaptureRequest() }
        .onChange(of: quickNoteEditorDraft?.id) { _, id in
            if id == nil { consumeNoteCaptureRequest() }
        }
        .sheet(item: $noteToMove) { note in NoteMoveFolderView(repository: repository, note: note) }
        .noteEditorPresentation(repository: repository, draft: $quickNoteEditorDraft)
        .navigationDestination(item: $selectedNote) { note in
            NativeNoteDetailView(repository: repository, noteID: note.id)
        }
    }

    private func openRequestedNote() {
        guard let id = repository.pendingOpenNoteID else { return }
        repository.pendingOpenNoteID = nil
        if let note = repository.quickNotes.first(where: { $0.id == id }) { selectedNote = note }
        else { repository.errorMessage = "That note is no longer available." }
    }

    private func consumeNoteCaptureRequest() {
        // Keep an existing draft intact; handle the new request once it is closed.
        guard quickNoteEditorDraft == nil, let mode = repository.pendingNoteCapture else { return }
        repository.pendingNoteCapture = nil
        quickNoteEditorDraft = QuickNoteEditorDraft(startWithDictation: mode == .dictateNote)
    }

    private var shouldShowQuickNotes: Bool {
        noteFilter == .all || noteFilter == .quick
    }

    private var shouldShowTaskNotes: Bool {
        noteFilter == .all || noteFilter == .task
    }

    private var emptyQuickNotes: some View {
        ContentUnavailableView {
            Label("No Quick Notes", systemImage: "square.and.pencil")
        } description: {
            Text("Capture an idea, checklist, or reference without attaching it to a task.")
        } actions: {
            Button("New Note") { quickNoteEditorDraft = QuickNoteEditorDraft() }
        }
        .listRowBackground(Color.clear)
    }

    private var emptyTaskNotes: some View {
        ContentUnavailableView {
            Label("No Task Notes", systemImage: "text.bubble")
        } description: {
            Text("Comments and notes added to tasks will appear here, alongside their task context.")
        }
        .listRowBackground(Color.clear)
    }

    private func listColor(for listID: String) -> Color {
        repository.lists.first { $0.id == listID }?.color ?? repository.appTheme.primary
    }

    private func eventColor(for calendarID: String) -> Color {
        repository.eventCalendars.first { $0.id == calendarID }?.color ?? .blue
    }

    private func linkedTask(for note: QuickNote) -> TaskItem? {
        guard let linkedTaskID = note.linkedTaskID else { return nil }
        return repository.tasks.first { $0.id == linkedTaskID }
    }

    private func linkedEvent(for note: QuickNote) -> CalendarEvent? {
        guard let linkedEventID = note.linkedEventID else { return nil }
        return repository.filteredCalendarEvents.first { $0.id == linkedEventID }
    }

    private func selectTask(_ task: TaskItem) {
        guard verticalSizeClass != .compact else {
            repository.selectedTaskID = nil
            return
        }
        repository.selectTask(task)
    }
}

private enum NotesFilter: String, CaseIterable, Identifiable {
    case all
    case quick
    case task

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .quick: "Quick"
        case .task: "Task"
        }
    }
}

private struct TaskCommentItem: Identifiable, Hashable {
    let task: TaskItem
    let comment: TaskComment

    var id: String {
        "\(task.id)-\(comment.id.uuidString)"
    }
}

private struct NotesCalendarEventSearchRow: View {
    let event: CalendarEvent
    let color: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).foregroundStyle(.primary).lineLimit(1)
                    Text(timeText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                Image(systemName: "calendar").foregroundStyle(color)
            }
        }
        .buttonStyle(.plain)
    }

    private var timeText: String {
        if event.isAllDay {
            return event.startDate.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(event.startDate.formatted(date: .abbreviated, time: .shortened)) - \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

private struct QuickNoteEditorDraft: Identifiable {
    let id: UUID
    var note: QuickNote?
    var startWithDictation: Bool
    var recovery: NoteEditorRecovery?
    var seed: QuickNote? { recovery?.note ?? note }
    init(note: QuickNote? = nil, startWithDictation: Bool = false, recovery: NoteEditorRecovery? = nil) {
        id = recovery?.id ?? UUID()
        self.note = recovery?.originalNoteID != nil ? recovery?.note : note
        self.startWithDictation = startWithDictation
        self.recovery = recovery
    }
}

private struct QuickNoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var repository: TaskRepository
    let draft: QuickNoteEditorDraft
    @State private var checklistTaskDraft: TaskDraft?
    @State private var folder = ""
    @State private var isFinalized = false
    @State private var recoveryStatus = ""
    @State private var pendingTranscript = ""
    @State private var title = ""
    @State private var text = ""
    @State private var selectedTags: [String] = []
    @State private var linkedTaskID: String?
    @State private var linkedEventID: String?
    @State private var format: QuickNoteFormat = .plain
    @State private var layout: QuickNoteLayout = .standard
    @State private var drawingData: Data?
    @State private var attachments: [TaskAttachment] = []
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachmentImports = 0
    @State private var isFileImporterPresented = false
    @State private var isDictationPresented = false
    @State private var didHandleInitialDictation = false
    @State private var drawingUndoToken = 0
    @State private var drawingClearToken = 0
    @State private var isTextFocused = false
    @State private var formattingCommand: NoteFormattingCommand?

    init(repository: TaskRepository, draft: QuickNoteEditorDraft) {
        self.repository = repository
        self.draft = draft
        _folder = State(initialValue: draft.seed?.folder ?? "")
        _title = State(initialValue: draft.seed?.title ?? "")
        _text = State(initialValue: NoteRichText.legacyText(draft.seed?.text ?? "", format: draft.seed?.format ?? .plain))
        _selectedTags = State(initialValue: draft.seed?.tags ?? [])
        _linkedTaskID = State(initialValue: draft.seed?.linkedTaskID)
        _linkedEventID = State(initialValue: draft.seed?.linkedEventID)
        _format = State(initialValue: .markdown)
        _layout = State(initialValue: draft.seed?.layout ?? .standard)
        _drawingData = State(initialValue: draft.seed?.drawingData)
        _attachments = State(initialValue: draft.seed?.attachments ?? [])
        _urlText = State(initialValue: draft.recovery?.pendingURL ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Title", text: $title)
                        .font(.headline)

                    NoteFormattingTextEditor(text: $text, command: $formattingCommand, focused: $isTextFocused)
                        .frame(height: 260)

                    QuickNoteFormattingToolbar(format: $format, text: $text, command: $formattingCommand)
                    Button("Dictate Note", systemImage: "mic") {
                        isTextFocused = false
                        isDictationPresented = true
                    }

                    Label(timestampText, systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Section("Drawing") {
                    QuickNoteDrawingCanvas(
                        drawingData: $drawingData,
                        undoToken: drawingUndoToken,
                        clearToken: drawingClearToken
                    )
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))

                    HStack(spacing: 12) {
                        Button {
                            drawingUndoToken += 1
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            drawingData = nil
                            drawingClearToken += 1
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .disabled(drawingData == nil)
                    }
                    .font(.subheadline.weight(.semibold))
                }

                Section("Attachments") {
                    HStack {
                        TextField("Add URL", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { _ = commitPendingURL(showError: true) }

                        Button {
                            addURLAttachment()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 6, matching: .images) {
                            Label("Photos", systemImage: "photo.on.rectangle.angled")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Label("Files", systemImage: "paperclip")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let urlError { Text(urlError).font(.caption).foregroundStyle(.red) }

                    if attachments.isEmpty {
                        Label("Attach links, files, and photos to keep note context together.", systemImage: "paperclip")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        QuickNoteAttachmentList(repository: repository, attachments: attachments) { attachment in
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }



                Section("Layout") {
                    Picker("Layout", selection: $layout) {
                        ForEach(QuickNoteLayout.allCases) { option in
                            Label(option.title, systemImage: option.icon)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    QuickNoteLayoutPreview(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        text: $text,
                        format: format,
                        layout: layout,
                        color: repository.appTheme.secondary,
                        onCreateTask: convertItemToTask
                    )
                }

                Section("Folder") {
                    NoteFolderPicker(selection: $folder, folders: repository.noteFolders)
                }
                Section {
                    if !recoveryStatus.isEmpty { Label(recoveryStatus, systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.secondary) }
                    Button(draft.note == nil ? "Discard Draft" : "Remove Recovery Copy", role: .destructive) {
                        isFinalized = true
                        repository.discardNoteDraft(id: draft.id)
                        dismiss()
                    }
                }
                Section("Tags") {
                    TagSelectionEditor(
                        savedTags: repository.savedTags,
                        selectedTags: $selectedTags,
                        colorForTag: repository.color(forTag:),
                        onCreate: repository.saveTag
                    )
                }

                Section("Attach To") {
                    QuickNoteAttachmentPicker(
                        title: "Task",
                        icon: "checklist",
                        selectionTitle: linkedTaskTitle,
                        onClear: { linkedTaskID = nil },
                        content: {
                            ForEach(attachableTasks) { task in
                                Button(task.title) {
                                    linkedTaskID = task.id
                                }
                            }
                        }
                    )

                    NavigationLink {
                        EventLinkPicker(repository: repository, selection: Binding(get: { linkedEventID ?? "" }, set: { linkedEventID = $0.isEmpty ? nil : $0 }))
                    } label: {
                        LabeledContent { Text(linkedEventTitle) } label: { Label("Event", systemImage: "calendar") }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle(draft.note == nil ? "New Quick Note" : "Edit Quick Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        _ = commitPendingURL(showError: false)
                        persistDraft()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(attachmentImports > 0 ? "Importing…" : "Save") {
                        save()
                    }
                    .disabled(isSaveDisabled || attachmentImports > 0)
                }
            }
            .sheet(isPresented: $isDictationPresented) {
                NoteDictationView(autoStart: true, onDraftChange: { pendingTranscript = $0 }) { transcript in
                    text += (text.isEmpty ? "" : "\n\n") + transcript
                    pendingTranscript = ""
                }
            }
            .onChange(of: isDictationPresented) { _, presented in if !presented { pendingTranscript = "" } }
            .task(id: NoteRecoverySaveKey(note: recoveryNote, pendingURL: urlText)) {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await persistDraftAsync()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { persistDraft() } }
            .onDisappear { persistDraft() }
            .sheet(item: $checklistTaskDraft) { TaskEditorView(repository: repository, draft: $0) }
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
            .task {
                if draft.startWithDictation {
                    guard !didHandleInitialDictation else { return }
                    didHandleInitialDictation = true
                    isDictationPresented = true
                } else {
                    isTextFocused = true
                }
            }
        }
    }

    private func convertItemToTask(_ item: NoteChecklist.Item) {
        guard !item.title.isEmpty, repository.saveNoteSnapshot(currentNote) else { return }
        var task = repository.makeDraft()
        task.title = item.title
        task.notes = "From note: " + (title.isEmpty ? "Untitled note" : title) + "\n" + TaskFlowDeepLink.noteURL(currentNote.id).absoluteString
        task.url = TaskFlowDeepLink.noteURL(currentNote.id)
        checklistTaskDraft = task
    }

    private var currentNote: QuickNote {
        var note = draft.seed ?? QuickNote(id: draft.id, text: "")
        note.title = title
        note.text = text
        note.tags = selectedTags
        note.linkedTaskID = linkedTaskID
        note.linkedEventID = linkedEventID
        note.format = format
        note.layout = layout
        note.drawingData = drawingData
        note.attachments = attachments
        note.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return note
    }

    private struct NoteRecoverySaveKey: Equatable {
        let note: QuickNote
        let pendingURL: String
    }

    private var recoveryNote: QuickNote {
        var note = currentNote
        if !pendingTranscript.isEmpty { note.text += (note.text.isEmpty ? "" : "\n\n") + pendingTranscript }
        return note
    }

    private func persistDraftAsync() async {
        guard !isFinalized else { return }
        let note = recoveryNote
        guard !note.title.isEmpty || !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.drawingData != nil || !note.attachments.isEmpty || !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let recovery = NoteEditorRecovery(id: draft.id, originalNoteID: draft.note?.id, note: note, pendingURL: urlText.isEmpty ? nil : urlText)
        let saved = await repository.saveNoteDraftAsync(recovery)
        guard !isFinalized, !Task.isCancelled else { return }
        if saved {
            if draft.note != nil && pendingTranscript.isEmpty { _ = await repository.autosaveNoteSnapshot(note) }
            recoveryStatus = "Draft saved on this device"
        } else { recoveryStatus = "Draft could not be saved" }
    }

    private func persistDraft() {
        guard !isFinalized else { return }
        let note = recoveryNote
        guard !note.title.isEmpty || !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.drawingData != nil || !note.attachments.isEmpty || !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let recovery = NoteEditorRecovery(id: draft.id, originalNoteID: draft.note?.id, note: note, pendingURL: urlText.isEmpty ? nil : urlText)
        if repository.saveNoteDraft(recovery) {
            if draft.note != nil && pendingTranscript.isEmpty { _ = repository.saveNoteSnapshot(currentNote) }
            recoveryStatus = "Draft saved on this device"
        } else { recoveryStatus = "Draft could not be saved" }
    }

    private func save() {
        guard commitPendingURL(showError: true) else { return }
        guard repository.saveNoteSnapshot(currentNote) else { return }
        isFinalized = true
        repository.discardNoteDraft(id: draft.id)
        dismiss()
    }

    private var isSaveDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            drawingData == nil &&
            attachments.isEmpty && urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addURLAttachment() { _ = commitPendingURL(showError: true) }

    @discardableResult
    private func commitPendingURL(showError: Bool) -> Bool {
        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let updated = currentNote.addingURLAttachment(urlText) else {
            if showError { urlError = "Enter a valid website address, such as https://example.com." }
            return false
        }
        attachments = updated.attachments
        urlText = ""
        urlError = nil
        return true
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        attachmentImports += 1
        Task {
            defer { attachmentImports -= 1 }
            do {
                for url in try result.get() {
                    let attachment = try await repository.importFileAttachmentAsync(from: url)
                    attachments.append(attachment)
                }
            } catch { repository.errorMessage = error.localizedDescription }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        attachmentImports += 1
        Task {
            defer { selectedPhotos = []; attachmentImports -= 1 }
            do {
                for (index, item) in items.enumerated() {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let name = item.supportedContentTypes.first?.preferredFilenameExtension.map { "Note-Photo-\(index + 1).\($0)" } ?? "Note-Photo-\(index + 1).jpg"
                    attachments.append(try await repository.importPhotoAttachmentAsync(data: data, suggestedName: name))
                }
            } catch {
                repository.errorMessage = error.localizedDescription
            }
        }
    }

    private var timestampText: String {
        let date = draft.seed?.createdAt ?? Date()
        return "Captured \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var linkedTaskTitle: String {
        guard let linkedTaskID, let task = repository.tasks.first(where: { $0.id == linkedTaskID }) else {
            return "None"
        }
        return task.title
    }

    private var linkedEventTitle: String {
        guard let linkedEventID, let event = repository.calendarEvents.first(where: { $0.id == linkedEventID }) else {
            return "None"
        }
        return event.title
    }

    private var attachableTasks: [TaskItem] {
        let activeTasks = repository.tasks.filter { !$0.isCompleted }
        let candidates = activeTasks.isEmpty ? repository.tasks : activeTasks

        return candidates.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?):
                if left != right { return left < right }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        .prefix(80)
        .map { $0 }
    }

    private var attachableEvents: [CalendarEvent] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let upcoming = repository.calendarEvents
            .filter { $0.endDate >= startOfToday }
            .sorted { $0.startDate < $1.startDate }

        let timedEvents = upcoming.filter { !$0.isAllDay }
        let candidates = timedEvents.isEmpty ? upcoming : timedEvents

        return candidates
            .prefix(60)
            .map { $0 }
    }
}

private struct QuickNoteDrawingCanvas: UIViewRepresentable {
    @Binding var drawingData: Data?
    let undoToken: Int
    let clearToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(drawingData: $drawingData)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .secondarySystemGroupedBackground
        canvasView.drawingPolicy = .anyInput
        canvasView.alwaysBounceVertical = false
        canvasView.alwaysBounceHorizontal = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1

        if let drawingData, let drawing = try? PKDrawing(data: drawingData) {
            canvasView.drawing = drawing
            context.coordinator.renderedData = drawingData
        }

        context.coordinator.canvasView = canvasView
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        if context.coordinator.lastUndoToken != undoToken {
            context.coordinator.lastUndoToken = undoToken
            canvasView.undoManager?.undo()
            context.coordinator.syncDrawing(from: canvasView)
        }

        if context.coordinator.lastClearToken != clearToken {
            context.coordinator.lastClearToken = clearToken
            canvasView.drawing = PKDrawing()
            context.coordinator.renderedData = nil
            drawingData = nil
        }

        if drawingData != context.coordinator.renderedData {
            if let drawingData, let drawing = try? PKDrawing(data: drawingData) {
                canvasView.drawing = drawing
                context.coordinator.renderedData = drawingData
            } else if drawingData == nil {
                canvasView.drawing = PKDrawing()
                context.coordinator.renderedData = nil
            }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawingData: Data?
        weak var canvasView: PKCanvasView?
        var renderedData: Data?
        var lastUndoToken = 0
        var lastClearToken = 0

        init(drawingData: Binding<Data?>) {
            _drawingData = drawingData
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            syncDrawing(from: canvasView)
        }

        func syncDrawing(from canvasView: PKCanvasView) {
            let bounds = canvasView.drawing.bounds
            if bounds.isEmpty {
                drawingData = nil
                renderedData = nil
                return
            }

            let data = canvasView.drawing.dataRepresentation()
            drawingData = data
            renderedData = data
        }
    }
}

private struct QuickNoteDrawingThumbnail: View {
    let drawingData: Data

    var body: some View {
        if let image = thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 120)
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
                }
                .accessibilityLabel("Attached drawing")
        }
    }

    private var thumbnailImage: UIImage? {
        if let cached = NoteDrawingImageCache.images.object(forKey: drawingData as NSData) { return cached }
        guard let drawing = try? PKDrawing(data: drawingData) else { return nil }
        let bounds = drawing.bounds
        guard !bounds.isEmpty else { return nil }
        let insetBounds = bounds.insetBy(dx: -16, dy: -16)
        let key = drawingData as NSData
        if let cached = NoteDrawingImageCache.images.object(forKey: key) { return cached }
        let scale = min(UIScreen.main.scale, 720 / max(insetBounds.width, insetBounds.height))
        guard scale.isFinite, scale > 0 else { return nil }
        let image = drawing.image(from: insetBounds, scale: scale)
        NoteDrawingImageCache.images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }
}

struct QuickNoteFormattingToolbar: View {
    @Binding var format: QuickNoteFormat
    @Binding var text: String
    @Binding var command: NoteFormattingCommand?

    @State private var showingLink = false
    @State private var linkURL = "https://"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            formattingButton("bold", title: "Bold") { inline("**", closing: "**", placeholder: "bold text") }
            formattingButton("italic", title: "Italic") { inline("*", closing: "*", placeholder: "italic text") }
            formattingButton("text.alignleft", title: "Normal Text") { inline("", placeholder: "", wholeLine: true) }
            formattingButton("list.bullet", title: "Bullets") {
                inline("- ", placeholder: "", wholeLine: true)
            }
            formattingButton("checklist", title: "Checklist") {
                inline("- [ ] ", placeholder: "", wholeLine: true)
            }
            formattingButton("quote.opening", title: "Quote") {
                inline("> ", placeholder: "", wholeLine: true)
            }
            formattingButton("textformat.size", title: "Heading") { inline("# ", placeholder: "Heading", wholeLine: true) }
            formattingButton("list.number", title: "Numbered") { inline("1. ", placeholder: "Item", wholeLine: true) }
            formattingButton("link", title: "Link") { showingLink = true }
            Spacer(minLength: 0)
        }
        }
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
        .alert("Insert Link", isPresented: $showingLink) {
            TextField("https://example.com", text: $linkURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Insert") {
                inline("[", closing: "](" + linkURL.trimmingCharacters(in: .whitespacesAndNewlines) + ")", placeholder: "link text")
                linkURL = "https://"
            }.disabled(URL(string: linkURL.trimmingCharacters(in: .whitespacesAndNewlines)).map(ReadingMedia.isWebURL) != true)
            Button("Cancel", role: .cancel) { }
        } message: { Text("Enter a web address. Selected text becomes the link label.") }

    }

    private func inline(_ opening: String, closing: String = "", placeholder: String, wholeLine: Bool = false) {
        format = .markdown
        command = NoteFormattingCommand(opening: opening, closing: closing, placeholder: placeholder, wholeLine: wholeLine)
    }

    private func formattingButton(_ icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

}

private struct QuickNoteLayoutPreview: View {
    let title: String
    @Binding var text: String
    let format: QuickNoteFormat
    let layout: QuickNoteLayout
    let color: Color
    var onCreateTask: ((NoteChecklist.Item) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Preview", systemImage: layout.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            QuickNoteBodyPreview(
                title: title.isEmpty ? "Untitled note" : title,
                text: text,
                format: format,
                layout: layout,
                color: color,
                onChecklistChange: { id, checked in text = NoteChecklist.replacing(text, itemID: id, checked: checked) },
                onCreateTask: onCreateTask
            )
        }
        .padding(.vertical, 4)
    }
}

private struct QuickNoteBodyPreview: View {
    let title: String
    let text: String
    let format: QuickNoteFormat
    let layout: QuickNoteLayout
    let color: Color

    var showsFullContent = false
    var onChecklistChange: ((Int, Bool) -> Void)? = nil
    var onCreateTask: ((NoteChecklist.Item) -> Void)? = nil

    private var lines: [String] {
        text.components(separatedBy: .newlines)
            .map { cleanedLine($0) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .compact ? 4 : 8) {
            Text(title)
                .font(showsFullContent ? .title2.bold() : (layout == .prominent ? .title3.bold() : .headline))
                .foregroundStyle(.primary)
                .lineLimit(showsFullContent ? nil : (layout == .compact ? 1 : 2))

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                formattedBody
            }
        }
        .fixedSize(horizontal: false, vertical: showsFullContent)
        .padding(layout == .compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous)
                .fill(color)
                .frame(width: layout == .prominent ? 6 : 4)
        }
    }

    @ViewBuilder
    private var formattedBody: some View {
        switch format {
        case .plain:
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(showsFullContent ? nil : (layout == .compact ? 2 : 5))
        case .markdown:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(NoteDocument.lines(text, format: format).prefix(showsFullContent ? Int.max : 6))) { line in
                    NoteDocumentLineView(line: line, color: color, onCheck: onChecklistChange, onCreateTask: onCreateTask)
                }
            }
        case .quote:
            Text(text.replacingOccurrences(of: "> ", with: ""))
                .font(.subheadline.italic())
                .foregroundStyle(.secondary)
                .lineLimit(showsFullContent ? nil : (layout == .compact ? 2 : 5))
                .padding(.leading, 8)
        case .checklist:
            NoteChecklistPreview(text: text, color: color, limit: showsFullContent ? nil : (layout == .compact ? 2 : 4), onChange: onChecklistChange, onCreateTask: onCreateTask)
        case .bullets:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.prefix(showsFullContent ? lines.count : (layout == .compact ? 2 : 4)).enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: format == .checklist ? "square" : "circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsFullContent ? nil : 1)
                }
            }
        }
    }

    private var background: Color {
        switch layout {
        case .standard, .compact:
            Color(.secondarySystemGroupedBackground)
        case .prominent:
            color.opacity(0.14)
        }
    }

    private func cleanedLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "- [ ] ", with: "")
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "> ", with: "")
    }
}

private struct QuickNoteAttachmentPicker<Content: View>: View {
    let title: String
    let icon: String
    let selectionTitle: String
    let onClear: () -> Void
    let content: Content

    init(
        title: String,
        icon: String,
        selectionTitle: String,
        onClear: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.selectionTitle = selectionTitle
        self.onClear = onClear
        self.content = content()
    }

    var body: some View {
        Menu {
            Button("None", action: onClear)
            content
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(selectionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct QuickNoteAttachmentList: View {
    @Bindable var repository: TaskRepository
    let attachments: [TaskAttachment]
    let onRemove: (TaskAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(attachments) { attachment in
                NoteAttachmentCard(attachment: attachment, url: repository.attachmentURL(for: attachment), contentRevision: repository.attachmentContentRevision, onRetry: { Task { await repository.synchronizeCloud() } }, onRemove: { onRemove(attachment) })
            }
        }
    }
}

private extension TaskAttachment {
    var tint: Color {
        switch kind {
        case .url: .blue
        case .file: .indigo
        case .photo: .pink
        }
    }

    var detailText: String {
        switch kind {
        case .url:
            return URL(string: urlString ?? "")?.host ?? "Web link"
        case .file, .photo:
            let ext = URL(fileURLWithPath: localPath ?? title).pathExtension
            if !ext.isEmpty { return ext.uppercased() }
            return kind == .photo ? "Photo" : "File"
        }
    }
}

private struct QuickNoteRow: View {
    let note: QuickNote
    let color: Color
    let colorForTag: (String) -> Color
    let linkedTask: TaskItem?
    let linkedEvent: CalendarEvent?
    let attachmentURL: (TaskAttachment) -> URL?
    let onSelect: () -> Void
    var onChecklistChange: ((Int, Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if note.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange).accessibilityLabel("Pinned") }
                        Text(displayTitle)
                    }
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.createdAt.formatted(date: .numeric, time: .omitted))
                            .foregroundStyle(.primary)
                        if note.format != .checklist {
                            Text(previewText)
                                .foregroundStyle(.secondary)
                                .lineLimit(note.layout == .compact ? 1 : 2)
                        }
                    }
                    .font(.subheadline)
                    if let drawingData = note.drawingData {
                        QuickNoteDrawingThumbnail(drawingData: drawingData)
                    }
                    if let attachmentText {
                        Label(attachmentText.title, systemImage: attachmentText.icon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !note.tags.isEmpty {
                        Text(note.tags.map { "#" + $0 }.joined(separator: " "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if note.format == .checklist {
                NoteChecklistPreview(text: note.text, color: color, limit: note.layout == .compact ? 2 : 4, onChange: onChecklistChange)
            }
        }
    }


    private var previewText: String {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? "No additional text" : text
    }

    private var displayTitle: String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        if note.format == .checklist { return NoteChecklist.items(in: note.text).first.map { $0.title.isEmpty ? "Untitled note" : $0.title } ?? "Untitled note" }
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Untitled note" : text
    }

    private var titleFont: Font {
        switch note.layout {
        case .standard, .compact:
            .headline
        case .prominent:
            .title3.bold()
        }
    }

    private var rowPadding: EdgeInsets {
        switch note.layout {
        case .compact:
            EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        case .standard:
            EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        case .prominent:
            EdgeInsets(top: 16, leading: 14, bottom: 16, trailing: 14)
        }
    }

    private var rowBackground: Color {
        switch note.layout {
        case .standard, .compact:
            Color(.secondarySystemGroupedBackground)
        case .prominent:
            color.opacity(0.14)
        }
    }

    private var attachmentText: (title: String, icon: String)? {
        if let linkedTask {
            return (linkedTask.title, "checklist")
        }
        if let linkedEvent {
            return (linkedEvent.title, linkedEvent.isAllDay ? "calendar" : "calendar.badge.clock")
        }
        return nil
    }
}

private struct TaskNoteOverviewRow: View {
    let item: TaskCommentItem
    let listColor: Color
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.comment.text)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(listColor)
                    Text(item.task.title).lineLimit(1)
                    Text("·")
                    Text(item.comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AllTaskCommentsView: View {
    @Bindable var repository: TaskRepository
    @State private var search = ""
    @State private var status = "All"

    private func comments(for task: TaskItem) -> [TaskComment] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return task.comments.filter { comment in
            (status == "All" || (status == "Resolved" ? comment.isResolved : !comment.isResolved)) &&
            (query.isEmpty || task.title.localizedCaseInsensitiveContains(query) || comment.text.localizedCaseInsensitiveContains(query))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var groupedTasks: [TaskItem] {
        repository.tasks.filter { !comments(for: $0).isEmpty }.sorted {
            let lhs = comments(for: $0).first?.createdAt ?? .distantPast
            let rhs = comments(for: $1).first?.createdAt ?? .distantPast
            return lhs == rhs ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : lhs > rhs
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Comment status", selection: $status) {
                    Text("All").tag("All")
                    Text("Open").tag("Open")
                    Text("Resolved").tag("Resolved")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if groupedTasks.isEmpty {
                ContentUnavailableView(
                    search.isEmpty && status == "All" ? "No Comments Yet" : "No Matching Comments",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Comments added to tasks appear here, grouped by task.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(groupedTasks) { task in
                Section {
                    Button {
                        repository.selectTask(task)
                    } label: {
                        HStack {
                            Text(task.title).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.bold())
                        }
                    }
                    .accessibilityLabel("Open task: \(task.title)")
                    ForEach(comments(for: task)) { comment in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(comment.text).textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                if comment.editedAt != nil { Text("· Edited") }
                                Spacer()
                                if comment.isResolved {
                                    Label("Resolved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(comment.isResolved ? "Reopen" : "Resolve", systemImage: comment.isResolved ? "arrow.uturn.backward" : "checkmark.circle") {
                                Task { await repository.toggleComment(comment, on: task) }
                            }
                            .tint(.green)
                        }
                        .contextMenu {
                            Button("Open Task", systemImage: "arrow.up.right") { repository.selectTask(task) }
                            ShareLink(item: comment.text) { Label("Share Comment", systemImage: "square.and.arrow.up") }
                        }
                    }
                } header: {
                    HStack {
                        Text(repository.lists.first { $0.id == task.listID }?.title ?? "Task")
                        Spacer()
                        Text("\(comments(for: task).count) comments")
                    }
                }
                .listRowBackground(TaskFlowTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .taskFlowThemedBackground()
        .navigationTitle("All Comments")
        .searchable(text: $search, prompt: "Search comments or tasks")
        .scrollContentBackground(.hidden)
        .background(TaskFlowBackground(accent: repository.appTheme.primary))
    }
}


struct NativeNoteDetailView: View {
    @Bindable var repository: TaskRepository
    let noteID: UUID
    @State private var hideCompleted = false
    @State private var completedLast = false
    @State private var collapsedSections: Set<Int> = []
    @State private var findText = ""
    @State private var matchIndex = 0
    @State private var checklistTaskDraft: TaskDraft?
    @State private var showsHistory = false
    @State private var editor: QuickNoteEditorDraft?
    @State private var noteToMove: QuickNote?

    private func activeMatch(_ note: QuickNote) -> NoteSearchMatch? {
        let matches = NoteSearch.matches(note: note, query: findText)
        return matches.isEmpty ? nil : matches[min(matchIndex, matches.count - 1)]
    }

    var body: some View {
        Group {
            if let note = repository.quickNotes.first(where: { $0.id == noteID }) {
                ScrollViewReader { proxy in
                List {
                    Section {
                        TextField("Find in Note", text: $findText)
                        if !findText.isEmpty {
                            let matches = NoteSearch.matches(note: note, query: findText)
                            HStack {
                                Text(matches.isEmpty ? "No matches" : "\(min(matchIndex + 1, matches.count)) of \(matches.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Previous Match", systemImage: "chevron.up") { matchIndex = (matchIndex - 1 + matches.count) % max(1, matches.count) }.labelStyle(.iconOnly).disabled(matches.isEmpty)
                                Button("Next Match", systemImage: "chevron.down") { matchIndex = (matchIndex + 1) % max(1, matches.count) }.labelStyle(.iconOnly).disabled(matches.isEmpty)
                            }.buttonStyle(.borderless)
                        }
                    }
                    Section {
                        if let drawing = note.drawingData { QuickNoteDrawingThumbnail(drawingData: drawing) }
                        Text(highlightedNoteText(note.title, query: findText, activeOrdinal: activeMatch(note)?.lineID == -1 ? activeMatch(note)?.ordinalWithinLine : nil)).font(.title2.bold()).id(-1)
                        ForEach(NoteDocument.presentedLines(note.text, format: note.format, hideCompleted: findText.isEmpty && hideCompleted, completedLast: findText.isEmpty && completedLast, collapsed: findText.isEmpty ? collapsedSections : [])) { line in
                            NoteDocumentLineView(line: line, color: repository.appTheme.primary, onCheck: { id, checked in repository.setNoteChecklistItem(noteID: note.id, itemID: id, checked: checked) }, onCreateTask: { item in
                                var draft = repository.makeDraft()
                                draft.title = item.title
                                draft.notes = "From note: " + note.title + "\n" + TaskFlowDeepLink.noteURL(note.id).absoluteString
                                draft.url = TaskFlowDeepLink.noteURL(note.id)
                                checklistTaskDraft = draft
                            }, onToggleSection: {
                                if collapsedSections.contains(line.id) { collapsedSections.remove(line.id) } else { collapsedSections.insert(line.id) }
                            }, isCollapsed: collapsedSections.contains(line.id), search: findText, activeOrdinal: activeMatch(note)?.lineID == line.id ? activeMatch(note)?.ordinalWithinLine : nil)
                            .id(line.id)
                        }
                        Text(note.createdAt, format: .dateTime.month().day().year()).font(.caption).foregroundStyle(.secondary)
                    }
                    if !note.tags.isEmpty {
                        Section("Tags") { Text(note.tags.map { "#" + $0 }.joined(separator: "  ")) }
                    }
                    if !note.attachments.isEmpty {
                        Section("Attachments") {
                            ForEach(note.attachments) { attachment in
                                NoteAttachmentCard(attachment: attachment, url: repository.attachmentURL(for: attachment), contentRevision: repository.attachmentContentRevision, onRetry: { Task { await repository.synchronizeCloud() } })
                            }
                        }
                    }
                }
                .onChange(of: findText) { _, _ in
                    matchIndex = 0
                    if let match = activeMatch(note) { proxy.scrollTo(match.lineID, anchor: .center) }
                }
                .onChange(of: matchIndex) { _, _ in
                    if let match = activeMatch(note) { withAnimation { proxy.scrollTo(match.lineID, anchor: .center) } }
                }
                }
                .textSelection(.enabled)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: [note.title, note.text].filter { !$0.isEmpty }.joined(separator: "\n\n")) {
                            Label("Share Note", systemImage: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(note.isPinned ? "Unpin Note" : "Pin Note", systemImage: note.isPinned ? "pin.slash" : "pin") { repository.toggleNotePin(note) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Checklist Options", systemImage: "line.3.horizontal.decrease.circle") {
                            Toggle("Hide Completed", isOn: $hideCompleted)
                            Toggle("Completed at Bottom", isOn: $completedLast)
                            Button("Expand All Sections") { collapsedSections = [] }
                            Button("Collapse All Sections") { collapsedSections = Set(NoteDocument.lines(note.text, format: note.format).filter { $0.headingLevel > 0 }.map(\.id)) }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Version History", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                            .disabled(note.versions.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Move to Folder", systemImage: "folder") { noteToMove = note }
                    }
                    ToolbarItem(placement: .primaryAction) { Button("Edit") { editor = QuickNoteEditorDraft(note: note) } }
                }
            } else {
                ContentUnavailableView("Note Unavailable", systemImage: "note.text", description: Text("This note may have been deleted."))
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $checklistTaskDraft) { TaskEditorView(repository: repository, draft: $0) }
        .sheet(isPresented: $showsHistory) { NoteVersionHistoryView(repository: repository, noteID: noteID) }
        .sheet(item: $noteToMove) { note in NoteMoveFolderView(repository: repository, note: note) }
        .noteEditorPresentation(repository: repository, draft: $editor)
    }
}

struct UnifiedSearchView: View {
    @Bindable var repository: TaskRepository
    @Binding var selectedCalendarEvent: CalendarEvent?
    @State private var query = ""
    @State private var searchEvent: CalendarEvent?
    @State private var scope = SearchCategory.all
    @State private var taskDraft: TaskDraft?
    @State private var smartDraft: SmartListDefinition?
    @AppStorage("TaskFlow.recentSearches") private var recentData = Data()
    @AppStorage("TaskFlow.savedSearches") private var savedData = Data()
    private var saved: [String] { (try? JSONDecoder().decode([String].self, from: savedData)) ?? [] }
    private func setSaved(_ values: [String]) { savedData = (try? JSONEncoder().encode(values)) ?? Data() }
    private var isSaved: Bool { saved.contains { $0.localizedCaseInsensitiveCompare(term) == .orderedSame } }
    private enum SearchCategory: String, CaseIterable { case all = "All", tasks = "Tasks", events = "Events", notes = "Notes", comments = "Comments" }
    private var recents: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ text: String) -> Bool { !term.isEmpty && text.localizedCaseInsensitiveContains(term) }
    private func remember() {
        guard !term.isEmpty else { return }
        recentData = (try? JSONEncoder().encode(Array(([term] + recents.filter { $0 != term }).prefix(8)))) ?? Data()
    }
    var body: some View {
        let listTitles = Dictionary(repository.lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let matchingTasks = (scope == .all || scope == .tasks) ? repository.tasks.filter { task in
            // List-type fields too: store, provider, creator, destination, contact, and so on.
            matches(([task.title, task.notes, task.tags.joined(separator: " "), listTitles[task.listID] ?? ""] + Array(repository.specializedDetails(task).fields.values)).joined(separator: " "))
        } : []
        let calendarTitles = Dictionary(repository.eventCalendars.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let matchingEvents = (scope == .all || scope == .events) ? repository.calendarEvents.filter {
            matches([$0.title, $0.location ?? "", $0.notes ?? "", calendarTitles[$0.calendarID] ?? "", $0.tags.joined(separator: " ")].joined(separator: " "))
        } : []
        let matchingNotes = (scope == .all || scope == .notes) ? repository.quickNotes.filter { matches([$0.title, $0.text, $0.tags.joined(separator: " ")].joined(separator: " ")) } : []
        let matchingComments = (scope == .all || scope == .comments) ? repository.tasks.filter { $0.comments.contains { matches($0.text) } } : []
        let matchingLists = scope == .all ? repository.lists.filter { matches($0.title) } : []
        let matchingTags = scope == .all ? repository.allTags.filter { matches($0) } : []
        let hasResults = !matchingTasks.isEmpty || !matchingEvents.isEmpty || !matchingNotes.isEmpty || !matchingComments.isEmpty || !matchingLists.isEmpty || !matchingTags.isEmpty
        return List {
            if term.isEmpty {
                if !saved.isEmpty {
                    Section("Saved Searches") {
                        ForEach(saved, id: \.self) { text in Button(text, systemImage: "star.fill") { query = text } }
                            .onDelete { offsets in var values = saved; values.remove(atOffsets: offsets); setSaved(values) }
                    }
                }
                if !recents.isEmpty {
                    Section("Recent Searches") {
                        ForEach(recents, id: \.self) { text in Button(text, systemImage: "clock") { query = text } }
                        Button("Clear Recent Searches", role: .destructive) { recentData = Data() }
                    }
                } else if saved.isEmpty {
                    ContentUnavailableView("Search TaskFlow", systemImage: "magnifyingglass", description: Text("Find tasks, events, notes, comments, lists, tags, and list details like stores or providers."))
                }
            } else if !hasResults {
                ContentUnavailableView.search(text: term)
                if scope != .all { Button("Search All Categories") { scope = .all } }
            } else {
                if scope == .all || scope == .tasks {
                    Section("Tasks") {
                        ForEach(matchingTasks) { task in
                            Button { remember(); repository.selectedTaskID = task.id } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(task.title).foregroundStyle(.primary)
                                    Label(listTitles[task.listID] ?? "Tasks", systemImage: repository.listIcon(for: task.listID)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if scope == .all || scope == .events {
                    Section("Events") {
                        ForEach(matchingEvents, id: \.occurrenceKey) { event in
                            Button { remember(); searchEvent = event } label: {
                                VStack(alignment: .leading) { Text(event.title).foregroundStyle(.primary); Text(event.startDate, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if scope == .all || scope == .notes {
                    Section("Notes") {
                        ForEach(matchingNotes) { note in
                            NavigationLink { NativeNoteDetailView(repository: repository, noteID: note.id).onAppear { remember() } } label: {
                                Label(note.title.isEmpty ? String(note.text.prefix(80)) : note.title, systemImage: "note.text").lineLimit(2)
                            }
                        }
                    }
                }
                if scope == .all || scope == .comments {
                    Section("Comments") {
                        ForEach(matchingComments) { task in
                            NavigationLink { TaskCommentsScreen(repository: repository, taskID: task.id).onAppear { remember() } } label: {
                                VStack(alignment: .leading) { Text(task.title); Text(task.comments.first { matches($0.text) }?.text ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                    }
                }
                if scope == .all {
                    Section("Lists and Tags") {
                        ForEach(matchingLists) { list in
                            NavigationLink {
                                TaskCollectionView(repository: repository, editorDraft: $taskDraft, smartListDraft: $smartDraft, selectedCalendarEvent: $selectedCalendarEvent, viewModeOverride: .list, titleOverride: list.title)
                                    .onAppear { remember(); repository.selectedScope = .list(list.id) }
                            } label: { Label(list.title, systemImage: repository.listIcon(for: list.id)) }
                        }
                        ForEach(matchingTags, id: \.self) { tag in
                            Button("#" + tag, systemImage: "tag") { query = tag; scope = .tasks }
                        }
                    }
                }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Tasks, events, notes, and comments")
        .searchScopes($scope) { ForEach(SearchCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        .onSubmit(of: .search) { remember() }
        .fullScreenCover(item: $searchEvent) { event in
            CalendarEventDetailView(repository: repository, event: event, color: repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue)
        }
        .sheet(item: $taskDraft) { TaskEditorView(repository: repository, draft: $0) }
        .sheet(item: $smartDraft) { SmartListEditorView(repository: repository, smartList: $0) }
        .toolbar {
            if !term.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaved ? "Remove Saved Search" : "Save Search", systemImage: isSaved ? "star.fill" : "star") {
                        if isSaved { setSaved(saved.filter { $0.localizedCaseInsensitiveCompare(term) != .orderedSame }) }
                        else { setSaved(Array(([term] + saved).prefix(20))) }
                    }
                }
            }
            if scope != .all { ToolbarItem(placement: .topBarTrailing) { Button("Clear Filter") { scope = .all } } }
        }
    }
}

@MainActor
private final class NoteDictationRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isFinishing = false
    @Published var errorMessage: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false
    private var sessionID = UUID()
    private var finishTask: Task<Void, Never>?

    func start() async {
        guard !isStarting, !isRecording, !isFinishing else { return }
        isStarting = true
        errorMessage = nil
        let id = UUID()
        sessionID = id
        defer { isStarting = false }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == id else { return }
        guard speechStatus == .authorized else {
            errorMessage = "Allow Speech Recognition for TaskFlow in Settings to transcribe notes."
            return
        }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard sessionID == id else { return }
        guard microphoneAllowed else {
            errorMessage = "Allow Microphone access for TaskFlow in Settings to dictate notes."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable. Please try again later."
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "NoteDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            transcript = ""
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil {
                        if let error, self.isRecording { self.errorMessage = error.localizedDescription }
                        self.cancel()
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            cancel()
        }
    }

    func stop() {
        guard isRecording else { return }
        stopAudio()
        isFinishing = true
        request?.endAudio()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        sessionID = UUID()
        finishTask?.cancel()
        finishTask = nil
        stopAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isFinishing = false
    }

    private func stopAudio() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct NoteDictationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = NoteDictationRecorder()
    var autoStart = false
    var onDraftChange: ((String) -> Void)? = nil
    @State private var didAutoStart = false
    let onInsert: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(recorder.isRecording ? "Listening…" : (recorder.isFinishing ? "Finishing transcription…" : "Ready to dictate"), systemImage: recorder.isRecording ? "waveform" : "mic")
                    Button(recorder.isRecording ? "Stop Dictation" : "Start Dictation", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill") {
                        if recorder.isRecording { recorder.stop() }
                        else { Task { await recorder.start() } }
                    }
                    .disabled(recorder.isStarting || recorder.isFinishing)
                    if let error = recorder.errorMessage { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Speak to transcribe, then review and insert the text into your note. Starting again replaces this transcript. Speech recognition may use Apple's servers.")
                }
                Section("Transcript") {
                    TextEditor(text: $recorder.transcript)
                        .frame(minHeight: 220)
                        .disabled(recorder.isRecording || recorder.isFinishing)
                }
            }
            .navigationTitle("Dictate Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        onInsert(recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
                        recorder.cancel()
                        dismiss()
                    }
                    .disabled(recorder.isStarting || recorder.isRecording || recorder.isFinishing || recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onChange(of: recorder.transcript) { _, value in onDraftChange?(value) }
        .task { await startAutomaticallyIfNeeded() }
        .onDisappear { recorder.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { recorder.cancel() }
            if phase == .active { Task { await startAutomaticallyIfNeeded() } }
        }
    }

    private func startAutomaticallyIfNeeded() async {
        // Control Center and permission dialogs can briefly leave the app inactive.
        guard autoStart, !didAutoStart, scenePhase == .active else { return }
        didAutoStart = true
        await recorder.start()
    }
}

private struct NoteChecklistPreview: View {
    let text: String
    let color: Color
    var limit: Int? = nil
    var onChange: ((Int, Bool) -> Void)?
    var onCreateTask: ((NoteChecklist.Item) -> Void)? = nil
    @State private var hideCompleted = false
    @State private var completedLast = false
    @State private var collapsed: Set<String> = []
    private var visibleItems: [NoteChecklist.Item] {
        let filtered = items.filter { (!hideCompleted || !$0.isChecked) && !collapsed.contains($0.section) }
        return completedLast ? filtered.filter { !$0.isChecked } + filtered.filter(\.isChecked) : filtered
    }
    private var items: [NoteChecklist.Item] { NoteChecklist.items(in: text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !items.isEmpty {
                Text("\(items.filter(\.isChecked).count) of \(items.count) completed")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu("Checklist Options", systemImage: "line.3.horizontal.decrease.circle") {
                        Toggle("Hide Completed", isOn: $hideCompleted)
                        Toggle("Completed at Bottom", isOn: $completedLast)
                    }.font(.caption)
                    Spacer()
                }
                ForEach(Array(Set(items.map(\.section))).sorted().filter { !$0.isEmpty }, id: \.self) { section in
                    Button {
                        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
                    } label: { Label(section, systemImage: collapsed.contains(section) ? "chevron.right" : "chevron.down").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.borderless)
                }
                ForEach(Array(visibleItems.prefix(limit ?? visibleItems.count))) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Button { onChange?(item.id, !item.isChecked) } label: {
                            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(item.isChecked ? color : .secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(onChange == nil)
                        .accessibilityLabel(item.isChecked ? "Uncheck \(item.title)" : "Check \(item.title)")
                        .accessibilityValue(item.isChecked ? "Completed" : "Incomplete")
                        Text(item.title.isEmpty ? "Untitled item" : item.title)
                            .font(.body).foregroundStyle(item.isChecked ? .secondary : .primary)
                            .strikethrough(item.isChecked)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let onCreateTask {
                            Button { onCreateTask(item) } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 32, height: 44) }
                                .buttonStyle(.plain).accessibilityLabel("Turn \(item.title) into task")
                                .disabled(item.title.isEmpty)
                        }
                    }
                    .padding(.leading, CGFloat(min(item.depth, 6)) * 12)
                }
                if let limit, visibleItems.count > limit {
                    Text("+\(visibleItems.count - limit) more items").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NoteChecklistEditor: View {
    @Binding var text: String
    let color: Color
    var onCreateTask: ((NoteChecklist.Item) -> Void)? = nil
    @State private var sectionTitle = ""
    @State private var hideCompleted = false
    @State private var completedLast = false
    @State private var collapsed: Set<String> = []
    private var items: [NoteChecklist.Item] { NoteChecklist.items(in: text) }
    private var visibleItems: [NoteChecklist.Item] {
        let filtered = items.filter { (!hideCompleted || !$0.isChecked) && !collapsed.contains($0.section) }
        return completedLast ? filtered.filter { !$0.isChecked } + filtered.filter(\.isChecked) : filtered
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(items.filter(\.isChecked).count) of \(items.count) completed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("Hide Completed", isOn: $hideCompleted)
                    Toggle("Completed at Bottom", isOn: $completedLast)
                    Button("Check All", systemImage: "checkmark.circle") { text = NoteChecklist.setAll(text, checked: true) }
                    Button("Uncheck All", systemImage: "circle") { text = NoteChecklist.setAll(text, checked: false) }
                    Button("Remove Checked Items", systemImage: "trash") {
                        text = NoteChecklist.removing(text, itemIDs: Set(items.filter(\.isChecked).map(\.id)))
                    }
                } label: { Label("Checklist Options", systemImage: "ellipsis.circle") }
                .labelStyle(.iconOnly).disabled(items.isEmpty)
            }
            ForEach(Array(Set(items.map(\.section))).sorted().filter { !$0.isEmpty }, id: \.self) { section in
                Button {
                    if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
                } label: { Label(section, systemImage: collapsed.contains(section) ? "chevron.right" : "chevron.down") }
                .buttonStyle(.borderless)
            }
            ForEach(visibleItems) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        text = NoteChecklist.replacing(text, itemID: item.id, checked: !item.isChecked)
                    } label: {
                        Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(item.isChecked ? color : .secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isChecked ? "Uncheck \(item.title)" : "Check \(item.title)")
                    .accessibilityValue(item.isChecked ? "Completed" : "Incomplete")
                    TextField("Checklist item", text: Binding(
                        get: { NoteChecklist.items(in: text).first { $0.id == item.id }?.title ?? "" },
                        set: { text = NoteChecklist.replacing(text, itemID: item.id, title: $0) }
                    ), axis: .vertical)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                    .padding(.top, 10)
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        .frame(width: 28, height: 44).draggable("note-checklist-\(item.id)")
                        .accessibilityLabel("Drag to reorder \(item.title)")
                    Menu {
                        if let onCreateTask { Button("Turn Into Task", systemImage: "checklist") { onCreateTask(item) }.disabled(item.title.isEmpty) }
                        Button("Indent Item", systemImage: "increase.indent") { indent(item.id, outdent: false) }
                        Button("Outdent Item", systemImage: "decrease.indent") { indent(item.id, outdent: true) }.disabled(item.depth == 0)
                        Button("Move Up", systemImage: "arrow.up") { move(item.id, direction: -1) }
                            .disabled(items.first?.id == item.id)
                        Button("Move Down", systemImage: "arrow.down") { move(item.id, direction: 1) }
                            .disabled(items.last?.id == item.id)
                        Button("Delete Item", systemImage: "trash", role: .destructive) {
                            text = NoteChecklist.removing(text, itemIDs: [item.id])
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                    .accessibilityLabel("Options for \(item.title)")
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * 12)
                .dropDestination(for: String.self) { values, _ in
                    guard let value = values.first, value.hasPrefix("note-checklist-"), let id = Int(value.dropFirst("note-checklist-".count)) else { return false }
                    text = NoteChecklist.moving(text, itemID: id, before: item.id)
                    return true
                }
            }
            HStack {
                TextField("New section name", text: $sectionTitle)
                Button("Add Section", systemImage: "text.badge.plus") {
                    let name = sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    text += (text.isEmpty ? "" : "\n") + "# " + name.replacingOccurrences(of: "\n", with: " ") + "\n- [ ] "
                    sectionTitle = ""
                }.buttonStyle(.borderless).disabled(sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Add Item", systemImage: "plus.circle") {
                text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "- [ ] "
            }
            .buttonStyle(.borderless)
        }
    }

    private func indent(_ id: Int, outdent: Bool) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(id) else { return }
        if outdent { lines[id] = String(lines[id].dropFirst(min(2, lines[id].prefix { $0 == " " }.count))) }
        else { lines[id] = "  " + lines[id] }
        text = lines.joined(separator: "\n")
    }

    private func move(_ id: Int, direction: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + direction) else { return }
        var lines = text.components(separatedBy: "\n")
        lines.swapAt(id, items[index + direction].id)
        text = lines.joined(separator: "\n")
    }
}


private struct NoteVersionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let noteID: UUID
    var body: some View {
        NavigationStack {
            List {
                if let note = repository.quickNotes.first(where: { $0.id == noteID }) {
                    ForEach(note.versions.reversed()) { version in
                        NavigationLink {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    QuickNoteBodyPreview(title: version.snapshot.title, text: version.snapshot.text, format: version.snapshot.format, layout: version.snapshot.layout, color: repository.appTheme.primary, showsFullContent: true)
                                    Button("Restore This Version") {
                                        repository.restoreNoteVersion(noteID: noteID, revision: version)
                                        dismiss()
                                    }.buttonStyle(.borderedProminent)
                                }.padding()
                            }.navigationTitle("Previous Version")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(version.savedAt, format: .dateTime.month().day().hour().minute().second())
                                Text(version.snapshot.text).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Version History")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}


private func highlightedNoteText(_ text: String, query: String, activeOrdinal: Int? = nil) -> AttributedString {
    var result = AttributedString()
    var start = text.startIndex
    for (index, range) in NoteSearch.ranges(in: text, query: query).enumerated() {
        result += AttributedString(String(text[start..<range.lowerBound]))
        var match = AttributedString(String(text[range]))
        match.backgroundColor = index == activeOrdinal ? .orange.opacity(0.6) : .yellow.opacity(0.6)
        match.foregroundColor = .black
        result += match
        start = range.upperBound
    }
    result += AttributedString(String(text[start...]))
    return result
}

private struct NoteDocumentLineView: View {
    let line: NoteDocumentLine
    let color: Color
    var onCheck: ((Int, Bool) -> Void)? = nil
    var onCreateTask: ((NoteChecklist.Item) -> Void)? = nil
    var onToggleSection: (() -> Void)? = nil
    var isCollapsed = false
    var search = ""
    var activeOrdinal: Int? = nil
    private var styledText: AttributedString {
        if !search.isEmpty { return NoteTextFormatting.addingDetectedLinks(to: highlightedNoteText(line.displayText, query: search, activeOrdinal: activeOrdinal)) }
        let content = line.checkbox?.title ?? (line.headingLevel > 0 ? String(line.source.trimmingCharacters(in: .whitespaces).dropFirst(line.headingLevel + 1)) : line.source)
        return NoteTextFormatting.inline(content)
    }
    var body: some View {
        if let item = line.checkbox {
            HStack(alignment: .top, spacing: 8) {
                Button { onCheck?(line.id, !item.isChecked) } label: {
                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(item.isChecked ? color : .secondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain).disabled(onCheck == nil)
                    .accessibilityLabel(item.isChecked ? "Uncheck \(item.title)" : "Check \(item.title)")
                Text(styledText).strikethrough(item.isChecked).foregroundStyle(item.isChecked ? .secondary : .primary).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                if let onCreateTask {
                    Button { onCreateTask(item) } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 32, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("Turn \(item.title) into task").disabled(item.title.isEmpty)
                }
            }.padding(.leading, CGFloat(min(item.depth, 6)) * 12)
        } else if line.headingLevel > 0 {
            if let onToggleSection {
                Button(action: onToggleSection) {
                    HStack { Text(styledText).font(line.headingLevel == 1 ? .title2.bold() : .headline); Spacer(); Image(systemName: isCollapsed ? "chevron.right" : "chevron.down") }
                }.buttonStyle(.plain).padding(.vertical, 4)
            } else { Text(styledText).font(line.headingLevel == 1 ? .title2.bold() : .headline).padding(.vertical, 4) }
        } else if line.source.hasPrefix("- ") || line.source.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text(NoteTextFormatting.inline(String(line.source.dropFirst(2))))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if line.source.hasPrefix("> ") {
            Text(NoteTextFormatting.inline(String(line.source.dropFirst(2))))
                .italic().padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        } else {
            Text(styledText).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private final class NotesListCache {
    private var noteKey: [String] = []
    private var taskKey: [String] = []
    private var noteResult: [QuickNote] = []
    private var taskResult: [TaskCommentItem] = []
    func notes(key: [String], calculate: () -> [QuickNote]) -> [QuickNote] {
        if noteKey != key { noteResult = calculate(); noteKey = key }
        return noteResult
    }
    func taskNotes(key: [String], calculate: () -> [TaskCommentItem]) -> [TaskCommentItem] {
        if taskKey != key { taskResult = calculate(); taskKey = key }
        return taskResult
    }
}

@MainActor
private enum NoteDrawingImageCache {
    static let images: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 24; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
}

/// Shared preview cards keep web links actionable even without fetched metadata,
/// and use Quick Look for full-resolution local documents and photos.
private struct NoteAttachmentCard: View {
    let attachment: TaskAttachment
    let url: URL?
    var contentRevision = 0
    var onRetry: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var fetchedTitle: String?
    @State private var loading = false
    @State private var document: AttachmentPreviewDocument?
    @State private var webPage: AttachmentPreviewDocument?

    private struct LoadKey: Equatable {
        let attachment: TaskAttachment
        let url: URL?
        let revision: Int
    }
    private var available: Bool {
        guard let url else { return false }
        return attachment.kind == .url || FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let url, available else { return }
                if attachment.kind == .url { webPage = AttachmentPreviewDocument(url: url) }
                else { document = AttachmentPreviewDocument(url: url) }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius).fill(attachment.tint.opacity(0.12))
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else if loading {
                            ProgressView()
                        } else {
                            Image(systemName: attachment.icon).font(.title2).foregroundStyle(attachment.tint)
                        }
                    }
                    .frame(width: 88, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fetchedTitle ?? attachment.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(3)
                        if attachment.kind == .url, let url {
                            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else {
                            Text(attachment.detailText + (available ? " · Tap to preview" : " · Not downloaded"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: attachment.kind == .url ? "arrow.up.forward" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .accessibilityLabel("Preview \(fetchedTitle ?? attachment.title)")
            .contextMenu {
                if let url, available {
                    ShareLink(item: url)
                    if attachment.kind == .url {
                        Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                    }
                }
            }
            if attachment.kind != .url && !available {
                HStack {
                    Text("This attachment is not on this device yet.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let onRetry { Button("Retry Sync", action: onRetry).font(.caption.weight(.semibold)).buttonStyle(.borderless) }
                }
            }
            if let onRemove {
                Button("Remove Attachment", systemImage: "trash", role: .destructive, action: onRemove)
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius))
        .task(id: LoadKey(attachment: attachment, url: url, revision: contentRevision)) {
            image = nil; fetchedTitle = nil
            guard let url, available else { return }
            loading = true
            defer { loading = false }
            let result = await NoteAttachmentPreviewCache.preview(url: url, isWeb: attachment.kind == .url)
            guard !Task.isCancelled else { return }
            fetchedTitle = result?.title
            image = result?.image
        }
        .sheet(item: $document) { item in
            NavigationStack {
                AttachmentQuickLookPreview(url: item.url)
                    .navigationTitle(attachment.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { document = nil } } }
            }
        }
        .sheet(item: $webPage) { item in NoteAttachmentBrowser(url: item.url) }
    }
}

private struct NoteAttachmentBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
private enum NoteAttachmentPreviewCache {
    /// Immutable once created, so it can cross from the loading task to the cache safely.
    final class Preview: NSObject, @unchecked Sendable {
        let title: String?
        let image: UIImage?
        init(title: String?, image: UIImage?) { self.title = title; self.image = image }
    }
    private static let cache: NSCache<NSURL, Preview> = {
        let value = NSCache<NSURL, Preview>()
        value.countLimit = 48
        value.totalCostLimit = 12 * 1024 * 1024
        return value
    }()
    private static var requests: [URL: Task<Preview?, Never>] = [:]
    private static var activeRequests = 0
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private static func acquire() async {
        if activeRequests < 4 { activeRequests += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private static func release() {
        if waiting.isEmpty { activeRequests -= 1 }
        else { waiting.removeFirst().resume() }
    }

    static func preview(url: URL, isWeb: Bool) async -> Preview? {
        if let value = cache.object(forKey: url as NSURL) { return value }
        if let pending = requests[url] { return await pending.value }
        let work = Task { @MainActor in
            await acquire()
            defer { release() }
            let result: Preview?
            if isWeb { result = await webPreview(url) }
            else { result = await filePreview(url) }
            if let result {
                let cost = result.image.map { Int($0.size.width * $0.size.height * $0.scale * $0.scale * 4) } ?? 512
                cache.setObject(result, forKey: url as NSURL, cost: cost)
            }
            return result
        }
        requests[url] = work
        let result = await work.value
        requests[url] = nil
        return result
    }

    private static func webPreview(_ url: URL) async -> Preview? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            var image: UIImage?
            if let item = metadata.imageProvider ?? metadata.iconProvider, item.canLoadObject(ofClass: UIImage.self) {
                image = await withCheckedContinuation { continuation in
                    item.loadObject(ofClass: UIImage.self) { object, _ in
                        continuation.resume(returning: object as? UIImage)
                    }
                }
            }
            let thumbnail = image?.preparingThumbnail(of: CGSize(width: 240, height: 160))
            return Preview(title: metadata.title, image: thumbnail)
        } catch { return nil } // The original saved URL always remains usable.
    }

    private static func filePreview(_ url: URL) async -> Preview? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 160), scale: 2, representationTypes: .thumbnail)
        do {
            let result = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return Preview(title: nil, image: result.uiImage)
        } catch { return nil } // Unsupported files still open in Quick Look.
    }
}

private extension View {
    @ViewBuilder
    func noteEditorPresentation(repository: TaskRepository, draft: Binding<QuickNoteEditorDraft?>) -> some View {
        // Device idiom keeps iPad presentation consistent in Split View and narrow
        // windows, where the horizontal size class can become compact.
        if UIDevice.current.userInterfaceIdiom == .pad {
            fullScreenCover(item: draft) { item in
                QuickNoteEditorView(repository: repository, draft: item)
            }
        } else {
            sheet(item: draft) { item in
                QuickNoteEditorView(repository: repository, draft: item)
            }
        }
    }
}

private struct NoteFolderPicker: View {
    @Binding var selection: String
    let folders: [String]
    @State private var showsCreateFolder = false
    @State private var newFolderName = ""
    private var choices: [String] {
        Array(Set(folders + (selection.isEmpty ? [] : [selection]))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        Picker("Folder", selection: $selection) {
            Text("Unfiled").tag("")
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.navigationLink)
        Button("New Folder", systemImage: "folder.badge.plus") {
            newFolderName = ""
            showsCreateFolder = true
        }
        .alert("New Note Folder", isPresented: $showsCreateFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                selection = choices.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The folder is saved when this note is saved or moved.")
        }
    }
}

private struct NoteMoveFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let note: QuickNote
    @State private var folder: String
    @State private var error: String?
    init(repository: TaskRepository, note: QuickNote) {
        self.repository = repository
        self.note = note
        _folder = State(initialValue: note.folder)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { NoteFolderPicker(selection: $folder, folders: repository.noteFolders) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Move Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        if repository.moveNote(id: note.id, toFolder: folder) { dismiss() }
                        else { error = repository.errorMessage ?? "Unable to move this note." }
                    }
                }
            }
        }
    }
}
