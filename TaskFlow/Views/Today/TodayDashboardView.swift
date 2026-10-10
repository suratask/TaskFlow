import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

struct TodayDashboardView: View {
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @State private var selectedCalendarEvent: CalendarEvent?
    @State private var showsQuickCapture = false
    @State private var captureEventDraft: EventDraft?
    @State private var choosingPriorities = false
    @State private var planningOverdue = false
    @State private var overdueExpanded = false
    @State private var tomorrowExpanded = false
    @State private var customizingToday = false
    @State private var reschedulingTask: TaskItem?
    @State private var skippedFocusIDs: Set<String> = []
    @State private var completingFocusTask = false
    @State private var now = Date()
    @AppStorage("TaskFlow.plannedDay") private var plannedDay = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Plan My Day is Today's morning mode: until noon (or when opened as Plan My Day),
    /// a card offers the planning steps until it's marked done for the day.
    private var showsPlanningCard: Bool {
        repository.accessState == .granted && plannedDay != SpecializedTaskDetails.dateText(now) &&
            (repository.selectedScope == .planMyDay || Calendar.current.component(.hour, from: now) < 12)
    }

    private var planningCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Plan Your Day", systemImage: "sun.max.fill").font(.headline).foregroundStyle(.orange)
                Text("Choose your top three, then decide what to do with anything overdue.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { planningButtons }
                    VStack(alignment: .leading) { planningButtons }
                }
                Button("Done Planning") { withAnimation { plannedDay = SpecializedTaskDetails.dateText(now) } }
                    .buttonStyle(.borderless).font(.subheadline)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var planningButtons: some View {
        Button("Choose Top 3", systemImage: "star") { choosingPriorities = true }
            .buttonStyle(.borderedProminent)
        if !repository.overdueTasks.isEmpty {
            Button("Review Overdue (\(repository.overdueTasks.count))", systemImage: "clock.arrow.circlepath") { planningOverdue = true }
                .buttonStyle(.bordered)
        }
    }

