import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The single place a task is viewed and edited, like the Details screen in Reminders.
struct TaskDetailView: View {
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    var showsCloseButton = false

    var body: some View {
        if let task = repository.selectedTask {
            if repository.listProfile(task.listID).type == .reading {
                MediaItemDetailView(repository: repository, task: task, showsCloseButton: showsCloseButton).id(task.id)
            } else {
                TaskEditorView(repository: repository, draft: TaskDraft(task: task), task: task, showsDoneButton: showsCloseButton).id(task.id)
            }
        } else {
            ContentUnavailableView("No Task Selected", systemImage: "checklist", description: Text("Choose a task to see and edit its details."))
        }
    }
}

struct MediaItemDetailView: View {
    @Bindable var repository: TaskRepository
    let task: TaskItem
    var showsCloseButton = false
    @State private var editing = false
    @State private var findingArtwork = false
    @State private var trackingShow = false
    @State private var mergeCandidate: TaskItem?
    @Environment(\.dismiss) private var dismiss
    private var current: TaskItem { repository.tasks.first { $0.id == task.id } ?? task }
    private var details: SpecializedTaskDetails { repository.specializedDetails(current) }
    private var format: String { ReadingMedia.displayFormat(details.fields) }
    private var action: String { ReadingMedia.action(for: format) }
    private var duplicateCandidates: [TaskItem] { repository.mediaDuplicates(title: current.title, fields: details.fields, listID: current.listID, excluding: current.id) }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    CachedMediaPreview(rawURL: details.fields["Thumbnail URL"], format: format, expanded: details.fields["Thumbnail URL"] != nil || details.fields["Local Preview"] != nil, localPreview: details.fields["Local Preview"]).frame(maxWidth: .infinity)
                    Text(current.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text([format, details.fields["Year"], details.fields["Runtime Minutes"].map { $0 + " min" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    if let series = details.fields["Series Title"], !series.isEmpty { Text(series).foregroundStyle(.secondary) }
                    if let genres = details.fields["Genres"], !genres.isEmpty { Text(genres).font(.caption).foregroundStyle(.secondary) }
                    if let service = details.fields["Saved From"] ?? ReadingMedia.watchLinks(details.fields).first?.provider { Label("Saved from " + service, systemImage: "bookmark").font(.caption) }
                }
            }
            Section {
                ForEach(ReadingMedia.watchLinks(details.fields)) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(action + " on " + link.provider, systemImage: ReadingMedia.symbol(for: format))
                                let note = [link.region, link.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Button("Add or Edit Links", systemImage: "link.badge.plus") { editing = true }
            } header: { Text(action == "Watch" ? "Where to Watch · Saved Links" : "Source Links") } footer: {
                if action == "Watch" { Text("Saved services may require a subscription or rental. Availability varies by country; these links are not a verified availability search.") }
            }
            if action == "Watch", format != "Movie", format != "Episode" {
                Section("Show Tracking") {
                    Button(ReadingMedia.tracking(details.fields) == nil ? "Match Show & Track Episodes" : "Show & Episodes", systemImage: "tv") { trackingShow = true }
                }
            }
            Section("Progress") {
                Picker("Status", selection: Binding(get: { current.isCompleted ? "Finished" : details.fields["Progress"] ?? "Saved" }, set: { stage in
                    Task { await repository.setSpecializedStage(stage, for: current, type: .reading) }
                })) {
                    Text("Saved").tag("Saved")
                    Text(action == "Watch" ? "Watching" : action == "Listen" ? "Listening" : "Reading").tag("In Progress")
                    Text("Caught Up").tag("Caught Up")
                    Text("Dropped").tag("Dropped")
                    Text("Finished").tag("Finished")
                }
                if ["TV Show", "Episode"].contains(format), ReadingMedia.tracking(details.fields) == nil {
                    LabeledContent("Season", value: details.fields["Season"].flatMap { $0.isEmpty ? nil : $0 } ?? "Not set")
                    LabeledContent("Episode", value: details.fields["Episode"].flatMap { $0.isEmpty ? nil : $0 } ?? "Not set")
                    Button("Next Episode", systemImage: "forward.end") {
                        var updated = details
                        let episode = Int(updated.fields["Episode"] ?? "") ?? 0
                        guard episode < 100_000 else { return }
                        updated.fields["Episode"] = String(episode + 1)
                        updated.fields["Progress"] = "In Progress"
                        Task { _ = await repository.saveSpecializedDetails(updated, for: current, type: .reading) }
                    }.disabled(repository.isUndoing)
                }
                if let progress = details.fields["Progress Detail"], !progress.isEmpty { Text(progress).font(.subheadline) }
            }
            if !current.tags.isEmpty {
                Section("Tags") { Text(current.tags.map { "#" + $0 }.joined(separator: "  ")).font(.subheadline) }
            }
            Section("Personal Notes") {
                ForEach(["Recommended By", "Watch With", "Why Saved"], id: \.self) { key in
                    if let value = details.fields[key], !value.isEmpty { LabeledContent(key, value: value) }
                }
                if let rating = details.fields["Rating"], !rating.isEmpty { LabeledContent("Your Rating", value: rating + "/5") }
                if !current.notes.isEmpty { Text(current.notes).textSelection(.enabled) }
                Button("Edit Notes & Details", systemImage: "pencil") { editing = true }
            }
            if !duplicateCandidates.isEmpty {
                Section {
                    ForEach(duplicateCandidates) { duplicate in
                        Button("Combine links from “" + duplicate.title + "”", systemImage: "arrow.triangle.merge") { mergeCandidate = duplicate }
                    }
                } header: { Text("Possible Duplicates") } footer: { Text("Review before combining. Matching titles can be different releases. Your selected item keeps its progress and filled details; links, tags, and notes are combined. Undo restores both entries.") }
            }
            Section("Artwork") {
                if details.fields["Preview Status"] == "Pending" {
                    Label("Fetching media details…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                } else {
                    Button("Retry Link Preview", systemImage: "arrow.clockwise") { repository.retryReadingPreview(current) }
                }
                if action == "Watch", format != "Movie", format != "Episode" {
                    Button("Find Show Artwork", systemImage: "photo.on.rectangle") { findingArtwork = true }
                }
                if let raw = details.fields["Artwork Credit"], let url = URL(string: raw) {
                    Link("Artwork source: TVmaze (CC BY-SA)", destination: url).font(.caption)
                }
            }
            if let undo = repository.taskUndo {
                Section { Button("Undo " + undo.message, systemImage: "arrow.uturn.backward") { Task { await repository.undoLastTaskAction() } }.disabled(repository.isUndoing) }
            }
            if let error = repository.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Media Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true }.disabled(repository.isUndoing) }
            if showsCloseButton { ToolbarItem(placement: .confirmationAction) { Button("Done") { repository.selectedTaskID = nil; dismiss() } } }
        }
        .sheet(isPresented: $trackingShow) { WatchShowTracker(repository: repository, taskID: current.id) }
        .sheet(isPresented: $findingArtwork) {
            NavigationStack { ShowArtworkPicker(title: current.title) { show in
                Task { _ = await repository.applyShowArtwork(show, to: current) }
            } }
        }
        .sheet(isPresented: $editing) { NavigationStack { SpecializedTaskEditor(repository: repository, task: current, type: .reading) } }
        .confirmationDialog("Combine these saved entries?", isPresented: Binding(get: { mergeCandidate != nil }, set: { if !$0 { mergeCandidate = nil } }), titleVisibility: .visible) {
            if let candidate = mergeCandidate {
                Button("Combine Links") { Task { _ = await repository.mergeMediaItem(candidate, into: current); mergeCandidate = nil } }
            }
        }
    }
}

