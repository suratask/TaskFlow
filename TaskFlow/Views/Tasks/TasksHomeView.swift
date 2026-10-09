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

enum PinnedTaskItem: Identifiable, Hashable {
    case allTasks
    case upNext
    case list(TaskList)

    var id: String {
        switch self {
        case .allTasks: PinnedTaskIdentifier.allTasks
        case .upNext: PinnedTaskIdentifier.upNext
        case .list(let list): list.id
        }
    }

    var scope: TaskScope {
        switch self {
        case .allTasks: .all
        case .upNext: .upNext
        case .list(let list): .list(list.id)
        }
    }

    var title: String {
        switch self {
        case .allTasks: "All Tasks"
        case .upNext: "Upcoming"
        case .list(let list): list.title
        }
    }

    var icon: String {
        switch self {
        case .allTasks: "tray.full.fill"
        case .upNext: "calendar.badge.clock"
        case .list: "list.bullet"
        }
    }

    func color(theme: TaskRepository.AppTheme) -> Color {
        switch self {
        case .allTasks: theme.primary
        case .upNext: theme.secondary
        case .list(let list): list.color
        }
    }

    static func resolve(_ id: String, lists: [TaskList]) -> PinnedTaskItem? {
        if id == PinnedTaskIdentifier.allTasks { return .allTasks }
        if id == PinnedTaskIdentifier.upNext { return .upNext }
        guard let list = lists.first(where: { $0.id == id }) else { return nil }
        return .list(list)
    }
}

struct PinnedTaskCard: View {
    @Bindable var repository: TaskRepository
    let item: PinnedTaskItem

    private var count: Int { repository.taskCount(for: item.scope) }
    private var color: Color { item.color(theme: repository.appTheme) }
    private var subtitle: String {
        switch item {
        case .allTasks: "Everything in your lists"
        case .upNext: "Scheduled tasks by day"
        case .list: "Reminder list"
        }
    }

    /// Mirrors the smart-list tiles at the top of Apple Reminders.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: { if case .list(let list) = item { return repository.listIcon(for: list.id) }; return item.icon }())
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(color, in: Circle())
                Spacer(minLength: 8)
                Text(count, format: .number).font(.title.bold()).monospacedDigit().foregroundStyle(.primary)
            }
            Text(item.title).font(.headline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(count) tasks, \(subtitle)")
    }
}