    private var todayEvents: [CalendarEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return repository.calendarEvents
            .filter { $0.startDate < end && $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
    }

    private var openTodayTasks: [TaskItem] {
        repository.dueTodayTasks.filter { !$0.isOverdue() }
    }

    private var checklistTasks: [TaskItem] {
        openTodayTasks.filter { !repository.visibleTodaySections.contains(.timeline) || !$0.hasDueTime }
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if repository.accessState != .granted && repository.usesReminders {
                Section {
                    Text(repository.accessState.message).foregroundStyle(.secondary)
                    if repository.accessState == .unknown {
                        Button("Continue") { Task { await repository.requestAccess() } }
                    }
                }
            }

            if showsPlanningCard { planningCard }
            ForEach(repository.visibleTodaySections) { section in
                todaySection(section, proxy: proxy)
            }
            if repository.visibleTodaySections.allSatisfy({ !sectionHasContent($0) }) {
                Section {
                    Text("No items in your selected sections").foregroundStyle(.secondary)
                    Button("Choose Today’s Sections", systemImage: "slider.horizontal.3") { customizingToday = true }
                }
            }
        }
        .listStyle(.insetGrouped)
        }
        .taskFlowThemedBackground()
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Customize Today", systemImage: "slider.horizontal.3") { customizingToday = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Task", systemImage: "checklist") {
                        var draft = repository.makeDraft()
                        draft.dueDate = Calendar.current.startOfDay(for: Date())
                        editorDraft = draft
                    }
                    if repository.canCreateEvents {
                        Button("New Event", systemImage: "calendar.badge.plus") { captureEventDraft = repository.makeEventDraft() }
                    }
                    Button("Quick Capture", systemImage: "text.cursor") { showsQuickCapture = true }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    showsQuickCapture = true
                }
                .popoverTip(AddMenuTip())
            }
        }
        .sheet(item: $reschedulingTask) { task in
            BulkRescheduleTasksSheet(selectedCount: 1, initialTask: task) { date, hasTime in
                Task { await repository.setDueDate(date, hasDueTime: hasTime, forTaskIDs: [task.id]) }
            }
        }
        .sheet(isPresented: $customizingToday) { TodaySectionsEditor(repository: repository) }
        .sheet(isPresented: $choosingPriorities) { TodayPriorityPicker(repository: repository) }
        .sheet(isPresented: $planningOverdue) { TodayOverduePlanner(repository: repository) }
        .task {
            while !Task.isCancelled {
                now = Date()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .sheet(isPresented: $showsQuickCapture) {
            QuickCaptureView(repository: repository, onTask: { draft in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editorDraft = draft }
            }, onEvent: { draft in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { captureEventDraft = draft }
            })
        }
        .sheet(item: $captureEventDraft) { draft in
            CalendarEventEditorView(repository: repository, draft: draft)
        }
        .sheet(item: $selectedCalendarEvent) { event in
            CalendarEventDetailView(repository: repository, event: event,
                                    color: repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue)
        }
    }

    private func sectionHasContent(_ section: TodayDashboardSection) -> Bool {
        switch section {
        case .summary, .suggested, .focus, .timeline: true
        case .priorities, .tasks, .capture: repository.accessState == .granted
        case .overdue: !repository.overdueTasks.isEmpty
        case .calendar: repository.showsCalendarEvents && !todayEvents.isEmpty
        case .tomorrow: repository.upcomingTasks.contains { $0.dueDate.map { Calendar.current.isDateInTomorrow($0) } == true }
        }
    }

    @ViewBuilder private func todaySection(_ section: TodayDashboardSection, proxy: ScrollViewProxy) -> some View {
        switch section {
        case .summary:
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { summaryButtons(proxy) }
                } else {
                    HStack(spacing: 8) { summaryButtons(proxy) }
                }
                Button {
                    revealSection(.timeline, anchor: "today-timeline", proxy: proxy)
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                            let entries = TodayPlanning.timeline(tasks: repository.tasks, events: repository.showsCalendarEvents ? repository.calendarEvents : [], now: context.date)
                            let seconds = TodayPlanning.availableSeconds(entries, now: context.date)
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Available time today").foregroundStyle(.secondary)
                                    Text(TodayPlanning.countdownText(seconds: seconds))
                                        .monospacedDigit().fontWeight(.semibold)
                                }
                            } icon: { Image(systemName: "clock") }
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Available time today")
                            .accessibilityValue("\(seconds / 3600) hours, \((seconds % 3600) / 60) minutes, \(seconds % 60) seconds")
                    }
                }.buttonStyle(.plain)
                if repository.showsCalendarEvents { eventSpotlight }
            } header: {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            }

        case .focus:
            Section("Focus Next") {
                if let task = focusTask {
                    Button(task.title) { repository.openTask(id: task.id) }.foregroundStyle(.primary)
                    VStack(alignment: .leading, spacing: 12) { focusActions(task) }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .disabled(completingFocusTask)
                } else {
                    Text("No actionable tasks to focus on").foregroundStyle(.secondary)
                }
            }
        case .timeline:
            Section {
                ForEach(timelineEntries) { entry in
                    Button {
                        if let task = entry.task { repository.openTask(id: task.id) }
                        if let event = entry.event { selectedCalendarEvent = event }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(entry.title, systemImage: entry.task == nil ? "calendar" : "checklist").foregroundStyle(.primary)
                            Text(entry.start.formatted(date: .omitted, time: .shortened) + " – " + entry.end.formatted(date: .omitted, time: .shortened)).font(.caption)
                            if entry.estimated { Text("Estimated 30-minute task block").font(.caption).foregroundStyle(.secondary) }
                            if TodayPlanning.conflicts(entry, entries: timelineEntries) { Label("Overlapping schedule", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }.fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.plain)
                }
                if timelineEntries.isEmpty { Text(repository.showsCalendarEvents ? "No timed tasks or events today" : "No timed tasks today").foregroundStyle(.secondary) }
                ForEach(availableGaps) { gap in
                    Label("Free " + gap.start.formatted(date: .omitted, time: .shortened) + " – " + gap.end.formatted(date: .omitted, time: .shortened) + " · " + gap.durationText, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: { Text(repository.todaySectionTitle(.timeline)) } footer: {
                Text(repository.showsCalendarEvents
                     ? "Task blocks start at their due time. Missing estimates use 30 minutes. Free time covers the rest of today; all-day events do not reserve time."
                     : "Task blocks start at their due time. Missing estimates use 30 minutes. Free time covers the rest of today.")
            }
            .id("today-timeline")

        case .priorities:
            if repository.accessState == .granted {
                Section {
                    if repository.todayPriorityTasks.isEmpty {
                        Button("Choose up to three priorities", systemImage: "star") { choosingPriorities = true }
                    } else {
                        ForEach(repository.todayPriorityTasks) { dashboardTaskRow($0) }
                        let finished = repository.todayPriorityTasks.filter(\.isCompleted).count
                        ProgressView(value: Double(finished), total: Double(repository.todayPriorityTasks.count))
                            .accessibilityLabel("Today priorities")
                            .accessibilityValue("\(finished) of \(repository.todayPriorityTasks.count) finished")
                        Text("\(finished) of \(repository.todayPriorityTasks.count) finished").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack { Text("Top 3 Today"); Spacer(); Button("Manage") { choosingPriorities = true }.textCase(nil) }
                } footer: { Text("Your priorities for today. Due dates stay as you set them.") }
            }

        case .overdue:
            if !repository.overdueTasks.isEmpty {
                Section {
                    DisclosureGroup("\(repository.overdueTasks.count) overdue tasks", isExpanded: $overdueExpanded) {
                        ForEach(repository.overdueTasks.sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }) {
                            dashboardTaskRow($0, canCommit: true, canDefer: true)
                        }
                    }
                    Button("Plan Overdue Tasks", systemImage: "calendar.badge.clock") { planningOverdue = true }
                } header: { Text("Overdue") }
                .id("today-overdue")
            }
        case .tasks:
            taskSection(repository.visibleTodaySections.contains(.timeline) ? "Untimed Tasks" : "Today", tasks: checklistTasks).id("today-tasks")
            if repository.accessState == .granted, checklistTasks.isEmpty {
                Section {
                    Label(!openTodayTasks.isEmpty ? "Timed tasks appear in your timeline" : TodayPlanning.emptyTaskMessage(repository.tasks, now: now), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }.id("today-tasks")
            }

        case .calendar:
            if !todayEvents.isEmpty {
                Section("Calendar") {
                    ForEach(todayEvents, id: \.occurrenceKey) { event in
                        Button {
                            repository.selectedTaskID = nil
                            selectedCalendarEvent = event
                        } label: {
                            HStack(spacing: 12) {
                                Circle().fill(eventColor(event)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).foregroundStyle(.primary).lineLimit(1)
                                    if let location = event.location, !location.isEmpty {
                                        Text(location).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(event.isAllDay ? "All Day" : event.startDate.formatted(date: .omitted, time: .shortened))
                                    if !event.isAllDay {
                                        Text(event.endDate.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                                    }
                                }
                                .font(.subheadline)
                                .monospacedDigit()
                            }
                        }
                        .tint(.primary)
                    }
                }.id("today-events")
            }

        case .tomorrow:
            let tomorrowTasks = repository.upcomingTasks.filter { task in
                guard let due = task.dueDate else { return false }
                return Calendar.current.isDateInTomorrow(due)
            }
            if !tomorrowTasks.isEmpty {
                Section("Tomorrow") {
                    DisclosureGroup("\(tomorrowTasks.count) \(tomorrowTasks.count == 1 ? "task" : "tasks")", isExpanded: $tomorrowExpanded) {
                        ForEach(tomorrowTasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
                            dashboardTaskRow($0, canCommit: true)
                        }
                    }
                }.id("today-tomorrow")
            }
        case .suggested:
            if !suggestedTasks.isEmpty || !repository.overdueTasks.isEmpty {
                TipView(PlanTodayTip())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            taskSection("Suggested", tasks: suggestedTasks, canCommit: true,
                        footer: "Flagged and high-priority tasks that aren\u{2019}t due today. Swipe right to add one to Today.")

            if suggestedTasks.isEmpty {
                Section {
                    Label("No actionable suggestions", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } header: { Text("Suggested") } footer: { Text("Suggestions use flagged or high-priority tasks. Waiting and blocked tasks are excluded.") }
            }
        case .capture:
            if repository.accessState == .granted {
                Section {
                    InlineNewTaskRow(repository: repository, defaultDue: .today, onShowDetails: { editorDraft = $0 }, onAdded: {
                        withAnimation { proxy.scrollTo(InlineNewTaskRow.scrollID, anchor: .bottom) }
                    })
                } footer: {
                    Text("New tasks here are due today.")
                }
            }        }
    }

    @ViewBuilder private func summaryButtons(_ proxy: ScrollViewProxy) -> some View {
        summaryButton("Due Today", count: openTodayTasks.count) { revealSection(.tasks, anchor: "today-tasks", proxy: proxy) }
        summaryButton("Overdue", count: repository.overdueTasks.count) { overdueExpanded = true; revealSection(.overdue, anchor: "today-overdue", proxy: proxy) }
        if repository.showsCalendarEvents {
            summaryButton("Events", count: todayEvents.filter { $0.endDate > now }.count) { revealSection(.calendar, anchor: "today-events", proxy: proxy) }
        } else {
            // Task-only Today: the third tile looks ahead instead of counting events.
            summaryButton("Tomorrow", count: tomorrowTaskCount) { tomorrowExpanded = true; revealSection(.tomorrow, anchor: "today-tomorrow", proxy: proxy) }
        }
    }
    private var timelineEntries: [TodayPlanning.TimelineEntry] {
        TodayPlanning.timeline(tasks: repository.tasks, events: repository.showsCalendarEvents ? todayEvents : [], now: now)
    }
    private var tomorrowTaskCount: Int {
        repository.upcomingTasks.filter { task in task.dueDate.map { Calendar.current.isDateInTomorrow($0) } == true }.count
    }
    private var availableGaps: [DayTimeGap] { TodayPlanning.gaps(timelineEntries, now: now) }
    private var focusTask: TaskItem? {
        let candidates = repository.tasks.filter { task in
            repository.isActionableToday(task) && repository.isFocusNextList(task.listID) && (repository.isTodayPriority(task) || task.dueDate == nil || task.dueDate! < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!)
        }
        let remaining = candidates.filter { !skippedFocusIDs.contains($0.id) }
        return (remaining.isEmpty ? candidates : remaining).sorted {
            let a = TodayPlanning.focusScore($0, pinned: repository.isTodayPriority($0), availableMinutes: availableGaps.first?.minutes, now: now)
            let b = TodayPlanning.focusScore($1, pinned: repository.isTodayPriority($1), availableMinutes: availableGaps.first?.minutes, now: now)
            return a == b ? $0.id < $1.id : a > b
        }.first
    }
    @ViewBuilder private func focusActions(_ task: TaskItem) -> some View {
        Button(completingFocusTask ? "Completing…" : "Mark Complete", systemImage: "checkmark") {
            guard !completingFocusTask else { return }
            completingFocusTask = true
            Task {
                await repository.toggleCompletion(for: task)
                completingFocusTask = false
            }
        }
        Button("Choose Another", systemImage: "arrow.triangle.2.circlepath") {
            if skippedFocusIDs.contains(task.id) { skippedFocusIDs = [task.id] } else { skippedFocusIDs.insert(task.id) }
        }
    }
    private func revealSection(_ section: TodayDashboardSection, anchor: String, proxy: ScrollViewProxy) {
        repository.setTodaySectionVisible(section, true)
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(anchor, anchor: .top) } }
    }
    private func summaryButton(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 10) {
                        Text(count, format: .number).font(.title3.bold()).monospacedDigit()
                        Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 3) {
                        Text(count, format: .number).font(.title3.bold()).monospacedDigit()
                        Text(title).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(6).background(repository.appTheme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius))
        }.buttonStyle(.plain).accessibilityLabel("\(count) \(title)")
    }
    @ViewBuilder private var eventSpotlight: some View {
        switch TodayPlanning.spotlight(todayEvents, now: now) {
        case .now(let event): spotlightCard(event, status: "Happening Now", time: "Until " + event.endDate.formatted(date: .omitted, time: .shortened))
        case .next(let event): spotlightCard(event, status: "Up Next", time: event.startDate.formatted(date: .omitted, time: .shortened))
        case .allDay(let event): spotlightCard(event, status: "On Your Calendar", time: "All Day")
        case .finished: Label("No more timed events today", systemImage: "calendar.badge.checkmark").foregroundStyle(.secondary)
        // Shown only while calendars are in use; connecting Calendar lives in Settings and the Calendar tab.
        case .empty: Label("Nothing scheduled on your calendar today", systemImage: "calendar").foregroundStyle(.secondary)
        }
    }
    private func spotlightCard(_ event: CalendarEvent, status: String, time: String) -> some View {
        Button { repository.selectedTaskID = nil; selectedCalendarEvent = event } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(status, systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(eventColor(event))
                Text(event.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Text(time).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }

    private func eventColor(_ event: CalendarEvent) -> Color {
        repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue
    }

    /// Flagged or high-priority work without a date in the next day, offered for planning (formerly Plan My Day).
    private var suggestedTasks: [TaskItem] {
        let calendar = Calendar.current
        return repository.tasks.filter { task in
            guard repository.isActionableToday(task), task.isFlagged || task.priority == .high else { return false }
            guard let due = task.dueDate else { return true }
            return !calendar.isDateInToday(due) && !calendar.isDateInTomorrow(due) && !task.isOverdue()
        }
    }

    @ViewBuilder private func taskSection(_ title: String, tasks: [TaskItem], canCommit: Bool = false, canDefer: Bool = false, footer: String? = nil) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) { task in
                    dashboardTaskRow(task, canCommit: canCommit, canDefer: canDefer)
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }
    private func dashboardTaskRow(_ task: TaskItem, canCommit: Bool = false, canDefer: Bool = false) -> some View {
                    TaskRowView(task: task, subtasks: [], isSelected: repository.selectedTaskID == task.id,
                                listColor: repository.lists.first { $0.id == task.listID }?.color ?? repository.appTheme.primary,
                                tagColor: repository.color(forTag:),
                                density: .comfortable, repository: repository)
                        .swipeActions(edge: .leading) {
                            if canCommit {
                                Button {
                                    Task { await repository.setDueDate(Calendar.current.startOfDay(for: Date()), hasDueTime: false, forTaskIDs: [task.id]) }
                                } label: {
                                    Label("Today", systemImage: "sun.max")
                                }
                                .tint(.yellow)
                            }
                            Button {
                                Task { await repository.toggleCompletion(for: task) }
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                        .swipeActions {
                            Button("Reschedule", systemImage: "calendar") { reschedulingTask = task }
                                .tint(.blue)
                            Button(role: .destructive) {
                                Task { await repository.deleteTask(task) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            if canDefer {
                                Button {
                                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                                    Task { await repository.setDueDate(tomorrow, hasDueTime: false, forTaskIDs: [task.id]) }
                                } label: {
                                    Label("Tomorrow", systemImage: "arrow.turn.up.right")
                                }
                                .tint(.indigo)
                            }
                            Button {
                                Task { await repository.setFlagged(!task.isFlagged, for: task) }
                            } label: {
                                Label(task.isFlagged ? "Unflag" : "Flag", systemImage: task.isFlagged ? "flag.slash" : "flag")
                            }
                            .tint(.orange)
                        }
    }

}
