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

struct CalendarBoardView: View {
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

        /// "Agenda" (not "List") so it is not confused with the List view mode.
        var displayName: String { rawValue }
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

struct MiniWeekStrip: View {
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

struct MiniCalendarDayCell: View {
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

struct SelectedDayAgendaView: View {
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

struct SelectedDayEventRow: View {
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

struct SelectedDayTaskRow: View {
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
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: task.isCompleted)
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

struct CalendarTaskMenu: View {
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

struct AgendaDay: Identifiable {
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

enum AgendaDayItem: Identifiable {
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

struct AgendaDaySection: View {
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
            .background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: TaskFlowTheme.panelRadius).strokeBorder(TaskFlowTheme.border, lineWidth: 1)
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
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: task.isCompleted)
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

struct CalendarHourGrid: View {
    let date: Date
    let events: [CalendarEvent]
    let settings: CalendarWorkspaceSettings
    @Binding var selectedEvent: CalendarEvent?
    let color: (String) -> Color

    private var calendar: Calendar { .current }
    private var firstHour: Int { settings.hideNonworkingHours ? min(max(settings.workStart, 0), 23) : 0 }
    private var lastHour: Int { settings.hideNonworkingHours ? min(max(settings.workEnd, firstHour + 1), 24) : 24 }
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
                                        .background(color(event.calendarID).opacity(0.18), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius))
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
