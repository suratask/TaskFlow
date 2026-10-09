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
    @State private var cleanupListID: String?
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            if let action = repository.taskRedo {
                                Button("Redo " + action.message, systemImage: "arrow.uturn.forward") { Task { await repository.redoLastTaskAction() } }
                                    .keyboardShortcut("z", modifiers: [.command, .shift])
                            }
                            if case .list(let id) = repository.selectedScope,
                               let list = repository.lists.first(where: { $0.id == id }) {
                                Button("Clean Up Items", systemImage: "trash") { cleanupListID = id }
                                Button(repository.pinnedListIDs.contains(id) ? "Unpin List" : "Pin List to Tasks", systemImage: repository.pinnedListIDs.contains(id) ? "pin.slash" : "pin") { repository.togglePinnedList(list) }
                            }
                            Button("Manage Pinned Lists", systemImage: "pin") { showsPinnedLists = true }
                            Button("Select Tasks", systemImage: "checkmark.circle") { beginBulkTagging() }
                            Button("Clear Completed", systemImage: "trash", role: .destructive) { promptToClearCompleted() }
                                .disabled(clearingCompleted || repository.isUndoing || repository.completedTasksInSelectedScope.isEmpty)
                            Picker("View As", selection: Binding(
                                get: { effectiveViewMode == .board ? TaskRepository.TaskViewMode.board : .list },
                                set: { repository.setViewMode($0, for: repository.selectedScope) } // Remembered per list or view.
                            )) {
                                Label("List", systemImage: "list.bullet").tag(TaskRepository.TaskViewMode.list)
                                Label("Board", systemImage: "rectangle.split.3x1").tag(TaskRepository.TaskViewMode.board)
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
                .sheet(isPresented: Binding(get: { cleanupListID != nil }, set: { if !$0 { cleanupListID = nil } })) {
                    if let id = cleanupListID { ListCleanupView(repository: repository, listID: id) }
                }
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
                    .id(id)
            } else {
            switch effectiveViewMode {
            case .list, .timeline:
                taskList
            case .calendar, .agenda: // Agenda is now a Calendar style.
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
            }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Every active filter is visible, so it's clear why a task isn't showing.
            if repository.hasActiveFilters && effectiveViewMode != .calendar {
                TaskFilterChipBar(repository: repository)
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

    /// Three modes: List, Board, and Calendar (whose Day/Week/Month/Agenda styles replace the old
    /// Timeline and Agenda modes). List and Board are remembered per list or view.
    private var effectiveViewMode: TaskRepository.TaskViewMode {
        if let viewModeOverride { return viewModeOverride.normalized }
        if repository.taskViewMode.normalized == .calendar { return .calendar }
        return repository.viewMode(for: repository.selectedScope)
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
                // First-run guidance in place of an empty or unexplained screen.
                if !isBulkTagging {
                    TipView(TaskGesturesTip()).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    TipView(QuickAddTip()).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
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
                        if repository.showsGroupHeaders {
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
        // Completed tasks slide out of the open list and reorders move smoothly; Reduce Motion turns this off.
        .animation(reduceMotion ? nil : .snappy, value: repository.tasksRevision)
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
        case .next7Days, .upNext: "Upcoming"
        case .planMyDay: "Today"
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

struct CalendarEventSearchRow: View {
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

struct FocusModeBrief: View {
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

struct TimelineSection: Identifiable {
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

struct TaskMilestone: Identifiable {
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

struct TaskScrollOffsets: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
    static func topItem(_ values: [String: CGFloat]) -> String? {
        values.filter { $0.value <= 0 }.max { $0.value < $1.value }?.key
            ?? values.min { $0.value < $1.value }?.key
    }
}

enum TaskSearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tasks = "Tasks"
    case events = "Events"
    var id: String { rawValue }
}
