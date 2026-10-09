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

struct NoteChecklistPreview: View {
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

struct NoteChecklistEditor: View {
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

struct NoteVersionHistoryView: View {
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

func highlightedNoteText(_ text: String, query: String, activeOrdinal: Int? = nil) -> AttributedString {
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

struct NoteDocumentLineView: View {
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

/// Shared preview cards keep web links actionable even without fetched metadata,
/// and use Quick Look for full-resolution local documents and photos.
struct NoteAttachmentCard: View {
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

struct NoteAttachmentBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
enum NoteAttachmentPreviewCache {
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
