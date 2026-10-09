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