struct TaskSubtasksScreen: View {
    @Bindable var repository: TaskRepository
    let parentID: String
    @State private var newSubtaskDraft: TaskDraft?

    var body: some View {
        List {
            if let parent = repository.tasks.first(where: { $0.id == parentID }) {
                Section {
                    SubtasksSection(repository: repository, parent: parent, editorDraft: $newSubtaskDraft)
                }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Subtasks")
        .sheet(item: $newSubtaskDraft) { draft in
            TaskEditorView(repository: repository, draft: draft)
        }
    }
}

struct TaskDependenciesScreen: View {
    @Bindable var repository: TaskRepository
    let taskID: String

    var body: some View {
        List {
            if let task = repository.tasks.first(where: { $0.id == taskID }) {
                Section {
                    NavigationLink("Add or Remove Dependencies", destination: DependencyTaskPicker(repository: repository, taskID: taskID))
                    if repository.blockingTasks(for: task).isEmpty && repository.dependentTasks(for: task).isEmpty {
                        Text("No dependencies. Choose tasks that must finish before this one.")
                            .foregroundStyle(.secondary)
                    } else {
                        DependenciesSection(repository: repository, task: task)
                    }
                }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Dependencies")
    }
}

struct TaskCommentsScreen: View {
    @Bindable var repository: TaskRepository
    let taskID: String
    @State private var noteText = ""
    @FocusState private var isNoteFieldFocused: Bool

    var body: some View {
        List {
            if let task = repository.tasks.first(where: { $0.id == taskID }) {
                Section {
                    TaskNotesSection(repository: repository, task: task, noteText: $noteText,
                                     isNoteFieldFocused: $isNoteFieldFocused) {
                        isNoteFieldFocused = true
                    }
                }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Comments")
        .scrollDismissesKeyboard(.interactively)
        .onAppear { noteText = repository.commentDraft(for: taskID) }
    }
}


private struct DependenciesSection: View {
    @Bindable var repository: TaskRepository
    let task: TaskItem
    var compact = false

    private var blockers: [TaskItem] {
        repository.blockingTasks(for: task)
    }

    private var blockedTasks: [TaskItem] {
        repository.dependentTasks(for: task)
    }

    private var chain: [TaskItem] {
        repository.dependencyChain(for: task)
    }

    var body: some View {
        if !blockers.isEmpty || !blockedTasks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Dependencies")
                        .font(.headline)
                    Spacer()
                    if !blockers.isEmpty {
                        Label("\(blockers.count)", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if !blockers.isEmpty {
                    DependencyGroup(title: "Blocked By", icon: "lock.fill", color: repository.appTheme.primary, tasks: blockers) { dependency in
                        repository.selectTask(dependency)
                    }
                }

                if chain.count > blockers.count {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chain")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(Array(chain.prefix(6).enumerated()), id: \.element.id) { index, dependency in
                                Button {
                                    repository.selectTask(dependency)
                                } label: {
                                    Label(dependency.title, systemImage: index == 0 ? "1.circle.fill" : "arrowshape.turn.up.right.fill")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .tint(repository.appTheme.primary)
                            }
                        }
                    }
                }

                if !blockedTasks.isEmpty {
                    DependencyGroup(title: "Blocking", icon: "point.3.connected.trianglepath.dotted", color: repository.appTheme.primary, tasks: blockedTasks) { dependent in
                        repository.selectTask(dependent)
                    }
                }
            }
        }
    }
}

private struct DependencyGroup: View {
    let title: String
    let icon: String
    let color: Color
    let tasks: [TaskItem]
    let onSelect: (TaskItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)

            ForEach(tasks) { task in
                Button {
                    onSelect(task)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.isCompleted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(task.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SubtasksSection: View {
    @Bindable var repository: TaskRepository
    let parent: TaskItem
    @Binding var editorDraft: TaskDraft?
    var compact = false

    var body: some View {
        let subtasks = repository.subtasks(for: parent)
        ForEach(subtasks) { subtask in
            HStack(spacing: 12) {
                Button {
                    Task { await repository.toggleCompletion(for: subtask) }
                } label: {
                    Image(systemName: subtask.isCompleted ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(subtask.isCompleted ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(subtask.isCompleted ? "Mark \(subtask.title) incomplete" : "Mark \(subtask.title) complete")
                Text(subtask.title)
                    .foregroundStyle(subtask.isCompleted ? .secondary : .primary)
            }
        }
        Button("Add Subtask", systemImage: "plus") {
            editorDraft = repository.makeDraft(parentID: parent.id)
        }
    }
}

private struct TaskNotesSection: View {
    @Bindable var repository: TaskRepository
    let task: TaskItem
    @Binding var noteText: String
    var isNoteFieldFocused: FocusState<Bool>.Binding
    var compact = false
    let onFocusRequested: () -> Void
    @State private var query = ""
    @State private var filter = "All"
    @State private var editingComment: TaskComment?
    @State private var editText = ""
    @State private var deletingComment: TaskComment?

    private var visibleComments: [TaskComment] {
        task.comments.filter {
            (filter == "All" || (filter == "Resolved" ? $0.isResolved : !$0.isResolved)) &&
            (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Add a comment", text: Binding(
                get: { noteText },
                set: { noteText = $0; repository.saveCommentDraft($0, for: task.id) }
            ), axis: .vertical)
                .lineLimit(1...6)
                .focused(isNoteFieldFocused)
                .onTapGesture { onFocusRequested() }
                .accessibilityLabel("New comment")
            Button {
                let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                noteText = ""
                repository.saveCommentDraft("", for: task.id)
                isNoteFieldFocused.wrappedValue = false
                filter = "All"
                Task { await repository.addComment(text, to: task) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Post comment")
        }
        .sheet(item: $editingComment) { comment in
            NavigationStack {
                Form {
                    TextField("Comment", text: $editText, axis: .vertical)
                        .lineLimit(6...16)
                }
                .taskFlowThemedBackground()
                .navigationTitle("Edit Comment")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingComment = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let text = editText
                            Task { await repository.editComment(comment, text: text, on: task) }
                            editingComment = nil
                        }
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { deletingComment != nil }, set: { if !$0 { deletingComment = nil } }), titleVisibility: .visible) {
            Button("Delete Comment", role: .destructive) {
                if let comment = deletingComment {
                    Task { await repository.deleteComment(comment, on: task) }
                }
                deletingComment = nil
            }
            Button("Cancel", role: .cancel) { deletingComment = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .onChange(of: task.id) { _, _ in
            query = ""
            filter = "All"
            editingComment = nil
            deletingComment = nil
        }

        if task.comments.contains(where: \.isResolved) {
            Picker("Show", selection: $filter) {
                Text("All").tag("All")
                Text("Open").tag("Open")
                Text("Resolved").tag("Resolved")
            }
            .pickerStyle(.segmented)
        }

        ForEach(visibleComments) { comment in
            VStack(alignment: .leading, spacing: 4) {
                Text(comment.text)
                    .textSelection(.enabled)
                    .foregroundStyle(comment.isResolved ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if comment.editedAt != nil { Text("· Edited") }
                    if comment.isResolved { Text("· Resolved") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) { deletingComment = comment }
                Button(comment.isResolved ? "Reopen" : "Resolve", systemImage: comment.isResolved ? "arrow.uturn.backward" : "checkmark") {
                    Task { await repository.toggleComment(comment, on: task) }
                }
                .tint(.green)
            }
            .contextMenu {
                Button("Edit", systemImage: "pencil") {
                    editText = comment.text
                    editingComment = comment
                }
                Button(comment.isResolved ? "Reopen" : "Resolve", systemImage: comment.isResolved ? "arrow.uturn.backward" : "checkmark.circle") {
                    Task { await repository.toggleComment(comment, on: task) }
                }
                ShareLink(item: comment.text) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Delete", systemImage: "trash", role: .destructive) { deletingComment = comment }
            }
        }
    }
}

/// Results are selected explicitly; a shared title alone cannot identify a release.
struct ShowArtworkPicker: View {
    let title: String
    let choose: (ReadingMedia.ShowArtwork) -> Void
    @State private var selectedPoster: ReadingMedia.ShowArtwork?
    @State private var query = ""
    @State private var results: [ReadingMedia.ShowArtwork] = []
    @State private var loading = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                TextField("Show title", text: $query).onSubmit { search() }
                Button("Search TVmaze", systemImage: "magnifyingglass") { search() }.disabled(loading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: { Text("Search sends the title to TVmaze. Choose the correct show to use its poster. Your saved streaming links stay attached to this item.") }
            if loading { ProgressView("Finding posters…") }
            if let message { Text(message).foregroundStyle(.secondary) }
            ForEach(results) { show in
                Button {
                    selectedPoster = show
                } label: {
                    HStack {
                        CachedMediaPreview(rawURL: show.thumbnail?.absoluteString, format: "TV Show")
                        VStack(alignment: .leading) {
                            Text(show.name).foregroundStyle(.primary)
                            if let date = show.premiered { Text(String(date.prefix(4))).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section { Link("Artwork and show data: TVmaze · CC BY-SA", destination: URL(string: "https://www.tvmaze.com/api#licensing")!).font(.caption) }
        }
        .navigationTitle("Change Poster")
        .sheet(item: $selectedPoster) { show in
            NavigationStack {
                VStack(spacing: 20) {
                    CachedMediaPreview(rawURL: show.thumbnail?.absoluteString, format: "TV Show", poster: true)
                        .scaleEffect(1.6).padding(40)
                    Text(show.name).font(.title2)
                    if let date = show.premiered { Text(String(date.prefix(4))).foregroundStyle(.secondary) }
                    Button("Use This Poster") { choose(show); selectedPoster = nil; dismiss() }
                        .buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(show.thumbnail == nil)
                }.padding()
                .navigationTitle("Preview Poster")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selectedPoster = nil } } }
            }
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear { query = title }
    }
    private func search() {
        loading = true; message = nil; results = []
        let searched = query
        Task {
            defer { loading = false }
            do {
                results = try await ReadingMedia.searchShowArtwork(title: searched)
                if results.isEmpty { message = "No posters found. Try another title." }
            } catch { message = "Unable to search right now. Please try again." }
        }
    }
}
