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

struct QuickNoteEditorDraft: Identifiable {
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

struct QuickNoteEditorView: View {
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

struct QuickNoteDrawingCanvas: UIViewRepresentable {
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

struct QuickNoteDrawingThumbnail: View {
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

struct QuickNoteLayoutPreview: View {
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

struct QuickNoteBodyPreview: View {
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

struct QuickNoteAttachmentPicker<Content: View>: View {
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

struct QuickNoteAttachmentList: View {
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

extension TaskAttachment {
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

@MainActor
enum NoteDrawingImageCache {
    static let images: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 24; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
}

extension View {
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
