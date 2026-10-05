import ActivityKit
import EventKit
import EventKitUI
import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TaskCollectionView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @Binding var smartListDraft: SmartListDefinition?
    @Binding var selectedCalendarEvent: CalendarEvent?
    var presentsCalendarEventSheet = true
    var viewModeOverride: TaskRepository.TaskViewMode?
    var titleOverride: String?
    var onExitPlanMyDay: (() -> Void)?
    @SceneStorage("TaskFlow.calendar.search") private var calendarSearch = ""
    @State private var showsPinnedLists = false
    @State private var confirmsBulkDelete = false
    @State private var isRestoringTaskScroll = false
    @State private var eventDraft: EventDraft?
    @State private var showsQuickCapture = false
    @State private var isBulkTagging = false
    @State private var bulkSelectedTaskIDs = Set<String>()
    @State private var isBulkTagSheetPresented = false
    @State private var isBulkDateSheetPresented = false
    @State private var isBulkMoveSheetPresented = false
    @State private var bulkTagSheetOperation: BulkTagOperation = .add
    @State private var searchScope: TaskSearchScope = .all
    @State private var isConfirmingClearCompleted = false
    @State private var pendingCompletedItems: [TaskItem] = []
    @State private var clearingCompleted = false

    var body: some View {
        Group {
            if (repository.selectedScope == .today || repository.selectedScope == .planMyDay) && viewModeOverride == nil {
                TodayDashboardView(repository: repository, editorDraft: $editorDraft)
            } else if repository.selectedScope == .notes && viewModeOverride == nil {
                AllNotesView(
                    repository: repository,
                    selectedCalendarEvent: $selectedCalendarEvent
                )
            } else {
                taskContent
                .taskFlowThemedBackground()
                .navigationTitle(title)
                .searchable(text: effectiveViewMode == .calendar ? $calendarSearch : $repository.searchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search or type #tag")
                .searchScopes($searchScope, activation: .onSearchPresentation) {
                    ForEach(TaskSearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .searchSuggestions {
                    if effectiveViewMode != .calendar {
                        ForEach(tagSuggestions, id: \.self) { tag in
                            Label("#\(tag)", systemImage: "number").searchCompletion("#\(tag)")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, horizontalContentMargin, for: .scrollContent)
                .background(
                    TaskFlowBackground(accent: repository.appTheme.primary)
                )
                .toolbar {
                    if isBulkTagging {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(areAllVisibleTasksSelected ? "Deselect All" : "Select All") {
                                bulkSelectedTaskIDs = areAllVisibleTasksSelected ? [] : visibleBulkTaskIDs
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: endBulkTagging)
                        }
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("Complete", systemImage: "checkmark.circle") {
                                Task {
                                    await repository.setCompletion(true, forTaskIDs: bulkSelectedTaskIDs)
                                    endBulkTagging()
                                }
                            }
                            Spacer()
                            Button("Due Date", systemImage: "calendar") { isBulkDateSheetPresented = true }
                            Spacer()
                            Button("Move", systemImage: "folder") { isBulkMoveSheetPresented = true }
                            Spacer()
                            Menu {
                                Button("Delete Selected…", systemImage: "trash", role: .destructive) { confirmsBulkDelete = true }
                                Button("Add Tags…", systemImage: "tag") { openBulkTagSheet(operation: .add) }
                                Button("Remove Tags…", systemImage: "tag.slash") { openBulkTagSheet(operation: .remove) }
                                Button("Move to Next Work Block", systemImage: "calendar.badge.clock") {
                                    Task {
                                        await repository.moveTasksToNextOpenWorkBlock(taskIDs: bulkSelectedTaskIDs)
                                        endBulkTagging()
                                    }
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                        }
                    } else if effectiveViewMode != .calendar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        TaskFilterMenu(repository: repository)

                        Menu {
                            Button("New Task", systemImage: "checklist") { editorDraft = repository.makeDraft() }
                            Button("New Event", systemImage: "calendar.badge.plus") { eventDraft = repository.makeEventDraft() }
                            Button("Quick Capture", systemImage: "text.cursor") { showsQuickCapture = true }
                        } label: {
                            Image(systemName: "plus")
                        } primaryAction: {
                            editorDraft = repository.makeDraft()
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityLabel("New task")
                        .accessibilityHint("Touch and hold for more options")

                        Menu {
                            if let action = repository.taskUndo {
                                Button("Undo " + action.message, systemImage: "arrow.uturn.backward") { Task { await repository.undoLastTaskAction() } }
                            }
                            if let action = repository.taskRedo {
                                Button("Redo " + action.message, systemImage: "arrow.uturn.forward") { Task { await repository.redoLastTaskAction() } }
                                    .keyboardShortcut("z", modifiers: [.command, .shift])
                            }
                            if case .list(let id) = repository.selectedScope,
                               let list = repository.lists.first(where: { $0.id == id }) {
                                Button(repository.pinnedListIDs.contains(id) ? "Unpin List" : "Pin List to Tasks", systemImage: repository.pinnedListIDs.contains(id) ? "pin.slash" : "pin") { repository.togglePinnedList(list) }
                            }
                            Button("Manage Pinned Lists", systemImage: "pin") { showsPinnedLists = true }
                            Button("Select Tasks", systemImage: "checkmark.circle") { beginBulkTagging() }
                            Button("Clear Completed Reminders", systemImage: "trash", role: .destructive) { promptToClearCompleted() }
                                .disabled(clearingCompleted || repository.isUndoing || repository.completedTasksInSelectedScope.isEmpty)
                            Picker("View As", selection: Binding(
                                get: { effectiveViewMode == .board ? TaskRepository.TaskViewMode.board : .list },
                                set: { mode in
                                    repository.taskViewMode = mode
                                    if case .list(let id) = repository.selectedScope {
                                        var profile = repository.listProfile(id)
                                        profile.settings["View Mode"] = mode.rawValue
                                        repository.setListProfile(profile, for: id)
                                    }
                                }
                            )) {
                                Label("List", systemImage: "list.bullet").tag(TaskRepository.TaskViewMode.list)
                                Label("Columns", systemImage: "rectangle.split.3x1").tag(TaskRepository.TaskViewMode.board)
                            }
                            .pickerStyle(.menu)
                            if let currentSmartList {
                                Button("Edit Smart List", systemImage: "slider.horizontal.3") { smartListDraft = currentSmartList }
                            }
                            NavigationLink(destination: AllTaskCommentsView(repository: repository)) {
                                Label("All Comments", systemImage: "bubble.left.and.bubble.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More task actions")
                    }
                    }
                }
                .toolbar(isBulkTagging ? .hidden : .automatic, for: .tabBar)
            }
        }
        .overlay {
            if repository.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
            }
        }
        .confirmationDialog("Delete selected tasks?", isPresented: $confirmsBulkDelete, titleVisibility: .visible) {
            Button("Delete \(bulkSelectedTaskIDs.count) Tasks", role: .destructive) {
                let ids = bulkSelectedTaskIDs
                Task { await repository.deleteTasks(ids); endBulkTagging() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These tasks will be removed from their reminder lists. You can undo the deletion in TaskFlow.")
        }
        .confirmationDialog("Clear \(pendingCompletedItems.count) Completed Reminders?", isPresented: $isConfirmingClearCompleted, titleVisibility: .visible) {
            Button("Clear Completed", role: .destructive) {
                let items = pendingCompletedItems
                clearingCompleted = true
                Task { await repository.clearCompletedTasks(items); clearingCompleted = false; pendingCompletedItems = [] }
            }
            Button("Cancel", role: .cancel) { pendingCompletedItems = [] }
        } message: { Text("Deletes these completed reminders from this view and synced devices. You can undo this in TaskFlow.") }
        .sheet(isPresented: $showsPinnedLists) { PinnedTaskListsEditor(repository: repository) }
        .sheet(item: compactCalendarEventSheetSelection) { event in
            CalendarEventDetailView(repository: repository, event: event, color: eventColor(for: event.calendarID))
        }
        .sheet(item: $eventDraft) { draft in
            CalendarEventEditorView(repository: repository, draft: draft)
        }
        .sheet(isPresented: $showsQuickCapture) {
            QuickCaptureView(
                repository: repository,
                onTask: { draft in editorDraft = draft },
                onEvent: { draft in eventDraft = draft }
            )
        }
        .sheet(isPresented: $isBulkTagSheetPresented) {
            BulkTaskTaggingSheet(
                repository: repository,
                selectedCount: bulkSelectedTaskIDs.count,
                initialOperation: bulkTagSheetOperation,
                onApply: { operation, tags in
                    Task {
                        await applyBulkTags(tags, operation: operation)
                        endBulkTagging()
                    }
                }
            )
        }
        .sheet(isPresented: $isBulkDateSheetPresented) {
            BulkRescheduleTasksSheet(selectedCount: bulkSelectedTaskIDs.count) { dueDate, hasDueTime in
                Task {
                    await repository.setDueDate(dueDate, hasDueTime: hasDueTime, forTaskIDs: bulkSelectedTaskIDs)
                    endBulkTagging()
                }
            }
        }
        .sheet(isPresented: $isBulkMoveSheetPresented) {
            BulkMoveTasksSheet(repository: repository, selectedCount: bulkSelectedTaskIDs.count) { listID in
                Task {
                    await repository.moveTasks(toListID: listID, taskIDs: bulkSelectedTaskIDs)
                    endBulkTagging()
                }
            }
        }
    }

    private func promptToClearCompleted() {
        pendingCompletedItems = repository.completedTasksInSelectedScope
        if !pendingCompletedItems.isEmpty { isConfirmingClearCompleted = true }
    }

    @ViewBuilder
    private var taskContent: some View {
        Group {
            if case .list(let id) = repository.selectedScope, repository.listProfile(id).type != .standard, effectiveViewMode != .calendar {
                SpecializedTaskListView(repository: repository, listID: id, viewMode: effectiveViewMode, editorDraft: $editorDraft)
            } else {
            switch effectiveViewMode {
            case .list, .timeline:
                taskList
            case .calendar:
                CalendarBoardView(
                    searchQuery: calendarSearch,
                    repository: repository,
                    editorDraft: $editorDraft,
                    selectedCalendarEvent: $selectedCalendarEvent,
                    eventDraft: $eventDraft,
                    title: title,
                    accentColor: accentColor,
                    upcomingCount: upcomingCount,
                    attachmentCount: attachmentCount,
                    listColor: listColor(for:)
                )
            case .board:
                TaskBoardView(repository: repository, listColor: listColor(for:))
            case .agenda:
                AgendaView(
                    repository: repository,
                    editorDraft: $editorDraft,
                    selectedCalendarEvent: $selectedCalendarEvent,
                    title: title,
                    accentColor: accentColor,
                    upcomingCount: upcomingCount,
                    attachmentCount: attachmentCount,
                    listColor: listColor(for:)
                )
            }
            }
        }
    }

    /// Lists show as rows or Reminders-style columns; the retired Timeline mode falls back to rows.
    private var tagSuggestions: [String] {
        let query = repository.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.hasPrefix("#") else { return [] }
        let partial = query.dropFirst()
        return repository.allTags.filter { partial.isEmpty || $0.localizedCaseInsensitiveContains(partial) }.prefix(8).map { $0 }
    }

    private var effectiveViewMode: TaskRepository.TaskViewMode {
        if viewModeOverride == .calendar { return .calendar }
        if viewModeOverride == nil, case .list(let id) = repository.selectedScope,
           let raw = repository.listProfile(id).settings["View Mode"], let mode = TaskRepository.TaskViewMode(rawValue: raw) { return mode }
        if repository.taskViewMode == .board { return .board }
        let mode = viewModeOverride ?? repository.taskViewMode
        return mode == .timeline ? .list : mode
    }

    private var showsBulkTagButton: Bool {
        effectiveViewMode != .calendar
    }

    private var matchingLists: [TaskList] {
        guard repository.isSearchActive else { return [] }
        let query = repository.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return repository.lists.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var currentSmartList: SmartListDefinition? {
        guard case .smart(let id) = repository.selectedScope else { return nil }
        return repository.smartLists.first { $0.id == id }
    }

    private var compactCalendarEventSheetSelection: Binding<CalendarEvent?> {
        Binding {
            presentsCalendarEventSheet ? selectedCalendarEvent : nil
        } set: { event in
            selectedCalendarEvent = event
        }
    }

    private var taskList: some View {
        ScrollViewReader { proxy in
        List(selection: taskSelection) {
            if repository.isSearchActive && !matchingLists.isEmpty {
                Section("Lists") {
                    ForEach(matchingLists) { list in
                        Button {
                            repository.selectedScope = .list(list.id)
                            repository.selectedTaskID = nil
                            repository.searchQuery = ""
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(list.color)
                                Text(list.title).foregroundStyle(.primary)
                                Spacer()
                                Text(repository.taskCount(for: .list(list.id)), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if repository.isSearchActive && searchScope != .tasks && !repository.filteredCalendarEvents.isEmpty {
                Section("Calendar Events") {
                    ForEach(repository.filteredCalendarEvents, id: \.occurrenceKey) { event in
                        CalendarEventSearchRow(event: event, color: eventColor(for: event.calendarID)) {
                            selectedCalendarEvent = event
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if repository.isSearchActive && searchScope == .events {
                EmptyView()
            } else if repository.rootTasks.isEmpty && (!repository.isSearchActive || repository.filteredCalendarEvents.isEmpty) {
                EmptyTaskStateView(repository: repository, editorDraft: $editorDraft)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(repository.groupedRootTasks) { group in
                    Section {
                        ForEach(group.tasks) { task in
                            TaskRowView(
                                task: task,
                                subtasks: repository.subtasks(for: task),
                                isSelected: isBulkTagging ? bulkSelectedTaskIDs.contains(task.id) : repository.selectedTaskID == task.id,
                                isBulkTagging: isBulkTagging,
                                listColor: listColor(for: task.listID),
                                tagColor: repository.color(forTag:),
                                density: effectiveTaskDensity,
                                usesGroupedListStyle: true,
                                repository: repository,
                                onOpen: {
                                    if isBulkTagging { toggleBulkSelection(for: task.id) }
                                    else { repository.selectedTaskID = task.id }
                                }
                            )
                            .id(task.id)
                            .draggable(task.id)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: TaskScrollOffsets.self, value: [task.id: geometry.frame(in: .named("task-list")).minY])
                                }
                            }
                            .tag(task.id)
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await repository.toggleCompletion(for: task) }
                                } label: {
                                    Label(task.isCompleted ? "Reopen" : "Complete", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark")
                                }
                                .tint(.green)
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Reschedule", systemImage: "calendar") {
                                    bulkSelectedTaskIDs = [task.id]
                                    isBulkDateSheetPresented = true
                                }.tint(.blue)
                                Button(role: .destructive) {
                                    Task { await repository.deleteTask(task) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    Task { await repository.setFlagged(!task.isFlagged, for: task) }
                                } label: {
                                    Label(task.isFlagged ? "Unflag" : "Flag", systemImage: task.isFlagged ? "flag.slash" : "flag")
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        if repository.taskGroupOption != .none {
                            Text(group.title)
                        }
                    }
                }
            }

            let completed = repository.completedTasksInSelectedScope
            if !repository.isSearchActive && repository.selectedScope != .completed && !completed.isEmpty {
                Section {
                    HStack {
                        Text("\(completed.count) Completed")
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        Button("Clear") { promptToClearCompleted() }.disabled(clearingCompleted || repository.isUndoing)
                            .buttonStyle(.borderless)
                        Spacer()
                        Button(repository.includeCompletedTasks ? "Hide" : "Show") {
                            withAnimation { repository.includeCompletedTasks.toggle() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.subheadline)
                    .listRowBackground(Color.clear)

                }
            }

            if repository.accessState == .granted && repository.selectedScope != .completed && !isBulkTagging {
                Section {
                    InlineNewTaskRow(
                        repository: repository,
                        defaultDue: repository.selectedScope == .today ? .today : .none,
                        defaultFlagged: repository.selectedScope == .flagged,
                        onShowDetails: { editorDraft = $0 },
                        onAdded: { withAnimation { proxy.scrollTo(InlineNewTaskRow.scrollID, anchor: .bottom) } }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(0)
        .listSectionSpacing(.compact)
        .coordinateSpace(name: "task-list")
        .onPreferenceChange(TaskScrollOffsets.self) { values in
            guard !isRestoringTaskScroll, let id = TaskScrollOffsets.topItem(values) else { return }
            repository.saveScrollAnchor(id, for: repository.selectedScope)
        }
        .task(id: "\(repository.selectedScope.id)-\(repository.rootTasks.count)") {
            isRestoringTaskScroll = true
            let saved = repository.scrollAnchor(for: repository.selectedScope)
            await Task.yield()
            if let saved, repository.rootTasks.contains(where: { $0.id == saved }) {
                proxy.scrollTo(saved, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { isRestoringTaskScroll = false }
        }
        }
    }

    private var title: String {
        if let titleOverride {
            return titleOverride
        }
        if effectiveViewMode == .calendar {
            return "Calendar"
        }

        return switch repository.selectedScope {
        case .all: "All Tasks"
        case .inbox: "Inbox"
        case .notes: "Notes"
        case .today: "Today"
        case .flagged: "Flagged"
        case .completed: "Completed"
        case .next7Days: "Next 7 Days"
        case .upNext: "Up Next"
        case .planMyDay: "Plan My Day"
        case .list(let id): repository.lists.first { $0.id == id }?.title ?? "List"
        case .smart(let id): repository.smartLists.first { $0.id == id }?.title ?? "Smart List"
        }
    }

    private var accentColor: Color { repository.appTheme.primary }

    private var upcomingCount: Int {
        repository.rootTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return dueDate >= Date()
        }.count
    }

    private var attachmentCount: Int {
        repository.rootTasks.reduce(0) { $0 + $1.attachments.count }
    }

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    private var horizontalContentMargin: CGFloat {
        if horizontalSizeClass == .regular {
            return 8
        }
        return isCompactHeight ? 6 : 0
    }

    private var effectiveTaskDensity: TaskRepository.TaskDensity {
        isCompactHeight ? .compact : repository.taskDensity
    }

    private var taskSelection: Binding<String?> {
        Binding {
            isBulkTagging ? nil : repository.selectedTaskID
        } set: { newValue in
            if !isBulkTagging {
                repository.selectedTaskID = newValue
            }
        }
    }

    private var visibleBulkTaskIDs: Set<String> {
        Set(repository.rootTasks.map(\.id))
    }

    private var areAllVisibleTasksSelected: Bool {
        let visible = visibleBulkTaskIDs
        return !visible.isEmpty && visible.isSubset(of: bulkSelectedTaskIDs)
    }

    private func beginBulkTagging() {
        isBulkTagging = true
        repository.selectedTaskID = nil
    }

    private func endBulkTagging() {
        isBulkTagging = false
        bulkSelectedTaskIDs.removeAll()
        isBulkTagSheetPresented = false
    }

    private func toggleBulkSelection(for taskID: String) {
        if bulkSelectedTaskIDs.contains(taskID) {
            bulkSelectedTaskIDs.remove(taskID)
        } else {
            bulkSelectedTaskIDs.insert(taskID)
        }
    }

    private func toggleAllVisibleTasksForBulkTagging() {
        let visible = visibleBulkTaskIDs
        if areAllVisibleTasksSelected {
            bulkSelectedTaskIDs.subtract(visible)
        } else {
            bulkSelectedTaskIDs.formUnion(visible)
        }
    }

    private func openBulkTagSheet(operation: BulkTagOperation) {
        bulkTagSheetOperation = operation
        isBulkTagSheetPresented = true
    }

    private func applyBulkTags(_ tags: [String], operation: BulkTagOperation) async {
        guard !tags.isEmpty, !bulkSelectedTaskIDs.isEmpty else { return }
        switch operation {
        case .add:
            await repository.addTags(tags, toTaskIDs: bulkSelectedTaskIDs)
        case .remove:
            await repository.removeTags(tags, fromTaskIDs: bulkSelectedTaskIDs)
        }
    }

    private func select(_ scope: TaskScope) {
        repository.selectedScope = scope
        repository.selectedTaskID = nil
    }

    private func exitPlanMyDay() {
        repository.selectedTaskID = nil

        if let onExitPlanMyDay {
            onExitPlanMyDay()
        } else {
            repository.selectedScope = .today
        }
    }

    private func listColor(for listID: String) -> Color {
        repository.lists.first { $0.id == listID }?.color ?? .indigo
    }

    private func eventColor(for calendarID: String) -> Color {
        repository.eventCalendars.first { $0.id == calendarID }?.color ?? .blue
    }
}

private struct CalendarEventSearchRow: View {
    let event: CalendarEvent
    let color: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.isAllDay ? "calendar" : "calendar.badge.clock")
                    .font(.headline)
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Label(timeText, systemImage: event.isAllDay ? "sun.max" : "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous)
                    .fill(color)
                    .frame(width: 5)
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

private struct FocusModeBrief: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @Bindable var repository: TaskRepository
    let listColor: (String) -> Color
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 8 : 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "scope")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Color.yellow, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Focus Mode")
                        .font(.headline.weight(.bold))
                    Text(summaryText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button("Off") {
                    repository.isFocusModeEnabled = false
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
            }

            if let task = firstActionTask {
                HStack(spacing: 10) {
                    Circle()
                        .strokeBorder(listColor(task.listID), lineWidth: 3)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.isOverdue() ? "Handle first" : "Good fit")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(task.title)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous)
                .fill(Color.yellow)
                .frame(width: 5)
        }
    }

    private var firstActionTask: TaskItem? {
        repository.focusTasks.first
    }

    private var summaryText: String {
        let overdue = repository.tasks.filter { $0.isOverdue() }.count
        let nextEvent = repository.nextFocusEvent.map { event in
            "next: \(event.title)"
        }
        let gap = repository.dayTimeGaps().first.map { $0.title }
        let parts = [
            overdue > 0 ? "\(overdue) overdue" : nil,
            nextEvent,
            gap
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing urgent. You’re clear for now." : parts.joined(separator: " • ")
    }

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }
}

private struct TimelineSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let color: Color
    let tasks: [TaskItem]

    static func makeSections(from tasks: [TaskItem]) -> [TimelineSection] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) ?? today

        let sortedTasks = tasks.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }

        let buckets: [(id: String, title: String, subtitle: String, color: Color, matches: (TaskItem) -> Bool)] = [
            ("overdue", "Overdue", "Needs attention", .red, { task in
                guard let dueDate = task.dueDate else { return false }
                return dueDate < today && !task.isCompleted
            }),
            ("today", "Today", "Due before midnight", .teal, { task in
                guard let dueDate = task.dueDate else { return false }
                return calendar.isDate(dueDate, inSameDayAs: today) && !task.isCompleted
            }),
            ("tomorrow", "Tomorrow", "Coming up next", .cyan, { task in
                guard let dueDate = task.dueDate else { return false }
                return calendar.isDate(dueDate, inSameDayAs: tomorrow) && !task.isCompleted
            }),
            ("next-seven-days", "Next 7 Days", "Scheduled work", .indigo, { task in
                guard let dueDate = task.dueDate else { return false }
                return dueDate >= tomorrow && dueDate < nextWeek && !calendar.isDate(dueDate, inSameDayAs: tomorrow) && !task.isCompleted
            }),
            ("later", "Later", "Beyond the next week", .accentColor, { task in
                guard let dueDate = task.dueDate else { return false }
                return dueDate >= nextWeek && !task.isCompleted
            }),
            ("unscheduled", "Unscheduled", "No due date yet", .secondary, { task in
                task.dueDate == nil && !task.isCompleted
            }),
            ("completed", "Completed", "Finished work in this view", .green, { task in
                task.isCompleted
            })
        ]

        var usedTaskIDs = Set<String>()
        return buckets.compactMap { bucket in
            let bucketTasks = sortedTasks.filter { task in
                guard !usedTaskIDs.contains(task.id), bucket.matches(task) else { return false }
                return true
            }
            guard !bucketTasks.isEmpty else { return nil }
            usedTaskIDs.formUnion(bucketTasks.map(\.id))
            return TimelineSection(
                id: bucket.id,
                title: bucket.title,
                subtitle: bucket.subtitle,
                color: bucket.color,
                tasks: bucketTasks
            )
        }
    }
}

private struct TaskMilestone: Identifiable {
    let id: String
    let title: String
    let date: Date?
    let icon: String
    let color: Color

    static func makeMilestones(for task: TaskItem) -> [TaskMilestone] {
        var items: [TaskMilestone] = []

        if let createdAt = task.createdAt {
            items.append(TaskMilestone(id: "created", title: "Created", date: createdAt, icon: "sparkle", color: .cyan))
        }
        if task.status != .notStarted {
            items.append(TaskMilestone(id: "status", title: "Status: \(task.status.rawValue)", date: task.modifiedAt, icon: "dial.high.fill", color: statusColor(task.status)))
        }
        if let dueDate = task.dueDate {
            items.append(TaskMilestone(id: "due", title: task.isCompleted ? "Was due" : "Due", date: dueDate, icon: "calendar.badge.clock", color: task.status == .overdue ? .red : .teal))
        }
        if task.isCompleted {
            items.append(TaskMilestone(id: "completed", title: "Completed", date: task.completedAt ?? task.modifiedAt, icon: "checkmark.seal.fill", color: .green))
        }
        for attachment in task.attachments.sorted(by: { $0.createdAt > $1.createdAt }).prefix(2) {
            items.append(TaskMilestone(id: "attachment-\(attachment.id.uuidString)", title: "Attachment: \(attachment.title)", date: attachment.createdAt, icon: attachment.icon, color: .blue))
        }
        for comment in task.comments.sorted(by: { $0.createdAt > $1.createdAt }).prefix(2) {
            items.append(TaskMilestone(id: "comment-\(comment.id.uuidString)", title: comment.isResolved ? "Resolved note" : "Note added", date: comment.createdAt, icon: "text.bubble.fill", color: comment.isResolved ? .green : .purple))
        }

        return items.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.title < rhs.title
            }
        }
    }

    private static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .notStarted: .secondary
        case .active: .blue
        case .waiting: .secondary
        case .blocked: .secondary
        case .overdue: .red
        case .done: .green
        }
    }
}

private struct CalendarBoardView: View {
    var searchQuery = ""
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    enum CalendarMode: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case agenda = "Agenda"
        case timeline = "Hours"

        var id: String { rawValue }

        /// The four standard calendar views; the older "Hours" mode now opens as Day.
        static let pickerCases: [CalendarMode] = [.day, .week, .month, .agenda]

        var displayName: String { self == .agenda ? "List" : rawValue }
    }

    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @Binding var selectedCalendarEvent: CalendarEvent?
    @Binding var eventDraft: EventDraft?
    let title: String
    let accentColor: Color
    let upcomingCount: Int
    let attachmentCount: Int
    let listColor: (String) -> Color

    @SceneStorage("TaskFlow.calendar.scrollDay") private var scrollDay = ""
    @State private var restoringCalendarScroll = false
    @SceneStorage("TaskFlow.calendar.mode") private var savedMode = CalendarMode.agenda.rawValue
    @SceneStorage("TaskFlow.calendar.date") private var savedDate = Date().timeIntervalSince1970

    @AppStorage("TaskFlow.calendar.workspace") private var workspaceData = Data()
    @AppStorage("TaskFlow.calendar.savedContexts") private var contextsData = Data()
    @State private var showConflictChecker = false
    @State private var showPlanner = false
    @State private var showPreferences = false
    @State private var showCommand = false
    @State private var showFilters = false
    @State private var showSaveContext = false
    @State private var contextName = ""
    @State private var localQuery = ""
    @State private var overridesGlobalSearch = false
    @State private var visibleListIDs: Set<String> = []
    @State private var filterStart = Date()
    @State private var filterEnd = Date()
    @State private var useDateRange = false

    private var workspace: CalendarWorkspaceSettings {
        get { (try? JSONDecoder().decode(CalendarWorkspaceSettings.self, from: workspaceData)) ?? CalendarWorkspaceSettings() }
        nonmutating set { workspaceData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    private var contexts: [SavedCalendarContext] {
        get { (try? JSONDecoder().decode([SavedCalendarContext].self, from: contextsData)) ?? [] }
        nonmutating set { contextsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    private var effectiveQuery: String { overridesGlobalSearch || !localQuery.isEmpty ? localQuery : searchQuery }
    private func matches(_ values: [String]) -> Bool {
        effectiveQuery.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(effectiveQuery) }
    }
    private func inDateRange(_ date: Date) -> Bool {
        !useDateRange || (date >= calendar.startOfDay(for: filterStart) && date < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: filterEnd)) ?? filterEnd))
    }
    private func withinWorkingHours(start: Date, end: Date) -> Bool {
        guard workspace.hideNonworkingHours else { return true }
        guard workspace.weekdays.contains(calendar.component(.weekday, from: start)) else { return false }
        let lower = calendar.date(bySettingHour: workspace.workStart, minute: 0, second: 0, of: start) ?? start
        let upper = calendar.date(bySettingHour: workspace.workEnd, minute: 0, second: 0, of: start) ?? end
        return start < upper && end > lower
    }

    private var mode: CalendarMode {
        get {
            let stored = CalendarMode(rawValue: savedMode) ?? .agenda
            return stored == .timeline ? .day : stored
        }
        nonmutating set { savedMode = newValue.rawValue }
    }
    private var selectedDate: Date {
        get { Date(timeIntervalSince1970: savedDate) }
        nonmutating set { savedDate = newValue.timeIntervalSince1970 }
    }

    private let calendar = Calendar.current

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact || workspace.compact
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: isCompactHeight ? 10 : 16) {

                if repository.isFocusModeEnabled {
                    FocusModeBrief(repository: repository, listColor: listColor)
                        .padding(.horizontal, 16)
                }

                switch mode {
                case .day:
                    dayView
                case .week:
                    weekView
                case .month:
                    monthView
                case .agenda:
                    agendaView
                case .timeline:
                    CalendarHourGrid(date: selectedDate, events: events(on: selectedDate), settings: workspace, selectedEvent: $selectedCalendarEvent, color: eventColor(for:))
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, isCompactHeight ? 10 : 16)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) { calendarToolbar }
                .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Today") {
                    scrollDay = ""
                    selectedDate = Date()
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("New Event", systemImage: "plus") {
                    eventDraft = repository.makeEventDraft(on: selectedDate)
                }
                Menu {
                    Button("New Task", systemImage: "checklist") {
                        editorDraft = repository.makeDraft()
                    }
                    Button("Go to Date…", systemImage: "calendar") { showCommand = true }
                    Button("Conflict Checker", systemImage: "calendar.badge.exclamationmark") { showConflictChecker = true }
                    Button("Plan Time", systemImage: "calendar.badge.clock") { showPlanner = true }
                    Divider()
                    Button("Filters", systemImage: "line.3.horizontal.decrease.circle") { showFilters = true }
                    Button("Calendar Settings", systemImage: "gearshape") { showPreferences = true }
                    Section("Saved Views") {
                        Button("Save Current View…", systemImage: "square.and.arrow.down") { showSaveContext = true }
                        ForEach(contexts) { context in
                            Button(context.name) { apply(context) }
                        }
                        if !contexts.isEmpty {
                            Menu("Delete Saved View") {
                                ForEach(contexts) { context in Button(context.name, role: .destructive) { contexts.removeAll { $0.id == context.id } } }
                            }
                        }
                    }
                } label: {
                    Label("Calendar Options", systemImage: "ellipsis")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showConflictChecker) {
            CalendarConflictCheckerPage(repository: repository)
        }
        .sheet(isPresented: $showPlanner) {
            CalendarPlanningSheet(repository: repository, settings: Binding(get: { workspace }, set: { workspace = $0 }))
        }
        .sheet(isPresented: $showPreferences) {
            CalendarPreferencesSheet(settings: Binding(get: { workspace }, set: { workspace = $0 }))
        }
        .sheet(isPresented: $showCommand) { commandSheet }
        .sheet(isPresented: $showFilters) { filtersSheet }
        .alert("Save Calendar View", isPresented: $showSaveContext) {
            TextField("Name", text: $contextName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let name = contextName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                contexts.append(SavedCalendarContext(name: name, mode: savedMode, calendarIDs: repository.selectedEventCalendarIDs, listIDs: visibleListIDs, query: effectiveQuery, start: useDateRange ? filterStart : nil, end: useDateRange ? filterEnd : nil))
                contextName = ""
            }
        }
        .task(id: "\(savedDate)-\(repository.selectedEventCalendarIDs.sorted().joined(separator: ","))") {
            await repository.showCalendarDate(selectedDate)
        }
        .coordinateSpace(name: "calendar-scroll")
        .onPreferenceChange(TaskScrollOffsets.self) { values in
            guard mode == .agenda, !restoringCalendarScroll, let id = TaskScrollOffsets.topItem(values) else { return }
            scrollDay = id
        }
        .task(id: "\(mode.rawValue)-\(selectedDate.timeIntervalSince1970)") {
            restoringCalendarScroll = true
            let saved = scrollDay
            await Task.yield()
            if mode == .agenda, !saved.isEmpty { proxy.scrollTo(saved, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { restoringCalendarScroll = false }
        }
        }
    }



    @ViewBuilder
    private var calendarToolbar: some View {
        if !repository.eventSaveStatus.isEmpty {
            HStack {
                Text(repository.eventSaveStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if repository.previousEventEdit != nil || !repository.previousEventBatchIDs.isEmpty {
                    Button("Undo") { Task { await repository.undoEventEdit() } }.font(.caption)
                }
            }
        }
        if workspace.showWeekNumbers { Text("Week \(calendar.component(.weekOfYear, from: selectedDate))").font(.caption).foregroundStyle(.secondary) }
        // Month uses the system calendar, which has its own month header and arrows.
        if isCompactHeight {
            HStack(spacing: 10) {
                calendarModePicker
                    .frame(maxWidth: 300)
                if mode != .month { calendarNavigationControls }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                calendarModePicker
                if mode != .month { calendarNavigationControls }
            }
        }
    }

    private var calendarModePicker: some View {
        Picker("Calendar View", selection: Binding(get: { mode }, set: { mode = $0 })) {
            ForEach(CalendarMode.pickerCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private func apply(_ context: SavedCalendarContext) {
        savedMode = context.mode
        repository.selectedEventCalendarIDs = context.calendarIDs
        visibleListIDs = context.listIDs
        overridesGlobalSearch = true
        localQuery = context.query
        useDateRange = context.start != nil
        if let start = context.start { filterStart = start; selectedDate = start }
        if let end = context.end { filterEnd = end }
        scrollDay = ""
    }

    private var calendarNavigationControls: some View {
        HStack(spacing: isCompactHeight ? 8 : 10) {
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous \(mode.rawValue.lowercased())")

            Spacer(minLength: 4)

            Button { showCommand = true } label: { Text(periodTitle).foregroundStyle(.primary) }
            Button("Check Conflicts", systemImage: "calendar.badge.exclamationmark") { showConflictChecker = true }.labelStyle(.iconOnly)
                .accessibilityLabel("Jump to date. " + periodTitle)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 4)

            Button {
                moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next \(mode.rawValue.lowercased())")
        }
    }

    private var dayView: some View {
        SelectedDayAgendaView(
            date: selectedDate,
            tasks: tasks(on: selectedDate),
            events: events(on: selectedDate),
            repository: repository,
            editorDraft: $editorDraft,
            selectedCalendarEvent: $selectedCalendarEvent,
            listColor: listColor,
            eventColor: eventColor(for:)
        )
    }

    private var weekView: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 10 : 18) {
            MiniWeekStrip(
                dates: weekDates,
                selectedDate: Binding(get: { selectedDate }, set: { selectedDate = $0 }),
                markers: calendarMarkers(on:)
            )
            .padding(.horizontal, 16)

            SelectedDayAgendaView(
                date: selectedDate,
                tasks: tasks(on: selectedDate),
                events: events(on: selectedDate),
                repository: repository,
                editorDraft: $editorDraft,
                selectedCalendarEvent: $selectedCalendarEvent,
                listColor: listColor,
                eventColor: eventColor(for:)
            )
            .padding(.horizontal, 16)
        }
    }

    private var monthView: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 10 : 18) {
            NativeMonthCalendar(
                selectedDate: Binding(get: { selectedDate }, set: { selectedDate = $0 }),
                markers: calendarMarkers(on:),
                contentVersion: repository.calendarEvents.count &+ repository.tasks.count &* 31
            )
            .padding(.horizontal, 8)

            SelectedDayAgendaView(
                date: selectedDate,
                tasks: tasks(on: selectedDate),
                events: events(on: selectedDate),
                repository: repository,
                editorDraft: $editorDraft,
                selectedCalendarEvent: $selectedCalendarEvent,
                listColor: listColor,
                eventColor: eventColor(for:)
            )
            .padding(.horizontal, 16)
        }
    }

    private var agendaView: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 10 : 14) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(agendaDays) { day in
                    if !day.tasks.isEmpty || !day.events.isEmpty {
                        AgendaDaySection(
                            day: day,
                            repository: repository,
                            listColor: listColor,
                            editorDraft: $editorDraft,
                            selectedCalendarEvent: $selectedCalendarEvent
                        )
                        .id(String(day.date.timeIntervalSince1970))
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: TaskScrollOffsets.self, value: [String(day.date.timeIntervalSince1970): geometry.frame(in: .named("calendar-scroll")).minY])
                            }
                        }
                    }
                }

                if agendaDays.allSatisfy({ $0.tasks.isEmpty && $0.events.isEmpty }) {
                    ContentUnavailableView {
                        Label("No Scheduled Items", systemImage: "calendar")
                    } description: {
                        Text("Events and dated tasks matching your calendars and filters appear here.")
                    } actions: {
                        Button("Review Filters") { showFilters = true }
                        Button("Create Event") { eventDraft = repository.makeEventDraft(on: selectedDate) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var rootTasks: [TaskItem] {
        let source = repository.isFocusModeEnabled ? repository.focusTasks : repository.tasks
        return source.filter { task in
            task.parentID == nil && !task.isCompleted &&
            (visibleListIDs.isEmpty || visibleListIDs.contains(task.listID)) &&
            matches([task.title, task.notes, task.tags.joined(separator: " "), repository.lists.first { $0.id == task.listID }?.title ?? ""] + task.comments.map(\.text))
        }
    }

    private var periodTitle: String {
        switch mode {
        case .day, .timeline:
            return selectedDate.formatted(date: .complete, time: .omitted)
        case .week:
            guard let first = weekDates.first, let last = weekDates.last else {
                return selectedDate.formatted(date: .abbreviated, time: .omitted)
            }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) - \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .month:
            return selectedDate.formatted(.dateTime.month(.wide).year())
        case .agenda:
            guard let first = agendaDays.first?.date, let last = agendaDays.last?.date else {
                return "Agenda"
            }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) - \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
    }

    private var weekDates: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return [selectedDate]
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var monthDates: [Date] {
        guard
            let monthInterval = calendar.dateInterval(of: .month, for: selectedDate),
            let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else {
            return []
        }

        let lastMonthDay = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthInterval.start) ?? monthInterval.start
        let lastWeek = calendar.dateInterval(of: .weekOfMonth, for: lastMonthDay)
        let end = lastWeek?.end ?? monthInterval.end
        var dates: [Date] = []
        var date = firstWeek.start

        while date < end {
            dates.append(date)
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = nextDate
        }

        return dates
    }

    private var agendaDays: [AgendaDay] {
        let count = useDateRange ? max(1, min(93, (calendar.dateComponents([.day], from: calendar.startOfDay(for: filterStart), to: calendar.startOfDay(for: filterEnd)).day ?? 0) + 1)) : 7
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: selectedDate)) else { return nil }
            return AgendaDay(
                date: date,
                tasks: tasks(on: date),
                events: events(on: date)
            )
        }
    }

    private var selectedAgendaDay: AgendaDay {
        AgendaDay(
            date: selectedDate,
            tasks: tasks(on: selectedDate),
            events: events(on: selectedDate)
        )
    }

    private var nextEvent: CalendarEvent? {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let lowerBound = calendar.isDateInToday(selectedDate) ? Date() : dayStart

        return repository.calendarEvents.filter { searchQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(searchQuery) }
            .filter { event in
                event.endDate >= lowerBound &&
                    calendar.isDate(event.startDate, inSameDayAs: selectedDate)
            }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    private func tasks(on date: Date) -> [TaskItem] {
        rootTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return inDateRange(dueDate) && calendar.isDate(dueDate, inSameDayAs: date) && (!task.hasDueTime || withinWorkingHours(start: dueDate, end: dueDate.addingTimeInterval(Double(max(1, task.durationMinutes ?? 30)) * 60)))
        }
        .sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func events(on date: Date) -> [CalendarEvent] {
        let dayInterval = calendar.dateInterval(of: .day, for: date)
        return calendarEventsForFocus.filter { event in
            guard let dayInterval, inDateRange(date) else { return false }
            if !event.isAllDay && !withinWorkingHours(start: max(event.startDate, dayInterval.start), end: event.endDate) { return false }
            return event.startDate < dayInterval.end && event.endDate > dayInterval.start
        }
    }

    private var calendarEventsForFocus: [CalendarEvent] {
        let source = repository.isFocusModeEnabled ? repository.nextFocusEvent.map { [$0] } ?? [] : repository.calendarEvents
        return source.filter { event in
            let linked = repository.tasks.filter { event.notes?.contains("TaskFlow linked task: \($0.id)") == true }
            return matches([event.title, event.location ?? "", event.notes ?? "", repository.eventCalendars.first { $0.id == event.calendarID }?.title ?? ""] + linked.map(\.title))
        }
    }

    private func eventColor(for calendarID: String) -> Color {
        repository.eventCalendars.first { $0.id == calendarID }?.color ?? .blue
    }

    private func calendarMarkers(on date: Date) -> [Color] {
        let eventMarkers = Array(events(on: date).prefix(3).map { eventColor(for: $0.calendarID) })
        let remainingSlots = max(0, 5 - eventMarkers.count)
        let taskMarkers = Array(tasks(on: date).prefix(remainingSlots).map { listColor($0.listID) })
        return eventMarkers + taskMarkers
    }

    private func busiestWindow(for day: AgendaDay) -> String {
        let items = day.items
        guard !items.isEmpty else { return "open" }

        let hourCounts = Dictionary(grouping: items) { item in
            calendar.component(.hour, from: item.startDate)
        }
        guard let busiestHour = hourCounts.max(by: { $0.value.count < $1.value.count })?.key else {
            return "open"
        }
        return "\(formattedHour(busiestHour))-\(formattedHour(busiestHour + 1))"
    }

    private func formattedHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        switch normalized {
        case 0: return "12a"
        case 1..<12: return "\(normalized)a"
        case 12: return "12p"
        default: return "\(normalized - 12)p"
        }
    }

    private func relatedTasks(before event: CalendarEvent) -> [TaskItem] {
        rootTasks
            .filter { task in
                guard !task.isCompleted, let dueDate = task.dueDate else { return false }
                return dueDate <= event.startDate && calendar.isDate(dueDate, inSameDayAs: event.startDate)
            }
            .sorted { lhs, rhs in
                (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
            .prefix(2)
            .map { $0 }
    }

    private func relatedNotes(for event: CalendarEvent) -> [QuickNote] {
        let eventTokens = Set(event.title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 3 })

        return repository.quickNotes
            .filter { note in
                if note.linkedEventID == event.id { return true }
                let noteText = "\(note.title) \(note.text)".lowercased()
                return eventTokens.contains { noteText.contains($0) || note.tags.contains($0) }
            }
            .prefix(2)
            .map { $0 }
    }

    private var commandSheet: some View {
        NavigationStack {
            List {
                Section("Navigate") {
                    DatePicker("Jump to date", selection: Binding(get: { selectedDate }, set: { selectedDate = $0; scrollDay = "" }), displayedComponents: .date)
                    Button("Go to Today") { selectedDate = Date(); scrollDay = ""; showCommand = false }
                    ForEach(CalendarMode.allCases) { value in Button(value.rawValue) { mode = value; showCommand = false } }
                }
                Section("Create") {
                    Button("Create Event / Time Block") { showCommand = false; eventDraft = repository.makeEventDraft(on: selectedDate) }
                    Button("Conflict Checker", systemImage: "calendar.badge.exclamationmark") { showCommand = false; showConflictChecker = true }
                    Button("Find Time for a Task") { showCommand = false; showPlanner = true }
                }
                Section("Events") {
                    ForEach(calendarEventsForFocus.filter { inDateRange($0.startDate) }.prefix(50), id: \.occurrenceKey) { event in
                        Button { showCommand = false; selectedCalendarEvent = event } label: {
                            VStack(alignment: .leading) {
                                Text(event.title)
                                Text(event.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $localQuery, prompt: "Events, notes, calendars, linked tasks")
            .taskFlowThemedBackground()
            .navigationTitle("Calendar Commands")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCommand = false } } }
        }
    }

    private var filtersSheet: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    TextField("Titles, notes, lists, tags", text: $localQuery)
                    Toggle("Date range", isOn: $useDateRange)
                    if useDateRange {
                        DatePicker("From", selection: $filterStart, displayedComponents: .date)
                        DatePicker("Through", selection: $filterEnd, in: filterStart..., displayedComponents: .date)
                        Button("Show Date Range") { selectedDate = filterStart; scrollDay = ""; showFilters = false }
                    }
                    Button("Clear Filters") { overridesGlobalSearch = true; localQuery = ""; useDateRange = false; visibleListIDs = []; workspace.hideNonworkingHours = false }
                }
                Section("Calendars") {
                    ForEach(repository.eventCalendars) { item in
                        Toggle(item.title, isOn: Binding(get: { repository.selectedEventCalendarIDs.contains(item.id) }, set: { enabled in
                            if enabled { repository.selectedEventCalendarIDs.insert(item.id) } else { repository.selectedEventCalendarIDs.remove(item.id) }
                        }))
                    }
                }
                Section("Task lists · none selected shows all") {
                    ForEach(repository.lists) { item in
                        Toggle(item.title, isOn: Binding(get: { visibleListIDs.contains(item.id) }, set: { enabled in
                            if enabled { visibleListIDs.insert(item.id) } else { visibleListIDs.remove(item.id) }
                        }))
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Calendar Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilters = false } } }
            .onChange(of: filterStart) { _, value in filterEnd = max(value, filterEnd) }
        }
    }

    private func moveSelection(by amount: Int) {
        let component: Calendar.Component
        switch mode {
        case .day, .timeline:
            component = .day
        case .week, .agenda:
            component = .weekOfYear
        case .month:
            component = .month
        }
        selectedDate = calendar.date(byAdding: component, value: amount, to: selectedDate) ?? selectedDate
    }
}

private struct MiniWeekStrip: View {
    let dates: [Date]
    @Binding var selectedDate: Date
    let markers: (Date) -> [Color]

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(dates, id: \.self) { date in
                    MiniCalendarDayCell(
                        date: date,
                        isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                        isCurrentMonth: true,
                        markers: markers(date),
                        style: .week
                    )
                    .frame(width: 92)
                    .onTapGesture {
                        selectedDate = date
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
    }
}

private struct MiniCalendarDayCell: View {
    enum Style {
        case week
        case month
    }

    let date: Date
    let isSelected: Bool
    let isCurrentMonth: Bool
    let markers: [Color]
    let style: Style

    private let calendar = Calendar.current
    /// Grows with Dynamic Type so large text sizes don't clip the day number.
    @ScaledMetric(relativeTo: .title2) private var circleSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 6) {
            if style == .week {
                Text(date.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(date.formatted(.dateTime.day()))
                .font(.title3.weight(isSelected || calendar.isDateInToday(date) ? .semibold : .regular))
                .foregroundStyle(dayForeground)
                .frame(width: circleSize, height: circleSize)
                .background {
                    if isSelected {
                        Circle().fill(calendar.isDateInToday(date) ? Color.red : Color.primary)
                    }
                }

            HStack(spacing: 3) {
                ForEach(Array(markers.prefix(3).enumerated()), id: \.offset) { _, color in
                    Circle().fill(color).frame(width: 5, height: 5)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .opacity(isCurrentMonth ? 1 : 0.38)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Matches Apple Calendar: today is red, the selected day is a filled circle.
    private var dayForeground: Color {
        if isSelected { return Color(uiColor: .systemBackground) }
        if calendar.isDateInToday(date) { return .red }
        return isCurrentMonth ? .primary : .secondary
    }

    private var accessibilityText: String {
        var text = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if calendar.isDateInToday(date) { text = "Today, " + text }
        if !markers.isEmpty { text += ", \(markers.count) item\(markers.count == 1 ? "" : "s")" }
        return text
    }
}

private struct SelectedDayAgendaView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let date: Date
    let tasks: [TaskItem]
    let events: [CalendarEvent]
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @Binding var selectedCalendarEvent: CalendarEvent?
    let listColor: (String) -> Color
    let eventColor: (String) -> Color

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 8 : 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayHeader)
                    .font(.headline)
                    .foregroundStyle(calendar.isDateInToday(date) ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer()

                Text("\(events.count + tasks.count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
            }

            if events.isEmpty && tasks.isEmpty {
                Button {
                    var draft = repository.makeDraft()
                    draft.dueDate = calendar.startOfDay(for: date)
                    draft.hasDueTime = false
                    editorDraft = draft
                } label: {
                    Label("Add Task", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.bordered)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sortedEvents) { event in
                        SelectedDayEventRow(event: event, color: eventColor(event.calendarID))
                            .contextMenu {
                                if repository.writableEventCalendars.contains(where: { $0.id == event.calendarID }) {
                                    ForEach(repository.availabilityOptions(for: event.calendarID)) { value in
                                        Button("Show As " + value.rawValue, systemImage: event.availability == value.rawValue ? "checkmark" : "circle") {
                                            Task { await repository.setEventAvailability(value, for: event) }
                                        }
                                    }
                                }
                            }
                            .onTapGesture {
                                repository.selectedTaskID = nil
                                selectedCalendarEvent = event
                            }
                    }

                    ForEach(tasks) { task in
                        SelectedDayTaskRow(
                            task: task,
                            color: listColor(task.listID),
                            tagColor: repository.color(forTag:),
                            repository: repository,
                            editorDraft: $editorDraft
                        )
                    }
                }
                .background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
            }
        }
    }

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    private var sortedEvents: [CalendarEvent] {
        events.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay {
                return lhs.isAllDay
            }
            return lhs.startDate < rhs.startDate
        }
    }

    private var dayHeader: String {
        let dateText = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if calendar.isDateInToday(date) {
            return "Today · \(dateText)"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow · \(dateText)"
        }
        return dateText
    }
}

private struct SelectedDayEventRow: View {
    let event: CalendarEvent
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 5, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

            }

            Spacer(minLength: 8)

            Text(timeText)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 26)
        }
    }

    private var timeText: String {
        if event.isAllDay {
            return "all-day"
        }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened))\n\(event.endDate.formatted(date: .omitted, time: .shortened))"
    }

}

