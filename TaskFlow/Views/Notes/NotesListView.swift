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

enum NotesFilter: String, CaseIterable, Identifiable {
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

struct TaskCommentItem: Identifiable, Hashable {
    let task: TaskItem
    let comment: TaskComment

    var id: String {
        "\(task.id)-\(comment.id.uuidString)"
    }
}

struct NotesCalendarEventSearchRow: View {
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

struct QuickNoteRow: View {
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

struct TaskNoteOverviewRow: View {
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

@MainActor
final class NotesListCache {
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

struct NoteFolderPicker: View {
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

struct NoteMoveFolderView: View {
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
