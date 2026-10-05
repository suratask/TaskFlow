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
            TaskEditorView(repository: repository, draft: TaskDraft(task: task), task: task, showsDoneButton: showsCloseButton)
                .id(task.id)
        } else {
            ContentUnavailableView("No Task Selected", systemImage: "checklist", description: Text("Choose a task to see and edit its details."))
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
                    if repository.blockingTasks(for: task).isEmpty && repository.dependentTasks(for: task).isEmpty {
                        Text("No dependencies. Use Status \u{201C}Blocked\u{201D} or link tasks from the task list to track what this task waits on.")
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