private struct SelectedDayTaskRow: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let task: TaskItem
    let color: Color
    let tagColor: (String) -> Color
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await repository.toggleCompletion(for: task) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(task.isCompleted ? Color.green : color)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(taskTimeText)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(timeColor)

                    if task.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(task.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                    .strikethrough(task.isCompleted)
                    .lineLimit(2)

                if !task.tags.isEmpty {
                    TagCloud(tags: Array(task.tags.prefix(3)), colorForTag: tagColor)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            selectTask()
        }
        .contextMenu {
            CalendarTaskMenu(task: task, repository: repository)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 34)
        }
    }

    private var taskTimeText: String {
        guard let dueDate = task.dueDate else { return "Task" }
        if task.hasDueTime {
            return dueDate.formatted(date: .omitted, time: .shortened)
        }
        return dueDate.formatted(.dateTime.month(.abbreviated).day())
    }

    private var timeColor: Color {
        task.status == .overdue ? .red : .secondary
    }

    private func selectTask() {
        repository.selectTask(task)
    }
}

/// Creates and edits events with Apple's own Calendar editor (`EKEventEditViewController`).
private struct EventAvailabilityControl: View {
    let options: [EventAvailability]
    let value: String
    var isSaving = false
    let onSelect: (EventAvailability) -> Void

