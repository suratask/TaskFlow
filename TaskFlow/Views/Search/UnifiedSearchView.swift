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