struct PinnedTaskListsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository

    private var pinnedItems: [PinnedTaskItem] {
        repository.pinnedItemIDs.compactMap { PinnedTaskItem.resolve($0, lists: repository.lists) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pinnedItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: { if case .list(let list) = item { return repository.listIcon(for: list.id) }; return item.icon }()).foregroundStyle(item.color(theme: repository.appTheme))
                            Text(item.title)
                            Spacer()
                            Text(repository.taskCount(for: item.scope), format: .number).foregroundStyle(.secondary)
                        }
                    }
                    .onMove { repository.movePinnedItems(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Pinned · drag to reorder")
                } footer: {
                    Text("All Tasks and Up Next stay pinned. Up Next shows open reminders due today through the next 13 days.")
                }

                Section("Pin Lists") {
                    ForEach(repository.lists) { list in
                        Toggle(isOn: Binding(
                            get: { repository.pinnedListIDs.contains(list.id) },
                            set: { isPinned in
                                if isPinned != repository.pinnedListIDs.contains(list.id) {
                                    repository.togglePinnedList(list)
                                }
                            }
                        )) {
                            Label { Text(list.title) } icon: {
                                Image(systemName: repository.listIcon(for: list.id)).foregroundStyle(list.color)
                            }
                        }
                    }
                }
            }
            .overlay {
                if repository.lists.isEmpty {
                    ContentUnavailableView("No Lists", systemImage: "list.bullet", description: Text("All Tasks and Up Next are ready to use. Create a list to pin it here too."))
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Pinned Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TasksHomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @Binding var smartListDraft: SmartListDefinition?
    @Binding var selectedCalendarEvent: CalendarEvent?
    @SceneStorage("TaskFlow.tasks.path") private var savedPath = ""
    @State private var path: [TaskScope] = []
    @State private var restored = false
    @State private var showsPins = false
    @State private var showsNewList = false
    @State private var listName = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !repository.pinnedItemIDs.isEmpty {
                    Section {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                            ForEach(repository.pinnedItemIDs.compactMap { PinnedTaskItem.resolve($0, lists: repository.lists) }) { item in
                                Button {
                                    path.append(item.scope)
                                } label: {
                                    PinnedTaskCard(repository: repository, item: item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if case .list(let list) = item {
                                        Button("Unpin List", systemImage: "pin.slash") { repository.togglePinnedList(list) }
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    } header: {
                        HStack {
                            Text("Pinned Lists")
                            Spacer()
                            Button("Manage") { showsPins = true }
                                .textCase(nil)
                                .accessibilityLabel("Manage pinned list tiles")
                        }
                    }
                }
                if repository.isFocusFilterActive {
                    Section {
                        Label("A Focus is showing only some of your lists.", systemImage: "moon.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Browse") {
                    scopeRow("Inbox", icon: "tray", color: .blue, scope: .inbox)
                    scopeRow("Today", icon: "calendar", color: .teal, scope: .today)
                    scopeRow("Upcoming", icon: "calendar.badge.clock", color: .cyan, scope: .next7Days)
                    scopeRow("Flagged", icon: "flag", color: .orange, scope: .flagged)
                    scopeRow("Completed", icon: "checkmark.circle", color: .green, scope: .completed)
                }
                Section("My Lists") {
                    ForEach(repository.lists) { list in
                        scopeRow(list.title, icon: repository.listIcon(for: list.id), color: list.color, scope: .list(list.id))
                            .contextMenu {
                                Button(repository.pinnedListIDs.contains(list.id) ? "Unpin List" : "Pin List to Tasks", systemImage: repository.pinnedListIDs.contains(list.id) ? "pin.slash" : "pin") { repository.togglePinnedList(list) }
                                NavigationLink { ReminderListSettings(repository: repository, list: list) } label: { Label("Edit List", systemImage: "pencil") }
                                Menu("List Icon", systemImage: "square.grid.3x3") {
                                    ForEach(TaskRepository.listIconChoices, id: \.self) { icon in
                                        Button(icon.replacingOccurrences(of: ".", with: " "), systemImage: icon) { repository.setListIcon(icon, for: list.id) }
                                    }
                                }
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                let valid = Set(ids).intersection(Set(repository.tasks.map(\.id)))
                                guard !valid.isEmpty else { return false }
                                Task { await repository.moveTasks(toListID: list.id, taskIDs: valid) }
                                return true
                            }
                            .swipeActions {
                                Button(repository.pinnedListIDs.contains(list.id) ? "Unpin" : "Pin", systemImage: "pin") { repository.togglePinnedList(list) }.tint(.orange)
                            }
                    }
                    NavigationLink("Reorder Lists", destination: ListOrderEditor(repository: repository))
                    Button("New List", systemImage: "plus") { showsNewList = true }
                }
                Section("Smart Lists") {
                    ForEach(repository.smartLists) { list in
                        scopeRow(list.title, icon: list.icon, color: .purple, scope: .smart(list.id))
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { repository.deleteSmartList(list) }
                                Button("Edit", systemImage: "slider.horizontal.3") { smartListDraft = list }.tint(.blue)
                            }
                            .contextMenu {
                                Button("Edit Smart List", systemImage: "slider.horizontal.3") { smartListDraft = list }
                                Button("Delete Smart List", systemImage: "trash", role: .destructive) { repository.deleteSmartList(list) }
                            }
                    }
                    Button("New Smart List", systemImage: "plus") { smartListDraft = SmartListDefinition(title: "New Smart List") }
                }
                Section {
                    NavigationLink { AllTaskCommentsView(repository: repository) } label: {
                        Label("All Comments", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New Task", systemImage: "plus") { editorDraft = repository.makeDraft() }
                    Button("Pinned Lists", systemImage: "pin") { showsPins = true }
                }
            }
            .navigationDestination(for: TaskScope.self) { scope in
                TaskCollectionView(repository: repository, editorDraft: $editorDraft, smartListDraft: $smartListDraft, selectedCalendarEvent: $selectedCalendarEvent,
                                   viewModeOverride: .list)
                    .onAppear { repository.selectedScope = scope }
            }
        }
        .onChange(of: repository.pendingOpenListID) { _, id in
            guard let id else { return }
            path = [.list(id)]
            repository.pendingOpenListID = nil
        }
        .onAppear {
            if let id = repository.pendingOpenListID {
                path = [.list(id)]
                repository.pendingOpenListID = nil
                restored = true
            }
            guard !restored else { return }
            restored = true
            if let data = savedPath.data(using: .utf8), let scope = try? JSONDecoder().decode(TaskScope.self, from: data) {
                path = [scope]
            }
        }
        .onChange(of: path) { _, value in
            savedPath = value.last.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        .sheet(isPresented: $showsPins) { PinnedTaskListsEditor(repository: repository) }
        .alert("New List", isPresented: $showsNewList) {
            TextField("List name", text: $listName)
            Button("Cancel", role: .cancel) { listName = "" }
            Button("Create") {
                let name = listName
                listName = ""
                Task { await repository.createList(named: name) }
            }.disabled(listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func scopeRow(_ title: String, icon: String, color: Color, scope: TaskScope) -> some View {
        NavigationLink(value: scope) {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
                .badge(repository.taskCount(for: scope))
        }
    }
}