    var body: some View {
        HStack {
            ForEach(options.filter { $0 == .busy || $0 == .free }) { option in
                Button { onSelect(option) } label: {
                    Label(option.rawValue, systemImage: value == option.rawValue ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(option == .free ? .green : .blue)
                .accessibilityAddTraits(value == option.rawValue ? .isSelected : [])
            }
            let others = options.filter { $0 != .busy && $0 != .free }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { option in
                        Button(option.rawValue, systemImage: value == option.rawValue ? "checkmark" : "circle") { onSelect(option) }
                    }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("More availability options, currently " + value)
            }
            if isSaving { ProgressView().controlSize(.small) }
        }
        .disabled(isSaving)
    }
}

struct CalendarEventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @State private var draft: EventDraft
    private let originalStart: Date
    @State private var conflicts: [CalendarEvent] = []
    @State private var showsConflictConfirmation = false
    @State private var showsSystemEditor = false
    @State private var pendingSystemOutcome: SystemEventEditorOutcome?
    @State private var isSaving = false
    @State private var saveError: String?

    init(repository: TaskRepository, draft: EventDraft) {
        self.repository = repository
        _draft = State(initialValue: draft)
        originalStart = draft.startDate
    }

    var body: some View {
        NavigationStack {
            Group {
            if repository.eventAccessState == .granted {
                Form {
                    Section {
                        TextField("Event title", text: $draft.title)
                        Picker("Calendar", selection: $draft.calendarID) {
                            ForEach(repository.writableEventCalendars) { calendar in
                                Text(calendar.title).tag(calendar.id)
                            }
                        }
                        Toggle("All Day", isOn: $draft.isAllDay)
                        DatePicker("Starts", selection: $draft.startDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        DatePicker("Ends", selection: $draft.endDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                    let options = repository.availabilityOptions(for: draft.calendarID)
                    if !options.isEmpty {
                        Section {
                            EventAvailabilityControl(options: options, value: draft.availability) { draft.availability = $0.rawValue }
                        } header: { Text("Show As · " + draft.availability) } footer: { Text("Busy, Tentative and Unavailable block time. Free does not.") }
                    }
                    Section {
                        if draft.endDate < draft.startDate || (!draft.isAllDay && draft.endDate == draft.startDate) {
                            Label("End time must be after start time", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else if conflicts.isEmpty {
                            Label(!repository.calendarAffectsAvailability(draft.calendarID) ? "This calendar does not affect availability" : draft.availability == "Free" ? "Free events do not block time" : "No overlapping busy events", systemImage: "checkmark.circle").foregroundStyle(.green)
                        } else {
                            Label("\(conflicts.count) overlapping event\(conflicts.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            ForEach(conflicts, id: \.occurrenceKey) { event in
                                VStack(alignment: .leading) {
                                    Text(event.title).font(.headline)
                                    Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + event.endDate.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Text(repository.eventCalendars.first { $0.id == event.calendarID }?.title ?? "Calendar").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("Conflict Check") } footer: { Text("Checks calendars enabled under Settings → Calendars → Affects Availability, including hidden calendars. Invitee availability is not included.") }
                    Section {
                        TextField("Location", text: $draft.location)
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                        Button("More Event Options", systemImage: "slider.horizontal.3") { showsSystemEditor = true }
                    } footer: { Text("Use the system editor for alerts, repeat settings and other calendar options.") }
                }
                .disabled(isSaving)
                .taskFlowThemedBackground()
                .onAppear {
                    let options = repository.availabilityOptions(for: draft.calendarID)
                    if !options.isEmpty && !options.contains(where: { $0.rawValue == draft.availability }) { draft.availability = options.first?.rawValue ?? "Busy" }
                    checkConflicts()
                }
                .onChange(of: draft.location) { _, _ in draft.structuredLocation = nil }
                .onChange(of: conflictQueryKey) { _, _ in checkConflicts() }
                .onChange(of: draft.calendarID) { _, id in
                    let options = repository.availabilityOptions(for: id)
                    if !options.contains(where: { $0.rawValue == draft.availability }) { draft.availability = options.first?.rawValue ?? "Busy" }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            checkConflicts()
                            if conflicts.isEmpty { save() } else { showsConflictConfirmation = true }
                        }
                        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.endDate < draft.startDate || (!draft.isAllDay && draft.endDate == draft.startDate))
                    }
                }
                .confirmationDialog("This event overlaps \(conflicts.count) other event\(conflicts.count == 1 ? "" : "s").", isPresented: $showsConflictConfirmation, titleVisibility: .visible) {
                    Button("Save Anyway") { save() }
                    Button("Keep Editing", role: .cancel) {}
                }
                .sheet(isPresented: $showsSystemEditor, onDismiss: completeSystemEditor) {
                    SystemEventEditor(store: repository.eventStore, event: repository.systemEvent(for: draft), originalStart: originalStart) { outcome in
                        pendingSystemOutcome = outcome
                        showsSystemEditor = false
                    }.ignoresSafeArea()
                }
            } else {
                ContentUnavailableView {
                    Label("Calendar Access Needed", systemImage: "calendar.badge.exclamationmark")
                } description: { Text(repository.eventAccessState.message) } actions: {
                    if repository.eventAccessState == .unknown {
                        Button("Allow Calendar Access") { Task { await repository.requestEventCalendarAccess() } }.buttonStyle(.borderedProminent)
                    }
                }
            }
            }
        .navigationTitle(draft.eventID == nil ? "New Event" : "Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) } }
        .alert("Could Not Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        }
    }

    private func completeSystemEditor() {
        guard let outcome = pendingSystemOutcome else { return }
        pendingSystemOutcome = nil
        switch outcome {
        case .canceled: break
        case .saved(let id):
            dismiss()
            Task { await repository.systemEventEditorDidFinish(savedEventID: id, tags: draft.tags) }
        case .deleted(let deletion):
            dismiss()
            Task { await repository.eventDeletionDidComplete(deletion) }
        }
    }

    private var conflictQueryKey: String { "\(draft.startDate.timeIntervalSince1970)|\(draft.endDate.timeIntervalSince1970)|\(draft.isAllDay)|\(draft.calendarID)|\(draft.availability)|\(repository.excludedAvailabilityCalendarIDs.sorted())" }
    private func checkConflicts() { conflicts = repository.eventConflicts(for: draft, originalStart: originalStart) }
    private func save() {
        isSaving = true
        Task {
            if await repository.saveEvent(draft) { dismiss() }
            else { saveError = repository.eventSaveStatus }
            isSaving = false
        }
    }
}

private struct SystemEventEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    let event: EKEvent
    let originalStart: Date
    let onFinish: (SystemEventEditorOutcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(eventID: event.eventIdentifier ?? event.calendarItemIdentifier, originalStart: originalStart, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let eventID: String
        let originalStart: Date
        let onFinish: (SystemEventEditorOutcome) -> Void
        private var didFinish = false
        init(eventID: String, originalStart: Date, onFinish: @escaping (SystemEventEditorOutcome) -> Void) {
            self.eventID = eventID; self.originalStart = originalStart; self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            guard !didFinish else { return }
            didFinish = true
            // The event was prefilled from TaskFlow's draft; discard those unsaved edits so the shared store stays clean.
            if action == .canceled { controller.event?.rollback() }
            switch action {
            case .canceled: onFinish(.canceled)
            case .saved: onFinish(.saved(controller.event?.eventIdentifier))
            case .deleted: onFinish(.deleted(EventDeletion(eventID: eventID, startDate: originalStart, scope: .thisEvent)))
            @unknown default: onFinish(.canceled)
            }
        }
    }
}

struct CalendarEventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var repository: TaskRepository
    let event: CalendarEvent
    let color: Color
    @State private var editDraft: EventDraft?
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var dismissAfterEditor = false
    @State private var showsAlternateTimes = false
    @State private var isEventActivityActive = false
    @State private var eventActivityError: String?
    @State private var isSavingAvailability = false
    @State private var availabilityError: String?
    @State private var detailConflicts: [CalendarEvent] = []
    @State private var localAvailability: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentEvent.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        if let location = currentEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                            Text(location).foregroundStyle(.secondary)
                        }
                        Text(dateText).padding(.top, 6)
                        Text(currentEvent.isAllDay ? "All day" : "\(timeText) (\(durationText))")
                            .foregroundStyle(.secondary)
                        if let recurrence = currentEvent.recurrenceSummary {
                            Text(recurrence).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if supportsAvailability {
                    Section("Show As · " + (currentEvent.availability ?? "Busy")) {
                        if canEdit {
                            EventAvailabilityControl(options: repository.availabilityOptions(for: currentEvent.calendarID), value: currentEvent.availability ?? "Busy", isSaving: isSavingAvailability) { updateAvailability($0.rawValue) }
                        } else { Text(currentEvent.availability ?? "Busy") }
                    }
                }
                Section {
                    if detailConflicts.isEmpty {
                        Label(!repository.calendarAffectsAvailability(currentEvent.calendarID) ? "This calendar does not affect availability" : currentEvent.availability == "Free" ? "Free events do not block time" : "No overlapping busy events", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        ForEach(detailConflicts, id: \.occurrenceKey) { item in
                            VStack(alignment: .leading) {
                                Label(item.title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text(item.isAllDay ? "All day" : item.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + item.endDate.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if canEdit { Button("Change Event Time", systemImage: "calendar.badge.clock") { editDraft = EventDraft(event: currentEvent) } }
                    }
                } header: { Text("Conflict Check") } footer: { Text("Checks overlapping events on calendars enabled under Settings → Calendars → Affects Availability.") }

                if let meeting = currentEvent.onlineMeeting {
                    Section {
                        Button(meeting.provider.buttonTitle, systemImage: meeting.provider.icon) { joinMeeting(meeting) }
                    }
                }

                Section {
                    LabeledContent("Calendar") {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 10, height: 10)
                            Text(calendarTitle)
                        }
                    }
                    if let source = currentEvent.calendarSource { LabeledContent("Account", value: source) }
                    LabeledContent("Time Zone", value: currentEvent.timeZoneIdentifier ?? TimeZone.current.identifier)
                }

                if let location = currentEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                    Section("Location") {
                        Button {
                            openLocation(location)
                        } label: {
                            Label(location, systemImage: "map")
                        }
                        .accessibilityHint("Opens directions in Maps")
                    }
                }

                if let url = currentEvent.url {
                    Section("URL") {
                        Link(destination: url) { Label(url.host ?? url.absoluteString, systemImage: "safari").lineLimit(1) }
                    }
                }

                if let notes = currentEvent.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Section("Notes") {
                        Text(notes).textSelection(.enabled)
                    }
                }

                if !currentEvent.attendees.isEmpty || currentEvent.organizerName != nil {
                    Section("Invitees") {
                        if let organizer = currentEvent.organizerName {
                            LabeledContent(organizer, value: "Organizer")
                        }
                        ForEach(currentEvent.attendees) { attendee in
                            LabeledContent {
                                Text(attendee.status)
                            } label: {
                                Text(attendee.name)
                                if !attendee.email.isEmpty { Text(attendee.email) }
                            }
                        }
                        Button("Find Alternate Times", systemImage: "calendar.badge.clock") { showsAlternateTimes = true }
                    }
                }

                let linkedTasks = repository.tasks.filter { currentEvent.notes?.contains("TaskFlow linked task: \($0.id)") == true }
                if !linkedTasks.isEmpty {
                    Section("Linked Tasks") {
                        ForEach(linkedTasks) { task in
                            Button { repository.openTask(id: task.id); dismiss() } label: { Label(task.title, systemImage: "checklist") }
                        }
                    }
                }

                if !currentEvent.id.isEmpty {
                    Section("Tags") {
                        TagSelectionEditor(
                            savedTags: repository.savedTags,
                            selectedTags: Binding(
                                get: { currentEvent.tags },
                                set: { tags in Task { await repository.setEventTags(tags, for: currentEvent.id) } }
                            ),
                            colorForTag: repository.color(forTag:),
                            onCreate: repository.saveTag
                        )
                    }
                }

                if canOfferEventActivity {
                    Section {
                        Toggle("Lock Screen Countdown", isOn: Binding(
                            get: { isEventActivityActive },
                            set: { _ in Task { await toggleEventActivity() } }
                        ))
                    } footer: {
                        Text("Shows this event\u{2019}s countdown on the Lock Screen and in the Dynamic Island.")
                    }
                }
                if canEdit {
                    Section {
                        Button("Delete Event", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
                    }
                }
            }
            .disabled(isDeleting)
            .overlay { if isDeleting { ProgressView("Deleting event…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .listStyle(.insetGrouped)
            .taskFlowThemedBackground()
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isEventActivityActive = EventLiveActivityCoordinator.isActive(eventID: currentEvent.id)
                detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            }
            .alert("Could Not Update Availability", isPresented: Binding(get: { availabilityError != nil }, set: { if !$0 { availabilityError = nil } })) {
                Button("OK", role: .cancel) { availabilityError = nil }
            } message: { Text(availabilityError ?? "") }
            .onChange(of: repository.excludedAvailabilityCalendarIDs) { _, _ in
                detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            }
            .onChange(of: repository.calendarEvents) { _, _ in
                isEventActivityActive = EventLiveActivityCoordinator.isActive(eventID: currentEvent.id)
                detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            }
            .alert("Live Activity", isPresented: Binding(get: { eventActivityError != nil }, set: { if !$0 { eventActivityError = nil } })) {
                Button("OK", role: .cancel) { eventActivityError = nil }
            } message: {
                Text(eventActivityError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(isDeleting)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share event")
                    if canEdit {
                        Button("Edit") { editDraft = EventDraft(event: currentEvent) }.disabled(isDeleting)
                    }
                }
            }
            .confirmationDialog("Delete \(currentEvent.title)?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button(isRecurring ? "Delete This Event Only" : "Delete Event", role: .destructive) { delete(.thisEvent) }
                if isRecurring { Button("Delete This and Future Events", role: .destructive) { delete(.thisAndFuture) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isRecurring ? "Choose whether to delete this occurrence or this occurrence and all future events in the series. This change syncs with your calendar account." : "This removes the event from its calendar and synced devices.")
            }
            .alert("Could Not Delete Event", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                Button("Try Again") { deletionError = nil; confirmsDeletion = true }
                Button("Cancel", role: .cancel) { deletionError = nil }
            } message: { Text(deletionError ?? "") }
            .onChange(of: repository.lastEventDeletion) { _, deletion in
                guard let deletion, deletion.includes(event) else { return }
                if editDraft != nil { dismissAfterEditor = true; editDraft = nil }
                else { dismiss() }
            }
            .sheet(item: $editDraft, onDismiss: {
                if dismissAfterEditor { dismissAfterEditor = false; dismiss() }
            }) { draft in
                CalendarEventEditorView(repository: repository, draft: draft)
            }
            .sheet(isPresented: $showsAlternateTimes) {
                EventAvailabilitySuggestions(repository: repository, event: currentEvent, accent: color)
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private var isRecurring: Bool { currentEvent.recurrence != nil || currentEvent.recurrenceSummary != nil }
    private func delete(_ scope: EventDeletionScope) {
        guard !isDeleting else { return }
        let selected = currentEvent
        isDeleting = true
        Task {
            if !(await repository.deleteCalendarEvent(selected, scope: scope)) { deletionError = repository.eventSaveStatus }
            isDeleting = false
        }
    }

    private var canOfferEventActivity: Bool {
        !currentEvent.isAllDay && currentEvent.endDate > Date() && currentEvent.startDate < Date().addingTimeInterval(8 * 60 * 60)
    }

    @MainActor
    private func toggleEventActivity() async {
        if isEventActivityActive {
            await EventLiveActivityCoordinator.end(eventID: currentEvent.id)
            isEventActivityActive = false
            return
        }
        do {
            try await EventLiveActivityCoordinator.start(eventID: currentEvent.id, title: currentEvent.title,
                                                         calendarTitle: calendarTitle, location: currentEvent.location,
                                                         startDate: currentEvent.startDate, endDate: currentEvent.endDate)
            isEventActivityActive = true
        } catch {
            eventActivityError = error.localizedDescription
        }
    }

    private func updateAvailability(_ newAvailability: String) {
        guard let value = EventAvailability(rawValue: newAvailability), newAvailability != currentEvent.availability else { return }
        isSavingAvailability = true
        Task {
            if await repository.setEventAvailability(value, for: currentEvent) { localAvailability = value.rawValue }
            else { availabilityError = repository.eventSaveStatus }
            detailConflicts = repository.eventConflicts(for: EventDraft(event: currentEvent))
            isSavingAvailability = false
        }
    }

    private var supportsAvailability: Bool {
        repository.eventCalendars.first(where: { $0.id == currentEvent.calendarID })?.supportsAvailability ?? (currentEvent.availability != nil)
    }

    private var currentEvent: CalendarEvent {
        if let cached = repository.calendarEvents.first(where: { $0.id == event.id && $0.startDate == event.startDate }) { return cached }
        var fallback = event
        if let localAvailability { fallback.availability = localAvailability }
        return fallback
    }

    private var calendarTitle: String {
        repository.eventCalendars.first { $0.id == currentEvent.calendarID }?.title ?? "Calendar"
    }

    private var canEdit: Bool {
        repository.eventAccessState == .granted && repository.writableEventCalendars.contains { $0.id == currentEvent.calendarID }
    }

    private var dateText: String {
        // EventKit uses an exclusive midnight end date for all-day events.
        let displayEnd = currentEvent.isAllDay ? max(currentEvent.startDate, currentEvent.endDate.addingTimeInterval(-1)) : currentEvent.endDate
        if Calendar.current.isDate(currentEvent.startDate, inSameDayAs: displayEnd) {
            return currentEvent.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
        return "\(currentEvent.startDate.formatted(date: .abbreviated, time: .omitted)) – \(displayEnd.formatted(date: .abbreviated, time: .omitted))"
    }

    private var timeText: String {
        currentEvent.isAllDay ? "All day" : "\(currentEvent.startDate.formatted(date: .omitted, time: .shortened)) – \(currentEvent.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private var durationText: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: currentEvent.startDate, to: currentEvent.endDate)
        if let hour = components.hour, let minute = components.minute {
            if hour == 0 { return "\(minute) min" }
            if minute == 0 { return "\(hour) hr" }
            return "\(hour) hr \(minute) min"
        }
        return ""
    }

    private var shareText: String {
        [currentEvent.title, dateText, timeText, currentEvent.location].compactMap { $0 }.joined(separator: "\n")
    }

    private func openLocation(_ location: String) {
        if let url = MapNavigation.url(for: location) { openURL(url) }
    }

    private func joinMeeting(_ meeting: OnlineMeetingInfo) {
        guard let appURL = meeting.appURL else { openURL(meeting.url); return }
        openURL(appURL) { accepted in if !accepted { openURL(meeting.url) } }
    }
}

private struct CalendarTaskMenu: View {
    let task: TaskItem
    @Bindable var repository: TaskRepository

    var body: some View {
        ShareLink(item: task.shareText) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Button {
            repository.selectTask(task)
        } label: {
            Label("View Details", systemImage: "sidebar.right")
        }

        Button {
            Task { await repository.toggleCompletion(for: task) }
        } label: {
            Label(task.isCompleted ? "Reopen" : "Done", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark")
        }

        Section("Smart Reschedule") {
            ForEach(SmartRescheduleOption.allCases) { option in
                Button {
                    Task { await repository.smartReschedule(task, option: option) }
                } label: {
                    Label(option.rawValue, systemImage: option.icon)
                }
            }
        }

        Button(role: .destructive) {
            Task { await repository.deleteTask(task) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct AgendaView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @Binding var selectedCalendarEvent: CalendarEvent?
    let title: String
    let accentColor: Color
    let upcomingCount: Int
    let attachmentCount: Int
    let listColor: (String) -> Color

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if agendaDays.allSatisfy({ $0.tasks.isEmpty && $0.events.isEmpty }) {
                    EmptyTaskStateView(repository: repository, editorDraft: $editorDraft)
                        .padding(.horizontal, 16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(agendaDays) { day in
                            if !day.tasks.isEmpty || !day.events.isEmpty {
                                AgendaDaySection(
                                    day: day,
                                    repository: repository,
                                    listColor: listColor,
                                    editorDraft: $editorDraft,
                                    selectedCalendarEvent: $selectedCalendarEvent
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var agendaDays: [AgendaDay] {
        (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) else { return nil }
            return AgendaDay(
                date: date,
                tasks: tasks(on: date),
                events: events(on: date)
            )
        }
    }

    private var todayAgenda: AgendaDay {
        agendaDays.first ?? AgendaDay(date: Date(), tasks: [], events: [])
    }

    private var nextEvent: CalendarEvent? {
        let now = Date()
        return repository.filteredCalendarEvents
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    private func tasks(on date: Date) -> [TaskItem] {
        repository.rootTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: date)
        }
    }

    private func events(on date: Date) -> [CalendarEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return [] }
        return repository.filteredCalendarEvents.filter { $0.startDate < interval.end && $0.endDate > interval.start }
    }

    private func eventColor(for calendarID: String) -> Color {
        repository.eventCalendars.first { $0.id == calendarID }?.color ?? .blue
    }

    private func busiestWindow(for day: AgendaDay) -> String {
        let items = day.items
        guard !items.isEmpty else { return "open" }

        let hourCounts = Dictionary(grouping: items) { item in
            calendar.component(.hour, from: item.startDate)
        }
        guard let busiestHour = hourCounts.max(by: { $0.value.count < $1.value.count })?.key else {
            return "open"
        }
        return "\(formattedHour(busiestHour))-\(formattedHour(busiestHour + 1))"
    }

    private func formattedHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        switch normalized {
        case 0: return "12a"
        case 1..<12: return "\(normalized)a"
        case 12: return "12p"
        default: return "\(normalized - 12)p"
        }
    }

    private func relatedTasks(before event: CalendarEvent) -> [TaskItem] {
        repository.rootTasks
            .filter { task in
                guard !task.isCompleted, let dueDate = task.dueDate else { return false }
                return dueDate <= event.startDate && calendar.isDate(dueDate, inSameDayAs: event.startDate)
            }
            .sorted { lhs, rhs in
                (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
            .prefix(2)
            .map { $0 }
    }

    private func relatedNotes(for event: CalendarEvent) -> [QuickNote] {
        let eventTokens = Set(event.title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 3 })

        return repository.quickNotes
            .filter { note in
                if note.linkedEventID == event.id { return true }
                let noteText = "\(note.title) \(note.text)".lowercased()
                return eventTokens.contains { noteText.contains($0) || note.tags.contains($0) }
            }
            .prefix(2)
            .map { $0 }
    }

    private func suggestedTask(for gap: DayTimeGap) -> TaskItem? {
        repository.tasks
            .filter { task in
                !task.isCompleted &&
                    task.parentID == nil &&
                    (task.durationMinutes ?? 30) <= gap.minutes
            }
            .sorted { lhs, rhs in
                let lhsScore = (lhs.priority == .high ? 100 : 0) + (lhs.isFlagged ? 20 : 0) + (lhs.dueDate == nil ? 0 : 10)
                let rhsScore = (rhs.priority == .high ? 100 : 0) + (rhs.isFlagged ? 20 : 0) + (rhs.dueDate == nil ? 0 : 10)
                return lhsScore > rhsScore
            }
            .first
    }
}

private struct AgendaDay: Identifiable {
    var id: Date { date }
    let date: Date
    let tasks: [TaskItem]
    let events: [CalendarEvent]

    var items: [AgendaDayItem] {
        (events.map(AgendaDayItem.event) + tasks.map(AgendaDayItem.task))
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                return lhs.id < rhs.id
            }
    }
}

private enum AgendaDayItem: Identifiable {
    case task(TaskItem)
    case event(CalendarEvent)

    var id: String {
        switch self {
        case .task(let task): "task-\(task.id)"
        case .event(let event): "event-\(event.id)"
        }
    }

    var isAllDay: Bool {
        switch self {
        case .task(let task): !task.hasDueTime
        case .event(let event): event.isAllDay
        }
    }

    var startDate: Date {
        switch self {
        case .task(let task): task.dueDate ?? .distantFuture
        case .event(let event): event.startDate
        }
    }
}

private struct AgendaDaySection: View {
    let day: AgendaDay
    @Bindable var repository: TaskRepository
    let listColor: (String) -> Color
    @Binding var editorDraft: TaskDraft?
    @Binding var selectedCalendarEvent: CalendarEvent?
    @State private var completingIDs = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { dayTitle; dateLabel }
                    VStack(alignment: .leading, spacing: 2) { dayTitle; dateLabel }
                }
                Spacer(minLength: 4)
                Text(day.items.count, format: .number)
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, minHeight: 30)
                    .background(TaskFlowTheme.surface, in: Circle())
            }
            VStack(spacing: 0) {
                ForEach(day.items) { item in
                    if item.id == day.items.first(where: { $0.isAllDay == item.isAllDay })?.id {
                        Text(item.isAllDay ? "All day" : "Scheduled")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.top, 10)
                    }
                    agendaRow(item)
                    if item.id != day.items.last?.id {
                        Divider().padding(.leading, 26)
                    }
                }
            }
            .background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(TaskFlowTheme.border, lineWidth: 1)
            }
        }
        .padding(.bottom, 8)
    }

    private var dayTitle: some View {
        Text(Calendar.current.isDateInToday(day.date) ? "Today" : Calendar.current.isDateInTomorrow(day.date) ? "Tomorrow" : day.date.formatted(.dateTime.weekday(.wide)))
            .font(.title3.bold())
    }

    private var dateLabel: some View {
        Text(day.date.formatted(.dateTime.month(.abbreviated).day().year()))
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func agendaRow(_ item: AgendaDayItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if case .task(let task) = item {
                Button {
                    completingIDs.insert(task.id)
                    Task {
                        defer { completingIDs.remove(task.id) }
                        await repository.toggleCompletion(for: task)
                    }
                } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(accentColor(for: item))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(completingIDs.contains(task.id))
                .accessibilityLabel("Mark \(task.title) \(task.isCompleted ? "incomplete" : "complete")")
            }
            Button {
                switch item {
                case .task(let task): repository.selectTask(task)
                case .event(let event):
                    repository.selectedTaskID = nil
                    selectedCalendarEvent = event
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(itemTitle(item))
                        .font(.headline).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                detailLabel(item).fixedSize()
                                Spacer(minLength: 0)
                                badges(item, now: context.date).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                detailLabel(item)
                                badges(item, now: context.date)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.leading, 26)
        .padding(.trailing, 14)
        .overlay(alignment: .leading) {
            Capsule().fill(accentColor(for: item)).frame(width: 4)
                .padding(.vertical, 10).padding(.leading, 12)
        }
        .contextMenu {
            if case .task(let task) = item {
                CalendarTaskMenu(task: task, repository: repository)
            } else if case .event(let event) = item, repository.writableEventCalendars.contains(where: { $0.id == event.calendarID }) {
                ForEach(repository.availabilityOptions(for: event.calendarID)) { value in
                    Button("Show As " + value.rawValue, systemImage: event.availability == value.rawValue ? "checkmark" : "circle") {
                        Task { await repository.setEventAvailability(value, for: event) }
                    }
                }
            }
        }
    }

    private func detailLabel(_ item: AgendaDayItem) -> some View {
        Text(detail(item)).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func badges(_ item: AgendaDayItem, now: Date) -> some View {
        HStack(spacing: 6) {
            if case .event(let event) = item, let availability = event.availability {
                badge(availability, color: availability == "Free" ? .green : .red)
            }
            if let relative = relativeLabel(item, now: now) {
                badge(relative, color: relative == "Overdue" ? .red : .blue)
            }
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func itemTitle(_ item: AgendaDayItem) -> String {
        switch item {
        case .task(let task): task.title
        case .event(let event): event.title
        }
    }

    private func detail(_ item: AgendaDayItem) -> String {
        switch item {
        case .task(let task):
            let due = task.hasDueTime ? "Due " + (task.dueDate?.formatted(date: .omitted, time: .shortened) ?? "Anytime") : "Anytime"
            let list = repository.lists.first { $0.id == task.listID }?.title
            return [due, list, task.recurrence?.summary].compactMap { $0 }.joined(separator: " · ")
        case .event(let event):
            let time = event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened) + "–" + event.endDate.formatted(date: .omitted, time: .shortened)
            let calendar = repository.eventCalendars.first { $0.id == event.calendarID }?.title
            return [time, calendar].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func relativeLabel(_ item: AgendaDayItem, now: Date) -> String? {
        if case .task(let task) = item, !task.hasDueTime || task.isCompleted { return nil }
        if case .event(let event) = item {
            if event.isAllDay { return nil }
            if event.startDate <= now && event.endDate > now { return "In progress" }
            if event.endDate <= now { return nil }
        }
        let seconds = item.startDate.timeIntervalSince(now)
        if seconds < 0 { return "Overdue" }
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        if seconds < 86400 { return "in \(Int(seconds / 3600))h" }
        return "in \(Int(seconds / 86400))d"
    }

    private func accentColor(for item: AgendaDayItem) -> Color {
        switch item {
        case .task(let task): listColor(task.listID)
        case .event(let event): repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue
        }
    }
}

private enum PinnedTaskItem: Identifiable, Hashable {
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
        case .upNext: "Up Next"
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

private struct PinnedTaskCard: View {
    @Bindable var repository: TaskRepository
    let item: PinnedTaskItem

    private var count: Int { repository.taskCount(for: item.scope) }
    private var color: Color { item.color(theme: repository.appTheme) }
    private var subtitle: String {
        switch item {
        case .allTasks: "Everything in your lists"
        case .upNext: "Due in the next 14 days"
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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(count) tasks, \(subtitle)")
    }
}

private struct PinnedTaskListsEditor: View {
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

/// Standard toolbar filter menu, in the style of Mail and Files.
private struct TaskFilterMenu: View {
    @Bindable var repository: TaskRepository

    var body: some View {
        Menu {
            Picker("Status", selection: $repository.quickStatusFilter) {
                Text("Any Status").tag(Optional<TaskStatus>.none)
                ForEach(TaskStatus.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Picker("Priority", selection: $repository.quickPriorityFilter) {
                Text("Any Priority").tag(Optional<TaskPriority>.none)
                ForEach(TaskPriority.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Picker("Due", selection: $repository.quickDueFilter) {
                ForEach(TaskRepository.DueFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Tag", selection: $repository.quickTagFilter) {
                Text("Any Tag").tag(Optional<TaskRepository.TagFilter>.none)
                Text("No Tags").tag(Optional(TaskRepository.TagFilter.noTags))
                ForEach(repository.allTags, id: \.self) { Text("#\($0)").tag(Optional(TaskRepository.TagFilter.tag($0))) }
            }
            .pickerStyle(.menu)

            Section {
                Picker("Group By", selection: $repository.taskGroupOption) {
                    ForEach(TaskRepository.TaskGroupOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Sort By", selection: $repository.taskSortOption) {
                    ForEach(TaskRepository.TaskSortOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }

            if hasFilters {
                Section {
                    Button("Clear Filters", systemImage: "xmark.circle") { clearFilters() }
                }
            }
        } label: {
            Label("Filter", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(hasFilters ? "Filters, active" : "Filters")
    }

    private var hasFilters: Bool {
        repository.quickTagFilter != nil || repository.selectedTagFilter != nil ||
            repository.quickStatusFilter != nil || repository.quickPriorityFilter != nil ||
            repository.quickDueFilter != .any || repository.dueFilter != .any
    }

    private func clearFilters() {
        repository.clearQuickFilters()
        repository.selectedTagFilter = nil
        repository.dueFilter = .any
    }
}

private struct EmptyTaskStateView: View {
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                repository.accessState == .granted ? emptyTitle : "Reminders Access Needed",
                systemImage: repository.accessState == .granted ? emptyIcon : "lock.open",
                description: Text(repository.accessState == .granted ? emptyDescription : repository.accessState.message)
            )
            HStack(spacing: 10) {
                if repository.accessState == .unknown {
                    Button {
                        Task { await repository.requestAccess() }
                    } label: {
                        Label("Connect Reminders", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                } else if repository.accessState == .denied {
                    #if canImport(UIKit)
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    #endif
                } else if repository.accessState == .granted {
                    Button {
                        editorDraft = repository.makeDraft()
                    } label: {
                        Label("Create Task", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if hasFilters {
                    Button {
                        repository.clearQuickFilters()
                        repository.selectedTagFilter = nil
                        repository.dueFilter = .any
                        repository.searchQuery = ""
                    } label: {
                        Label("Clear Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var hasFilters: Bool {
        !repository.searchQuery.isEmpty || repository.selectedTagFilter != nil || repository.dueFilter != .any ||
        repository.quickTagFilter != nil ||
            repository.quickStatusFilter != nil ||
            repository.quickPriorityFilter != nil ||
            repository.quickDueFilter != .any
    }

    private var emptyTitle: String {
        hasFilters ? "No Matching Tasks" : "No Tasks"
    }

    private var emptyDescription: String {
        hasFilters ? "Try clearing filters or changing the current view." : "Create a task or adjust this view to start planning."
    }

    private var emptyIcon: String {
        hasFilters ? "line.3.horizontal.decrease.circle" : "checkmark.circle"
    }
}

struct TaskRowView: View {
    let task: TaskItem
    let subtasks: [TaskItem]
    let isSelected: Bool
    var isBulkTagging = false
    let listColor: Color
    let tagColor: (String) -> Color
    let density: TaskRepository.TaskDensity
    var usesGroupedListStyle = false
    @Bindable var repository: TaskRepository
    var onOpen: (() -> Void)?
    @State private var isCompleting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                if isBulkTagging { onOpen?(); return }
                isCompleting = true
                Task {
                    defer { isCompleting = false }
                    await repository.toggleCompletion(for: task)
                }
            } label: {
                checkmarkImage
                    .font(.title2)
                    .frame(width: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isCompleting)
            .accessibilityLabel(isBulkTagging ? "Select \(task.title)" : "Mark \(task.title) \(task.isCompleted ? "incomplete" : "complete")")

            Button {
                if let onOpen { onOpen() } else { repository.selectedTaskID = task.id }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if task.priority == .high {
                            Text("!!!").foregroundStyle(listColor).accessibilityLabel("High priority")
                        }
                        Text(task.title)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if task.isFlagged {
                            Image(systemName: "flag.fill").font(.footnote).foregroundStyle(.orange).accessibilityLabel("Flagged")
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { dueLabel; listLabel }
                        VStack(alignment: .leading, spacing: 2) { dueLabel; listLabel }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    if task.status == .waiting || task.status == .blocked {
                        Label(task.status.rawValue, systemImage: task.status == .blocked ? "hand.raised" : "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if (density == .detailed || repository.quickTagFilter != nil) && !task.tags.isEmpty {
                        Text(task.tags.prefix(3).map { "#" + $0 }.joined(separator: " "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, density == .compact ? 4 : 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityAction(named: task.isCompleted ? "Reopen task" : "Complete task") {
            Task { await repository.toggleCompletion(for: task) }
        }
        .accessibilityAction(named: task.isFlagged ? "Unflag task" : "Flag task") {
            Task { await repository.setFlagged(!task.isFlagged, for: task) }
        }
        .contextMenu {
            Button {
                Task { await repository.toggleCompletion(for: task) }
            } label: {
                Label(task.isCompleted ? "Mark Incomplete" : "Mark Complete", systemImage: task.isCompleted ? "circle" : "checkmark.circle")
            }
            Button {
                Task { await repository.setFlagged(!task.isFlagged, for: task) }
            } label: {
                Label(task.isFlagged ? "Unflag" : "Flag", systemImage: task.isFlagged ? "flag.slash" : "flag")
            }
            Divider()
            Button(role: .destructive) {
                Task { await repository.deleteTask(task) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder private var checkmarkImage: some View {
        if isBulkTagging {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        } else {
            Image(systemName: task.isCompleted ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(task.isCompleted ? listColor : Color.secondary)
        }
    }

    @ViewBuilder private var dueLabel: some View {
        if let dueDate = task.dueDate {
            Text(dueDate.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted))
                .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
        }
    }
    private var listLabel: some View {
        Label(repository.lists.first { $0.id == task.listID }?.title ?? "Tasks", systemImage: repository.listIcon(for: task.listID))
            .foregroundStyle(listColor).lineLimit(1)
    }
}

private enum BulkTagOperation: String, CaseIterable, Identifiable {
    case add = "Add"
    case remove = "Remove"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .add: "tag.fill"
        case .remove: "tag.slash.fill"
        }
    }
}

private struct BulkRescheduleTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selectedCount: Int
    let onApply: (Date?, Bool?) -> Void
    @State private var dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var includeTime = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Due", selection: $dueDate, displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                    Toggle("Include time", isOn: $includeTime)
                } header: {
                    Text("Reschedule \(selectedCount) task\(selectedCount == 1 ? "" : "s")")
                }
                Section {
                    Button("Remove Due Date", role: .destructive) {
                        onApply(nil, nil)
                        dismiss()
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Set Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(dueDate, includeTime)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BulkMoveTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let selectedCount: Int
    let onApply: (String) -> Void
    @State private var destinationID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Destination", selection: $destinationID) {
                        ForEach(repository.lists) { list in Text(list.title).tag(list.id) }
                    }
                } header: {
                    Text("Move \(selectedCount) task\(selectedCount == 1 ? "" : "s")")
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Move to List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onApply(destinationID)
                        dismiss()
                    }
                    .disabled(destinationID.isEmpty)
                }
            }
            .onAppear { destinationID = repository.lists.first?.id ?? "" }
        }
    }
}

private struct BulkTaskTaggingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let selectedCount: Int
    let initialOperation: BulkTagOperation
    let onApply: (BulkTagOperation, [String]) -> Void
    @State private var operation: BulkTagOperation = .add
    @State private var selectedTags = Set<String>()
    @State private var newTagText = ""

    init(
        repository: TaskRepository,
        selectedCount: Int,
        initialOperation: BulkTagOperation,
        onApply: @escaping (BulkTagOperation, [String]) -> Void
    ) {
        self.repository = repository
        self.selectedCount = selectedCount
        self.initialOperation = initialOperation
        self.onApply = onApply
        _operation = State(initialValue: initialOperation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("\(selectedCount) task\(selectedCount == 1 ? "" : "s") selected", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.indigo)
                }

                Section("Operation") {
                    Picker("Operation", selection: $operation) {
                        ForEach(BulkTagOperation.allCases) { operation in
                            Label(operation.rawValue, systemImage: operation.icon).tag(operation)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if operation == .add {
                    Section("Add Tag") {
                        HStack {
                            TextField("New tag", text: $newTagText)
                                .textInputAutocapitalization(.words)

                            Button {
                                addTypedTag()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if !repository.allTags.isEmpty {
                    Section("Saved Tags") {
                        ForEach(repository.allTags, id: \.self) { tag in
                            Button {
                                toggle(tag)
                            } label: {
                                HStack {
                                    Label(tag, systemImage: selectedTags.contains(tag) ? "checkmark.circle.fill" : "tag")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Circle()
                                        .fill(repository.color(forTag: tag))
                                        .frame(width: 12, height: 12)
                                }
                            }
                        }
                    }
                }

                if !selectedTags.isEmpty {
                    Section(operation == .add ? "Will Apply" : "Will Remove") {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(selectedTags).sorted(), id: \.self) { tag in
                                HStack(spacing: 6) {
                                    Text("#\(tag)")
                                    Image(systemName: "xmark.circle.fill")
                                        .imageScale(.small)
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(repository.color(forTag: tag))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(repository.color(forTag: tag).opacity(0.16), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
                                .onTapGesture {
                                    selectedTags.remove(tag)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Bulk Tag Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(operation == .add ? "Apply" : "Remove") {
                        onApply(operation, tagsToApply)
                        dismiss()
                    }
                    .disabled(tagsToApply.isEmpty)
                }
            }
        }
    }

    private func toggle(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func addTypedTag() {
        let normalized = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        selectedTags.insert(normalized)
        newTagText = ""
    }

    private var tagsToApply: [String] {
        var tags = Array(selectedTags)
        let typed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation == .add && !typed.isEmpty {
            tags.append(typed)
        }
        return tags
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
                    scopeRow("Next 7 Days", icon: "calendar.badge.clock", color: .cyan, scope: .next7Days)
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

private struct TaskScrollOffsets: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
    static func topItem(_ values: [String: CGFloat]) -> String? {
        values.filter { $0.value <= 0 }.max { $0.value < $1.value }?.key
            ?? values.min { $0.value < $1.value }?.key
    }
}

private struct CalendarPlanningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @Binding var settings: CalendarWorkspaceSettings
    @State private var taskID = ""
    @State private var duration = 30
    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
    @State private var slots: [CalendarPlanningSlot] = []
    @State private var selected: CalendarPlanningSlot?
    @State private var calendarID = ""
    @State private var status = ""
    @State private var saving = false
    @State private var searched = false
    @State private var conflicts: [String] = []
    @State private var reviewEvents: [CalendarEvent] = []
    @State private var editEvent: EventDraft?
    @State private var showsMultiTaskPlanner = false

    private var task: TaskItem? { repository.tasks.first { $0.id == taskID } }
    private var rangeEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: cappedEnd)) ?? cappedEnd }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan tasks") {
                    Button("Build a Day Plan", systemImage: "calendar.badge.clock") { showsMultiTaskPlanner = true }
                    Picker("Task", selection: $taskID) {
                        Text("Choose a task").tag("")
                        ForEach(repository.tasks.filter { !$0.isCompleted }) { Text($0.title).tag($0.id) }
                    }
                    Stepper("Duration: \(duration) minutes", value: $duration, in: 15...480, step: 15)
                    DatePicker("From", selection: $start, in: Date()..., displayedComponents: .date)
                    DatePicker("Through", selection: $end, in: start...(Calendar.current.date(byAdding: .day, value: 89, to: start) ?? start), displayedComponents: .date)
                    Picker("Calendar", selection: $calendarID) {
                        ForEach(repository.writableEventCalendars) { Text($0.title).tag($0.id) }
                    }
                    if repository.writableEventCalendars.isEmpty {
                        Text("Enable Calendar access and choose a writable calendar to schedule a block.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Find Open Slots") { findSlots() }
                        .disabled(task == nil || saving || calendarID.isEmpty || end < start)
                    Text("Checks all available calendars and timed tasks. Free events do not block time. Task deadlines stay unchanged. Suggestions cover up to 30 days.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if searched {
                    Section("Suggested times") {
                        if slots.isEmpty { Text("No available slots. Try a shorter duration, a wider date range, or different working hours.") }
                        ForEach(slots.prefix(12)) { slot in
                            Button {
                                selected = slot
                                status = ""
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(slot.start.formatted(date: .abbreviated, time: .shortened))
                                        Text("Until \(slot.end.formatted(date: .omitted, time: .shortened))\(slot.preferred ? " · Preferred focus time" : "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected == slot { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                    }
                }
                if let selected, let task {
                    Section("Preview") {
                        Text(task.title).font(.headline)
                        LabeledContent("Starts", value: selected.start.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Ends", value: selected.end.formatted(date: .abbreviated, time: .shortened))
                        Text("Creates a linked calendar event. Your task and its deadline remain unchanged.").font(.footnote)
                        Button(saving ? "Saving…" : "Create Time Block") { apply(selected, task: task) }
                            .disabled(saving)
                    }
                }
                if !status.isEmpty { Section { Text(status).accessibilityLabel(status) } }
                Section("Schedule review") {
                    Button("Check Conflicts in Date Range") { review() }.disabled(end < start)
                    ForEach(Array(conflicts.enumerated()), id: \.offset) { _, message in
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if !conflicts.isEmpty {
                        Button("Find Another Time for Selected Task") { findSlots() }.disabled(task == nil)
                        Button("Keep Schedule Unchanged") { conflicts = []; reviewEvents = []; status = "Schedule unchanged." }
                        ForEach(reviewEvents) { event in
                            Button("Edit " + event.title) { editEvent = EventDraft(event: event) }
                                .disabled(!repository.writableEventCalendars.contains { $0.id == event.calendarID })
                        }
                    }
                    Text("Read-only events must be changed by their calendar owner.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(item: $editEvent, onDismiss: { invalidate(); review() }) { draft in CalendarEventEditorView(repository: repository, draft: draft) }
            .sheet(isPresented: $showsMultiTaskPlanner) { MultiTaskPlanningSheet(repository: repository, settings: settings, calendarID: calendarID) }
            .taskFlowThemedBackground()
            .navigationTitle("Plan & Review")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(saving) } }
            .onChange(of: taskID) { _, _ in duration = max(15, task?.durationMinutes ?? 30); invalidate() }
            .onChange(of: duration) { _, _ in invalidate() }
            .onChange(of: start) { _, _ in if end < start { end = start }; invalidate() }
            .onChange(of: end) { _, _ in invalidate() }
            .onChange(of: calendarID) { _, _ in selected = nil }
            .task { calendarID = repository.makeEventDraft().calendarID }
            .interactiveDismissDisabled(saving)
        }
    }

    private func invalidate() { slots = []; selected = nil; searched = false; status = "" }
    private var cappedEnd: Date { min(end, Calendar.current.date(byAdding: .day, value: 30, to: start) ?? end) }
    private func findSlots() {
        selected = nil
        searched = true
        slots = CalendarPlanningEngine.slots(from: start, through: cappedEnd, duration: duration, settings: settings, events: repository.planningEvents(from: start.addingTimeInterval(-86400), to: rangeEnd), tasks: repository.tasks.filter { $0.id != taskID })
    }
    private func review() {
        reviewEvents = repository.planningEvents(from: start, to: rangeEnd)
        conflicts = CalendarPlanningEngine.conflicts(events: reviewEvents, tasks: repository.tasks.filter { guard let due = $0.dueDate else { return false }; return due >= start && due < rangeEnd }, settings: settings)
        status = conflicts.isEmpty ? "No conflicts found in this date range." : "\(conflicts.count) scheduling issues found."
    }
    private func apply(_ slot: CalendarPlanningSlot, task: TaskItem) {
        let fresh = CalendarPlanningEngine.slots(from: slot.start, through: slot.start, duration: duration, settings: settings, events: repository.planningEvents(from: slot.start.addingTimeInterval(-86400), to: slot.end.addingTimeInterval(86400)), tasks: repository.tasks.filter { $0.id != task.id })
        guard fresh.contains(where: { $0.start == slot.start }) else {
            status = "This time is no longer available. Find open slots again."
            selected = nil
            return
        }
        saving = true
        var draft = repository.makeEventDraft(startDate: slot.start, endDate: slot.end)
        draft.calendarID = calendarID
        draft.title = task.title
        draft.notes = "TaskFlow linked task: \(task.id)"
        Task {
            let success = await repository.saveEvent(draft)
            saving = false
            status = success ? "Time block saved." : (repository.errorMessage ?? "Unable to save. Try again.")
            if success { selected = nil; slots = []; searched = false }
        }
    }
}

private struct CalendarPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: CalendarWorkspaceSettings
    var body: some View {
        NavigationStack {
            Form {
                Section("Working hours") {
                    Stepper("Start: \(settings.workStart):00", value: $settings.workStart, in: 0...22)
                    Stepper("End: \(settings.workEnd):00", value: $settings.workEnd, in: (settings.workStart + 1)...23)
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { settings.weekdays.contains(day) }, set: { enabled in
                            if enabled { settings.weekdays.insert(day) } else { settings.weekdays.remove(day) }
                        }))
                    }
                }
                Section("Preferred focus times") {
                    Stepper("Start: \(settings.focusStart):00", value: $settings.focusStart, in: 0...22)
                    Stepper("End: \(settings.focusEnd):00", value: $settings.focusEnd, in: (settings.focusStart + 1)...23)
                    Stepper("Meeting buffer: \(settings.bufferMinutes) min", value: $settings.bufferMinutes, in: 0...60, step: 5)
                }
                Section("Layout") {
                    Toggle("Compact spacing", isOn: $settings.compact)
                    VStack(alignment: .leading) {
                        Text("Hour height: \(Int(settings.hourHeight)) points")
                        Slider(value: $settings.hourHeight, in: 60...140, step: 10)
                    }
                    Toggle("Show week number", isOn: $settings.showWeekNumbers)
                    Toggle("Show working hours only", isOn: $settings.hideNonworkingHours)
                    Text("All-day items remain visible. Timed events that overlap working hours remain visible.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Calendar Preferences")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings.workStart) { _, value in settings.workEnd = max(value + 1, settings.workEnd) }
            .onChange(of: settings.focusStart) { _, value in settings.focusEnd = max(value + 1, settings.focusEnd) }
        }
    }
}

private struct CalendarHourGrid: View {
    let date: Date
    let events: [CalendarEvent]
    let settings: CalendarWorkspaceSettings
    @Binding var selectedEvent: CalendarEvent?
    let color: (String) -> Color

    private var calendar: Calendar { .current }
    private var firstHour: Int { settings.hideNonworkingHours ? settings.workStart : 0 }
    private var lastHour: Int { settings.hideNonworkingHours ? settings.workEnd : 24 }
    private var gridHeight: CGFloat { CGFloat(lastHour - firstHour) * CGFloat(settings.hourHeight) }
    private var dayStart: Date { calendar.startOfDay(for: date) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400) }
    private var visibleStart: Date { calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: date) ?? dayStart }
    private var visibleEnd: Date { calendar.date(bySettingHour: lastHour, minute: 0, second: 0, of: date) ?? dayEnd }

    private func verticalPosition(_ value: Date) -> CGFloat {
        let clampedDate = min(max(value, dayStart), dayEnd)
        if clampedDate == dayEnd { return gridHeight }
        let components = calendar.dateComponents([.hour, .minute, .second], from: clampedDate)
        let hour = CGFloat(components.hour ?? 0) + CGFloat(components.minute ?? 0) / 60 + CGFloat(components.second ?? 0) / 3_600
        let offset = min(max(hour - CGFloat(firstHour), 0), CGFloat(lastHour - firstHour))
        return offset * CGFloat(settings.hourHeight)
    }

    private var timed: [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.endDate > visibleStart && $0.startDate < visibleEnd }
            .sorted { $0.startDate < $1.startDate }
    }

    private var lanes: [[CalendarEvent]] {
        var result: [[CalendarEvent]] = []
        for event in timed {
            if let index = result.firstIndex(where: { ($0.last?.endDate ?? .distantPast) <= event.startDate }) {
                result[index].append(event)
            } else {
                result.append([event])
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(events.filter(\.isAllDay), id: \.occurrenceKey) { event in
                Button { selectedEvent = event } label: {
                    Label(event.title, systemImage: "calendar").foregroundStyle(color(event.calendarID))
                }
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        ForEach(firstHour..<lastHour, id: \.self) { hour in
                            Text(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(height: CGFloat(settings.hourHeight), alignment: .top)
                        }
                    }
                    .frame(width: 62)

                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ForEach(firstHour..<lastHour, id: \.self) { _ in
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.20))
                                            .frame(height: 1)
                                            .frame(height: CGFloat(settings.hourHeight), alignment: .top)
                                    }
                                }

                                ForEach(lane) { event in
                                    let top = max(0, verticalPosition(event.startDate))
                                    let bottom = min(gridHeight, verticalPosition(event.endDate))
                                    let cardHeight = max(28, bottom - top - 2)
                                    Button { selectedEvent = event } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(event.title)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(2)
                                            Text(event.startDate.formatted(date: .omitted, time: .shortened))
                                                .font(.caption2)
                                        }
                                        .padding(6)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .background(color(event.calendarID).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(color(event.calendarID)).frame(width: 3)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 170, height: cardHeight)
                                    .position(x: 85, y: top + cardHeight / 2)
                                    .accessibilityLabel("\(event.title), \(event.startDate.formatted(date: .omitted, time: .shortened)) to \(event.endDate.formatted(date: .omitted, time: .shortened))")
                                }
                            }
                            .frame(width: 170, height: gridHeight, alignment: .topLeading)
                        }
                    }
                    .frame(minWidth: 240, alignment: .topLeading)
                }
            }
        }
    }
}

struct QuickCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let onTask: (TaskDraft) -> Void
    let onEvent: (EventDraft) -> Void
    @State private var input = ""
    @State private var parsedTitle = ""
    @State private var dueDate: Date?
    @State private var reminderMinutes: Int?
    @State private var captureKind = "Task"
    @State private var selectedListID = ""
    @State private var selectedCalendarID = ""
    @State private var eventEndDate = Date().addingTimeInterval(3600)

    init(repository: TaskRepository, onTask: @escaping (TaskDraft) -> Void, onEvent: @escaping (EventDraft) -> Void, initialText: String = "", initialKind: String = "Task") {
        self.repository = repository
        self.onTask = onTask
        self.onEvent = onEvent
        _input = State(initialValue: initialText)
        _parsedTitle = State(initialValue: initialText)
        _captureKind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Picker("Create", selection: $captureKind) {
                        Text("Task").tag("Task")
                        Text("Event").tag("Event")
                    }.pickerStyle(.segmented)
                    TextField("Describe it: Call the dentist Friday at 9", text: $input, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: input) { _, value in parse(value) }
                    Text("You can dictate with the microphone on your keyboard.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Preview") {
                    TextField("Title", text: $parsedTitle, axis: .vertical)
                    if captureKind == "Task" {
                        Picker("List", selection: $selectedListID) {
                            ForEach(repository.lists) { Text($0.title).tag($0.id) }
                        }
                        Toggle("Due date", isOn: Binding(get: { dueDate != nil }, set: { enabled in
                            if enabled, dueDate == nil { dueDate = Calendar.current.startOfDay(for: Date()) }
                            if !enabled { dueDate = nil; reminderMinutes = nil }
                        }))
                        if let dueDate {
                            DatePicker("Due", selection: Binding(get: { dueDate }, set: { self.dueDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                            Picker("Remind", selection: Binding(get: { reminderMinutes ?? 0 }, set: { reminderMinutes = $0 == 0 ? nil : $0 })) {
                                Text("At due time").tag(0)
                                Text("5 minutes before").tag(5)
                                Text("15 minutes before").tag(15)
                                Text("30 minutes before").tag(30)
                                Text("1 hour before").tag(60)
                            }
                        }
                    } else {
                        Picker("Calendar", selection: $selectedCalendarID) {
                            ForEach(repository.writableEventCalendars) { Text($0.title).tag($0.id) }
                        }
                        if let dueDate {
                            DatePicker("Starts", selection: Binding(get: { dueDate }, set: { self.dueDate = $0; eventEndDate = max(eventEndDate, $0.addingTimeInterval(1800)) }), displayedComponents: [.date, .hourAndMinute])
                            DatePicker("Ends", selection: $eventEndDate, in: (dueDate.addingTimeInterval(60))..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                    if !input.isEmpty {
                        Label(dueDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No date recognized", systemImage: dueDate == nil ? "calendar.badge.questionmark" : "calendar")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Quick Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { savePreview() }
                        .disabled(parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (captureKind == "Event" && repository.writableEventCalendars.isEmpty))
                }
            }
            .onAppear {
                selectedListID = repository.makeDraft().listID
                selectedCalendarID = repository.makeEventDraft().calendarID
                if !input.isEmpty { parse(input) }
            }
        }
    }

    private func parse(_ text: String) {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alertRegex = try? NSRegularExpression(pattern: #"(?i)\\bremind me (\\d+)\\s*(minute|minutes|min|hour|hours|hr)\\s*before\\b"#)
        if let match = alertRegex?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range, in: title), let amountRange = Range(match.range(at: 1), in: title),
           let amount = Int(title[amountRange]) {
            let unit = String(title[range]).lowercased()
            reminderMinutes = amount * (unit.contains("hour") || unit.contains("hr") ? 60 : 1)
            title.removeSubrange(range)
        } else { reminderMinutes = nil }

        dueDate = nil
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let date = match.date, let range = Range(match.range, in: title) {
            dueDate = date
            title.removeSubrange(range)
        } else {
            let weekday = try? NSRegularExpression(pattern: #"(?i)\\b(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)(?:\\s+at\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?)?\\b"#)
            if let match = weekday?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let range = Range(match.range, in: title) {
                let phrase = String(title[range]).lowercased()
                var date = Calendar.current.startOfDay(for: Date())
                if phrase.hasPrefix("tomorrow") { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
                else if phrase != "today" {
                    let names = Calendar.current.weekdaySymbols
                    if let index = names.firstIndex(where: { $0.lowercased().hasPrefix(String(phrase.prefix(3))) }) {
                        let today = Calendar.current.component(.weekday, from: date)
                        var days = (index + 1 - today + 7) % 7
                        if days == 0 { days = 7 }
                        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
                    }
                }
                if match.range(at: 2).location != NSNotFound, let hourRange = Range(match.range(at: 2), in: title), let hour = Int(title[hourRange]) {
                    let minute = Range(match.range(at: 3), in: title).flatMap { Int(title[$0]) } ?? 0
                    let meridiem = Range(match.range(at: 4), in: title).map { String(title[$0]).lowercased() } ?? ""
                    var hour24 = hour
                    if meridiem == "pm" && hour24 < 12 { hour24 += 12 }
                    if meridiem == "am" && hour24 == 12 { hour24 = 0 }
                    date = Calendar.current.date(bySettingHour: hour24, minute: minute, second: 0, of: date) ?? date
                }
                dueDate = date
                title.removeSubrange(range)
            }
        }
        title = title.replacingOccurrences(of: #"(?i)\\b(call|meet|appointment|event)\\b"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\\bat\\s+\\d{1,2}(?::\\d{2})?\\s*(am|pm)?\\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
        parsedTitle = title.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : title
        if let dueDate { eventEndDate = dueDate.addingTimeInterval(3600) }
    }

    private func savePreview() {
        if captureKind == "Task" {
            var draft = repository.makeDraft()
            draft.listID = selectedListID
            draft.title = parsedTitle
            draft.dueDate = dueDate
            draft.hasDueTime = dueDate.map { Calendar.current.dateComponents([.hour, .minute], from: $0).hour != 0 || Calendar.current.dateComponents([.hour, .minute], from: $0).minute != 0 } ?? false
            draft.alarmOffsetMinutes = reminderMinutes
            onTask(draft)
        } else {
            var draft = repository.makeEventDraft(startDate: dueDate ?? Date(), endDate: eventEndDate)
            draft.calendarID = selectedCalendarID
            draft.title = parsedTitle
            draft.alarmOffsetMinutes = reminderMinutes
            onEvent(draft)
        }
        dismiss()
    }
}

private struct TaskBoardView: View {
    @Bindable var repository: TaskRepository
    let listColor: (String) -> Color
    @State private var targetedStatus: TaskStatus?
    private let columns = TaskStatus.allCases

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns, id: \.rawValue) { status in
                        let tasks = repository.rootTasks.filter { $0.status == status }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(status.rawValue).font(.headline)
                                Spacer()
                                Text(tasks.count, format: .number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ScrollView {
                                LazyVStack(spacing: 10) {
                                    ForEach(tasks) { task in
                                        TaskBoardCard(task: task, accent: listColor(task.listID),
                                                      listTitle: repository.lists.first { $0.id == task.listID }?.title ?? "Tasks",
                                                      listIcon: repository.listIcon(for: task.listID)) {
                                            repository.selectedTaskID = task.id
                                        }
                                        .draggable(task.id)
                                        .contextMenu {
                                            Menu("Move to", systemImage: "rectangle.split.3x1") {
                                                ForEach(TaskStatus.editableCases, id: \.rawValue) { destination in
                                                    Button(destination.rawValue) { Task { await repository.setStatus(destination, for: task) } }
                                                        .disabled(destination == status)
                                                }
                                            }
                                        }
                                    }
                                    if tasks.isEmpty {
                                        Text(status == .overdue ? "No overdue tasks" : "Drop a task here").font(.subheadline).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, minHeight: 80)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(width: min(320, max(260, geometry.size.width - 48)))
                        .frame(height: max(200, geometry.size.height - 24))
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(targetedStatus == status ? repository.appTheme.primary : .clear, lineWidth: 2) }
                        .dropDestination(for: String.self) { ids, _ in
                            guard status != .overdue else { return false }
                            let matches = repository.tasks.filter { ids.contains($0.id) }
                            guard !matches.isEmpty else { return false }
                            Task { for task in matches { await repository.setStatus(status, for: task) } }
                            return true
                        } isTargeted: { targeted in
                            if targeted { targetedStatus = status } else if targetedStatus == status { targetedStatus = nil }
                        }
                    }
                }
                .padding(12)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .background(TaskFlowBackground(accent: repository.appTheme.primary))
    }
}


private struct MultiTaskPlanningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let settings: CalendarWorkspaceSettings
    let calendarID: String
    @State private var selectedIDs = Set<String>()
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var proposals: [(task: TaskItem, slot: CalendarPlanningSlot)] = []
    @State private var status = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Choose work") {
                    DatePicker("Start day", selection: $startDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    ForEach(repository.rootTasks.filter { !$0.isCompleted }.sorted { priorityRank($0) < priorityRank($1) }) { task in
                        Toggle(isOn: Binding(get: { selectedIDs.contains(task.id) }, set: { enabled in
                            if enabled { selectedIDs.insert(task.id) } else { selectedIDs.remove(task.id) }
                            proposals = []
                        })) {
                            VStack(alignment: .leading) {
                                Text(task.title)
                                Text("\(task.priority.rawValue) priority · \(task.durationMinutes ?? 30) min\(task.dueDate.map { " · due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Tasks are ordered by priority and deadline. Suggested blocks respect working hours, events, existing timed tasks, and your buffer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Suggest a Day Plan") { makePlan() }
                        .disabled(selectedIDs.isEmpty || calendarID.isEmpty || isSaving)
                }
                if !proposals.isEmpty {
                    Section("Review proposed schedule") {
                        ForEach(proposals, id: \.task.id) { proposal in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proposal.task.title).font(.headline)
                                Text("\(proposal.slot.start.formatted(date: .abbreviated, time: .shortened)) – \(proposal.slot.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Button(isSaving ? "Saving…" : "Apply Schedule") { applyPlan() }
                            .disabled(isSaving)
                        Text("Creates linked calendar blocks. Task deadlines remain unchanged. You can undo each calendar change in TaskFlow.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !status.isEmpty { Section { Text(status) } }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Plan My Day")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(isSaving) } }
            .onChange(of: startDate) { _, _ in proposals = [] }
        }
    }

    private func priorityRank(_ task: TaskItem) -> Int {
        let deadline = task.dueDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
        return (task.priority == .high ? 0 : task.priority == .medium ? 1 : task.priority == .low ? 2 : 3) * 1000000000 + Int(min(deadline / 86400, 900000000))
    }

    private func makePlan() {
        let tasks = repository.rootTasks.filter { selectedIDs.contains($0.id) && !$0.isCompleted }.sorted { priorityRank($0) < priorityRank($1) }
        var scheduledEvents = repository.planningEvents(from: startDate.addingTimeInterval(-86400), to: startDate.addingTimeInterval(86400 * 31))
        var planned: [(task: TaskItem, slot: CalendarPlanningSlot)] = []
        for task in tasks {
            let length = max(15, task.durationMinutes ?? 30)
            let candidates = CalendarPlanningEngine.slots(from: startDate, through: Calendar.current.date(byAdding: .day, value: 30, to: startDate) ?? startDate, duration: length, settings: settings, events: scheduledEvents, tasks: repository.tasks.filter { $0.id != task.id && !selectedIDs.contains($0.id) })
            let beforeDeadline = candidates.filter { slot in
                guard let dueDate = task.dueDate else { return true }
                if task.hasDueTime { return slot.end <= dueDate }
                let dueDayEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: dueDate)) ?? dueDate
                return slot.end <= dueDayEnd
            }
            guard let slot = beforeDeadline.first else { continue }
            planned.append((task, slot))
            scheduledEvents.append(CalendarEvent(id: "proposal-\(task.id)", calendarID: calendarID, title: task.title, startDate: slot.start, endDate: slot.end, isAllDay: false, availability: "Busy"))
        }
        proposals = planned
        status = planned.count == tasks.count ? "All selected tasks fit." : "\(tasks.count - planned.count) task(s) could not fit in the next 30 days. Shorten estimates or adjust working hours."
    }

    private func applyPlan() {
        guard !proposals.isEmpty else { return }
        isSaving = true
        let drafts = proposals.map { proposal -> EventDraft in
            var draft = repository.makeEventDraft(startDate: proposal.slot.start, endDate: proposal.slot.end)
            draft.calendarID = calendarID
            draft.title = proposal.task.title
            draft.notes = "TaskFlow linked task: \(proposal.task.id)"
            return draft
        }
        Task {
            let succeeded = await repository.saveEvents(drafts)
            isSaving = false
            if succeeded { dismiss() } else { status = repository.errorMessage ?? "Could not apply the proposed schedule." }
        }
    }
}


private struct TaskBoardCard: View {
    let task: TaskItem
    let accent: Color
    let listTitle: String
    let listIcon: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                Label(listTitle, systemImage: listIcon)
                    .font(.caption.weight(.medium)).foregroundStyle(accent).lineLimit(1)
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let due = task.dueDate {
                    Text(due.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted))
                        .font(.caption)
                        .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
                }
                if !task.tags.isEmpty {
                    Text(task.tags.prefix(2).map { "#" + $0 }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
    }
}


private struct EventAvailabilitySuggestions: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let event: CalendarEvent
    let accent: Color
    @AppStorage("TaskFlow.calendar.workspace") private var planningData = Data()
    @State private var suggestions: [CalendarPlanningSlot] = []

    private var settings: CalendarWorkspaceSettings {
        (try? JSONDecoder().decode(CalendarWorkspaceSettings.self, from: planningData)) ?? CalendarWorkspaceSettings()
    }
    private var duration: Int { max(15, Int(event.endDate.timeIntervalSince(event.startDate) / 60)) }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 14, to: event.startDate) ?? event.startDate }
    private var shareText: String {
        let options = suggestions.prefix(5).map { $0.start.formatted(date: .complete, time: .shortened) }
        return "Suggested alternate times for \(event.title):\n" + options.map { "• \($0)" }.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Suggestions use calendars that affect availability, working hours, buffers, and timed tasks. Share a few options with attendees to coordinate a new time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Available times") {
                    if suggestions.isEmpty {
                        ContentUnavailableView("No alternate times found", systemImage: "calendar.badge.exclamationmark", description: Text("Check calendar access and working hours, or widen your planning settings."))
                    }
                    ForEach(suggestions) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(slot.start.formatted(date: .complete, time: .shortened)).font(.headline)
                            Text("Until \(slot.end.formatted(date: .omitted, time: .shortened))\(slot.preferred ? " · Preferred focus time" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                if !suggestions.isEmpty {
                    Section {
                        ShareLink(item: shareText) {
                            Label("Share proposed times", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Meeting Options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                let calendar = Calendar.current
                let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.startDate)) ?? event.startDate
                suggestions = Array(CalendarPlanningEngine.slots(
                    from: start,
                    through: end,
                    duration: duration,
                    settings: settings,
                    events: repository.planningEvents(from: start.addingTimeInterval(-86400), to: end),
                    tasks: repository.tasks
                ).prefix(8))
            }
        }
        .tint(accent)
    }
}

/// Apple's system month calendar (`UICalendarView`) with a dot under days that have events or tasks.
struct NativeMonthCalendar: UIViewRepresentable {
    @Binding var selectedDate: Date
    let markers: (Date) -> [Color]
    /// Changes whenever the underlying events or tasks change, so dots are refreshed.
    let contentVersion: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar.current
        view.locale = .current
        view.fontDesign = .default
        view.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        selection.setSelected(Calendar.current.dateComponents([.year, .month, .day], from: selectedDate), animated: false)
        view.selectionBehavior = selection
        view.visibleDateComponents = Calendar.current.dateComponents([.year, .month], from: selectedDate)
        view.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.lastVersion = contentVersion
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
        let calendar = Calendar.current
        let wanted = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        if let selection = view.selectionBehavior as? UICalendarSelectionSingleDate, selection.selectedDate != wanted {
            selection.setSelected(wanted, animated: true)
            let visible = view.visibleDateComponents
            if visible.year != wanted.year || visible.month != wanted.month {
                view.setVisibleDateComponents(calendar.dateComponents([.year, .month], from: selectedDate), animated: true)
            }
        }
        if context.coordinator.lastVersion != contentVersion {
            context.coordinator.lastVersion = contentVersion
            view.reloadDecorations(forDateComponents: context.coordinator.visibleMonthDays(of: view), animated: false)
        }
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: NativeMonthCalendar
        var lastVersion = 0

        init(parent: NativeMonthCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = Calendar.current.date(from: dateComponents) else { return nil }
            guard let color = parent.markers(date).first else { return nil }
            return .default(color: UIColor(color), size: .medium)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, let date = Calendar.current.date(from: dateComponents) else { return }
            parent.selectedDate = date
        }

        func visibleMonthDays(of view: UICalendarView) -> [DateComponents] {
            let calendar = Calendar.current
            guard let monthStart = calendar.date(from: view.visibleDateComponents),
                  let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
            return range.compactMap { day in
                calendar.date(byAdding: .day, value: day - 1, to: monthStart).map { calendar.dateComponents([.year, .month, .day], from: $0) }
            }
        }
    }
}

enum TaskSearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tasks = "Tasks"
    case events = "Events"
    var id: String { rawValue }
}

struct CalendarConflictCheckerPage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.date(byAdding: .day, value: 6, to: Date()) ?? Date()
    @State private var includeAllDay = true
    @State private var conflicts: [CalendarEventConflict] = []
    @State private var isScanning = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var editDraft: EventDraft?
    @State private var detailsEvent: CalendarEvent?
    @State private var moveEvent: CalendarEvent?
    @State private var undoAvailability: (CalendarEvent, EventAvailability)?
    @State private var undoMove: EventDraft?

    private var rangeStart: Date { Calendar.current.startOfDay(for: start) }
    private var rangeEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end }
    private var scanKey: String { "\(rangeStart)|\(rangeEnd)|\(includeAllDay)|\(repository.eventAccessState)|\(repository.excludedAvailabilityCalendarIDs.sorted())" }
    private var dayGroups: [(date: Date, items: [CalendarEventConflict])] {
        Dictionary(grouping: Array(conflicts.prefix(200)), by: { Calendar.current.startOfDay(for: $0.start) })
            .map { (date: $0.key, items: $0.value) }.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                filters
                if repository.eventAccessState != .granted {
                    Section {
                        ContentUnavailableView("Calendar Access Needed", systemImage: "calendar.badge.exclamationmark", description: Text(repository.eventAccessState.message))
                        Button("Allow Calendar Access") { Task { await repository.requestEventCalendarAccess(); scan() } }
                    }
                } else if end < start {
                    Section { Label("Choose an end date on or after the start date", systemImage: "exclamationmark.triangle") }
                } else if isScanning {
                    Section { ProgressView("Checking calendars…") }
                } else if conflicts.isEmpty {
                    Section { ContentUnavailableView("No Conflicts", systemImage: "checkmark.circle", description: Text("No busy events overlap in this date range. Free events do not block time.")) }
                } else {
                    Section {
                        Label("\(conflicts.count >= 2_001 ? "At least " : "")\(conflicts.count) overlapping event pairs", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        if conflicts.count > 200 { Text("Showing the first 200 pairs. Narrow the date range to review more.").font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(dayGroups, id: \.date) { group in
                        Section(group.date.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.items) { conflict in conflictCard(conflict) }
                        }
                    }
                }
                if undoAvailability != nil || undoMove != nil {
                    Section { Button("Undo Last Resolution", systemImage: "arrow.uturn.backward") { undo() }.disabled(isSaving) }
                }
            }
            .listStyle(.insetGrouped)
            .taskFlowThemedBackground()
            .navigationTitle("Conflict Checker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise") { scan() }.disabled(isSaving) }
            }
            .task(id: scanKey) { scan() }
            .refreshable { scan() }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in scan() }
            .sheet(item: $editDraft, onDismiss: { scan() }) { draft in CalendarEventEditorView(repository: repository, draft: draft) }
            .sheet(item: $detailsEvent, onDismiss: { scan() }) { event in CalendarEventDetailView(repository: repository, event: event, color: color(event)) }
            .sheet(item: $moveEvent, onDismiss: { scan() }) { event in
                ConflictRescheduleSheet(repository: repository, event: event) { previous in
                    undoAvailability = nil
                    undoMove = previous
                    scan()
                }
            }
            .alert("Could Not Resolve Conflict", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var filters: some View {
        Section {
            Menu("Date Range") {
                ForEach([7, 14, 30], id: \.self) { days in
                    Button("Next \(days) Days") {
                        start = Date()
                        end = Calendar.current.date(byAdding: .day, value: days - 1, to: start) ?? start
                    }
                }
            }
            DatePicker("From", selection: $start, displayedComponents: .date)
            DatePicker("Through", selection: $end, in: start..., displayedComponents: .date)
            Toggle("Include All-Day Events", isOn: $includeAllDay)
        } footer: { Text("Checks calendars enabled under Settings → Calendars → Affects Availability, including hidden calendars. Free events are excluded. Invitee schedules are not available. Limit each scan to 90 days.") }
    }

    private func conflictCard(_ conflict: CalendarEventConflict) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Overlap: \(conflict.start.formatted(date: .omitted, time: .shortened))–\(conflict.end.formatted(date: .omitted, time: .shortened))", systemImage: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            eventRow(conflict.first)
            Divider()
            eventRow(conflict.second)
        }.padding(.vertical, 6)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { detailsEvent = event } label: {
                HStack(alignment: .top) {
                    Circle().fill(color(event)).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.headline).foregroundStyle(.primary)
                        Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + event.endDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Text((repository.eventCalendars.first { $0.id == event.calendarID }?.title ?? "Calendar") + " · " + (event.availability ?? "Busy")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            if repository.writableEventCalendars.contains(where: { $0.id == event.calendarID }) {
                ViewThatFits(in: .horizontal) {
                    HStack { resolutionButtons(event) }
                    VStack(alignment: .leading) { resolutionButtons(event) }
                }.disabled(isSaving)
            } else { Text("Read-only calendar · resolve by changing the other event").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func resolutionButtons(_ event: CalendarEvent) -> some View {
        if repository.availabilityOptions(for: event.calendarID).contains(.free) {
            Button("Mark Free") { markFree(event) }.buttonStyle(.bordered).tint(.green)
        }
        Button("Edit Time") { editDraft = EventDraft(event: event) }.buttonStyle(.bordered)
        if !event.isAllDay { Button("Find Time") { moveEvent = event }.buttonStyle(.bordered) }
    }

    private func color(_ event: CalendarEvent) -> Color { repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue }
    private func scan() {
        guard !isSaving else { return }
        guard end >= start else { conflicts = []; return }
        guard rangeEnd.timeIntervalSince(rangeStart) <= 91 * 86400 else { conflicts = []; error = "Choose a date range of 90 days or fewer."; return }
        isScanning = true
        let events = repository.conflictCheckEvents(from: rangeStart, to: rangeEnd)
        conflicts = EventConflictChecker.pairs(in: events, from: rangeStart, to: rangeEnd, includeAllDay: includeAllDay)
        isScanning = false
    }
    private func markFree(_ event: CalendarEvent) {
        isSaving = true
        Task {
            if await repository.setEventAvailability(.free, for: event) {
                let updated = repository.conflictCheckEvents(from: event.startDate, to: event.endDate).first { $0.id == repository.lastAvailabilityEventID && $0.startDate == event.startDate }
                undoAvailability = updated.flatMap { updated in EventAvailability(rawValue: event.availability ?? "Busy").map { (updated, $0) } }
                undoMove = nil
            } else { error = repository.eventSaveStatus }
            isSaving = false
            scan()
        }
    }
    private func undo() {
        isSaving = true
        Task {
            let succeeded: Bool
            if let (event, previous) = undoAvailability { succeeded = await repository.setEventAvailability(previous, for: event) }
            else if let previous = undoMove { succeeded = await repository.saveEvent(previous) }
            else { isSaving = false; return }
            if succeeded { undoAvailability = nil; undoMove = nil }
            else { error = repository.eventSaveStatus }
            isSaving = false
            scan()
        }
    }
}

private struct ConflictRescheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let event: CalendarEvent
    let onSaved: (EventDraft) -> Void
    @AppStorage("TaskFlow.calendar.workspace") private var settingsData = Data()
    @State private var slots: [CalendarPlanningSlot] = []
    @State private var selected: CalendarPlanningSlot?
    @State private var isSaving = false
    @State private var error: String?
    private var settings: CalendarWorkspaceSettings { (try? JSONDecoder().decode(CalendarWorkspaceSettings.self, from: settingsData)) ?? CalendarWorkspaceSettings() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title).font(.headline)
                    Text("Choose an open time in the next 14 days. Suggestions respect working hours, buffers, timed tasks and calendars that affect availability. The event keeps its exact duration.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Open Times") {
                    if slots.isEmpty { ContentUnavailableView("No Open Times", systemImage: "calendar.badge.exclamationmark", description: Text("Use Edit Time to pick a different date, or adjust your calendar working hours.")) }
                    ForEach(slots) { slot in
                        Button { selected = slot } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(slot.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                                    Text("Until " + slot.start.addingTimeInterval(event.endDate.timeIntervalSince(event.startDate)).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == slot.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Find Open Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Saving…" : "Move Event") { move() }.disabled(selected == nil || isSaving) }
            }
            .task {
                let start = max(Date(), event.startDate)
                let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start
                let events = repository.conflictCheckEvents(from: start.addingTimeInterval(-86400), to: end).filter { !($0.id == event.id && $0.startDate == event.startDate) }
                slots = Array(CalendarPlanningEngine.slots(from: start, through: end, duration: max(1, Int(ceil(event.endDate.timeIntervalSince(event.startDate) / 60))), settings: settings, events: events, tasks: repository.tasks).prefix(12))
            }
            .alert("Time Is Not Available", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func move() {
        guard let selected else { return }
        var draft = EventDraft(event: event)
        draft.startDate = selected.start
        draft.endDate = selected.start.addingTimeInterval(event.endDate.timeIntervalSince(event.startDate))
        let freshEvents = repository.conflictCheckEvents(from: selected.start.addingTimeInterval(-86400), to: draft.endDate.addingTimeInterval(86400)).filter { !($0.id == event.id && $0.startDate == event.startDate) }
        let validSlots = CalendarPlanningEngine.slots(from: selected.start, through: selected.start, duration: max(1, Int(ceil(event.endDate.timeIntervalSince(event.startDate) / 60))), settings: settings, events: freshEvents, tasks: repository.tasks)
        guard validSlots.contains(where: { $0.start == selected.start }), repository.eventConflicts(for: draft, originalStart: event.startDate).isEmpty else {
            error = "This time is no longer open with your current events, tasks and buffers. Choose a different slot."; return
        }
        isSaving = true
        Task {
            if await repository.saveEvent(draft) {
                var previous = EventDraft(event: event)
                previous.eventID = repository.lastSavedEventID
                previous.originalStartDate = selected.start
                onSaved(previous)
                dismiss()
            }
            else { error = repository.eventSaveStatus }
            isSaving = false
        }
    }
}
