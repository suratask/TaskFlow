import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

struct AttachmentPreviewDocument: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        if priority != .none {
            Text(priority.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(color)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
        }
    }

    private var color: Color {
        switch priority {
        case .none: .secondary
        case .low: .secondary
        case .medium: .secondary
        case .high: .accentColor
        }
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Label(status.rawValue, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
    }

    private var icon: String {
        switch status {
        case .notStarted: "circle"
        case .active: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .blocked, .overdue: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .notStarted: .secondary
        case .active: .accentColor
        case .waiting: .secondary
        case .blocked: .secondary
        case .overdue: .red
        case .done: .secondary
        }
    }
}

struct TagCloud: View {
    let tags: [String]
    var colorForTag: (String) -> Color = { _ in .indigo }
    var onRemove: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                let color = colorForTag(tag)
                HStack(spacing: 4) {
                    Text("#\(tag)")
                    if let onRemove {
                        Button {
                            onRemove(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                        }
                        .foregroundStyle(color.opacity(0.8))
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous)
                        .strokeBorder(color.opacity(0.14), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(CGFloat.zero) { partial, subview in
            partial + subview.sizeThatFits(.unspecified).width + spacing
        }
        let maxWidth = max(1, proposal.width ?? max(1, naturalWidth - spacing))
        var size = CGSize.zero
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let subviewSize = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if lineWidth + subviewSize.width > maxWidth, lineWidth > 0 {
                size.width = max(size.width, lineWidth - spacing)
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }

        size.width = max(size.width, lineWidth - spacing)
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if point.x + size.width > bounds.maxX, point.x > bounds.minX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct TagSelectionEditor: View {
    let savedTags: [SavedTag]
    @Binding var selectedTags: [String]
    let colorForTag: (String) -> Color
    let onCreate: (String) -> Void
    @State private var newTag = ""

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(allTagNames, id: \.self) { name in
                Button { toggle(name) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: contains(name) ? "checkmark.circle.fill" : "number")
                        Text(name).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline.weight(contains(name) ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .foregroundStyle(colorForTag(name))
                    .background(colorForTag(name).opacity(contains(name) ? 0.18 : 0.07), in: Capsule())
                    .overlay(Capsule().stroke(colorForTag(name).opacity(contains(name) ? 0.6 : 0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tag " + name)
                .accessibilityAddTraits(contains(name) ? .isSelected : [])
            }
        }
        TextField("New Tag", text: $newTag)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.done).onSubmit(addTag)
    }

    /// Saved tags plus any already on this item, in alphabetical order.
    private var allTagNames: [String] {
        var names = savedTags.map(\.name)
        for tag in selectedTags where !names.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            names.append(tag)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func addTag() {
        let name = MetadataStore.normalizedTag(newTag)
        guard !name.isEmpty else { return }
        if !contains(name) { selectedTags.append(name) }
        onCreate(name)
        newTag = ""
    }

    private func toggle(_ name: String) {
        if contains(name) { selectedTags.removeAll { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        else { selectedTags.append(name) }
    }

    private func contains(_ name: String) -> Bool {
        selectedTags.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}

// Shared by the calendar location search and its selected-place presentation.
struct LocationLookupResult: Identifiable {
    let location: TaskLocation
    var id: String { location.id }

    init(mapItem: MKMapItem) {
        location = TaskLocation(
            title: mapItem.name ?? "",
            address: mapItem.placemark.title ?? "",
            latitude: mapItem.placemark.coordinate.latitude,
            longitude: mapItem.placemark.coordinate.longitude
        )
    }
}

struct LocationLookupRow: View {
    let result: LocationLookupResult

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.location.displayTitle).foregroundStyle(.primary)
                Text(result.location.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "mappin.circle").foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct PinnedLocationCard: View {
    let location: TaskLocation
    let onOpen: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                Label(location.displayTitle, systemImage: "map")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Clear Location", systemImage: "xmark.circle.fill", action: onClear)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
    }
}

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            if repository.accessState != .granted {
                Section {
                    Text(repository.accessState.message).foregroundStyle(.secondary)
                    if repository.accessState == .unknown {
                        Button("Continue") { Task { await repository.requestAccess() } }
                    }
                }
            }

            ForEach(repository.visibleTodaySections) { section in
                todaySection(section, proxy: proxy)
            }
            if repository.visibleTodaySections.allSatisfy({ !sectionHasContent($0) }) {
                Section {
                    Text("No items in your selected sections").foregroundStyle(.secondary)
                    Button("Choose Today’s Sections", systemImage: "slider.horizontal.3") { customizingToday = true }
                }
            }
            if let undo = repository.taskUndo {
                Section { Button("Undo " + undo.message, systemImage: "arrow.uturn.backward") { Task { await repository.undoLastTaskAction() } }.disabled(repository.isUndoing) }
            }
            if let error = repository.errorMessage { Section { Text(error).foregroundStyle(.red) } }


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
                    Button("New Event", systemImage: "calendar.badge.plus") { captureEventDraft = repository.makeEventDraft() }
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
        case .calendar: !todayEvents.isEmpty
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
                    if repository.eventAccessState == .granted {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let entries = TodayPlanning.timeline(tasks: repository.tasks, events: repository.calendarEvents, now: context.date)
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
                    } else {
                        Label("Connect Calendar to calculate available time", systemImage: "clock")
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }.buttonStyle(.plain)
                eventSpotlight
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
                if timelineEntries.isEmpty { Text("No timed tasks or events today").foregroundStyle(.secondary) }
                if repository.eventAccessState == .granted {
                    ForEach(availableGaps) { gap in
                        Label("Free " + gap.start.formatted(date: .omitted, time: .shortened) + " – " + gap.end.formatted(date: .omitted, time: .shortened) + " · " + gap.durationText, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else { Text("Connect Calendar to include events in available time.").foregroundStyle(.secondary) }
            } header: { Text("Combined Timeline") } footer: { Text("Task blocks start at their due time. Missing estimates use 30 minutes. Free time covers the rest of today; all-day events do not reserve time.") }
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
                }
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
        summaryButton("Events", count: todayEvents.filter { $0.endDate > now }.count) { revealSection(.calendar, anchor: "today-events", proxy: proxy) }
    }
    private var timelineEntries: [TodayPlanning.TimelineEntry] {
        TodayPlanning.timeline(tasks: repository.tasks, events: todayEvents, now: now)
    }
    private var availableGaps: [DayTimeGap] { TodayPlanning.gaps(timelineEntries, now: now) }
    private var focusTask: TaskItem? {
        let candidates = repository.tasks.filter { task in
            repository.isActionableToday(task) && (repository.isTodayPriority(task) || task.dueDate == nil || task.dueDate! < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!)
        }
        let remaining = candidates.filter { !skippedFocusIDs.contains($0.id) }
        return (remaining.isEmpty ? candidates : remaining).sorted {
            let a = TodayPlanning.focusScore($0, pinned: repository.isTodayPriority($0), availableMinutes: repository.eventAccessState == .granted ? availableGaps.first?.minutes : nil, now: now)
            let b = TodayPlanning.focusScore($1, pinned: repository.isTodayPriority($1), availableMinutes: repository.eventAccessState == .granted ? availableGaps.first?.minutes : nil, now: now)
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
            .padding(6).background(repository.appTheme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("\(count) \(title)")
    }
    @ViewBuilder private var eventSpotlight: some View {
        switch TodayPlanning.spotlight(todayEvents, now: now) {
        case .now(let event): spotlightCard(event, status: "Happening Now", time: "Until " + event.endDate.formatted(date: .omitted, time: .shortened))
        case .next(let event): spotlightCard(event, status: "Up Next", time: event.startDate.formatted(date: .omitted, time: .shortened))
        case .allDay(let event): spotlightCard(event, status: "On Your Calendar", time: "All Day")
        case .finished: Label("No more timed events today", systemImage: "calendar.badge.checkmark").foregroundStyle(.secondary)
        case .empty:
            if repository.eventAccessState == .granted { Label("Nothing scheduled on your calendar today", systemImage: "calendar").foregroundStyle(.secondary) }
            else { Button("Connect Calendar", systemImage: "calendar") { Task { await repository.requestEventCalendarAccess() } } }
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


/// Reminders-style "New Task" row: type a title, press Return, and keep going.
struct InlineNewTaskRow: View {
    enum DueChoice: String, CaseIterable, Identifiable {
        case none = "No Date"
        case today = "Today"
        case tomorrow = "Tomorrow"
        case nextWeek = "Next Week"
        var id: String { rawValue }
    }

    @Bindable var repository: TaskRepository
    var defaultDue: DueChoice = .none
    var defaultFlagged = false
    var onShowDetails: (TaskDraft) -> Void
    var onAdded: () -> Void = {}
    @State private var title = ""
    @State private var due: DueChoice?
    @State private var isFlagged = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(width: 30)
                .accessibilityHidden(true)
            TextField("New Task", text: $title)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(add)
            if isFocused {
                Menu {
                    Picker("Date", selection: Binding(get: { effectiveDue }, set: { due = $0 })) {
                        ForEach(DueChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: effectiveDue == .none ? "calendar" : "calendar.badge.checkmark")
                }
                .accessibilityLabel("Due date: \(effectiveDue.rawValue)")
                Button {
                    isFlagged.toggle()
                } label: {
                    Image(systemName: isFlagged ? "flag.fill" : "flag")
                        .foregroundStyle(isFlagged ? Color.orange : Color.accentColor)
                }
                .accessibilityLabel(isFlagged ? "Unflag" : "Flag")
                Button {
                    onShowDetails(makeDraft())
                    reset()
                    isFocused = false
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("More details")
            } else if isFlagged {
                Image(systemName: "flag.fill").foregroundStyle(.orange).accessibilityLabel("Flagged")
            }
        }
        .buttonStyle(.borderless)
        .id(InlineNewTaskRow.scrollID)
    }

    static let scrollID = "inline-new-task-row"

    private var effectiveDue: DueChoice { due ?? defaultDue }

    private func makeDraft() -> TaskDraft {
        var draft = repository.makeDraft()
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.isFlagged = isFlagged || defaultFlagged
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch effectiveDue {
        case .none: draft.dueDate = nil
        case .today: draft.dueDate = today
        case .tomorrow: draft.dueDate = calendar.date(byAdding: .day, value: 1, to: today)
        case .nextWeek: draft.dueDate = calendar.date(byAdding: .day, value: 7, to: today)
        }
        draft.hasDueTime = false
        return draft
    }

    private func add() {
        let draft = makeDraft()
        guard !draft.title.isEmpty, !draft.listID.isEmpty else {
            isFocused = false
            return
        }
        reset()
        isFocused = true
        Task {
            if await repository.saveTask(draft) {
                onAdded()
            }
        }
    }

    private func reset() {
        title = ""
        due = nil
        isFlagged = false
    }
}

/// One-time hint that the + button has more options on touch-and-hold.
struct AddMenuTip: Tip {
    var title: Text { Text("More Ways to Add") }
    var message: Text? { Text("Tap + for a new task. Touch and hold for a new event or Quick Capture.") }
    var image: Image? { Image(systemName: "plus.circle") }
}

/// One-time hint for planning swipes in Today's Suggested section.
struct PlanTodayTip: Tip {
    var title: Text { Text("Plan Your Day") }
    var message: Text? { Text("Swipe right on a suggested task to add it to Today. Swipe left on an overdue task to move it to tomorrow.") }
    var image: Image? { Image(systemName: "sun.max") }
}


struct EditableMediaLink: Identifiable {
    var id = UUID()
    var provider = ""
    var url = ""
    var region = ""
    var note = ""
    var link: ReadingMedia.WatchLink {
        .init(provider: provider.trimmingCharacters(in: .whitespacesAndNewlines), url: url.trimmingCharacters(in: .whitespacesAndNewlines), region: region.isEmpty ? nil : region, note: note.isEmpty ? nil : note)
    }
}

struct SpecializedTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let task: TaskItem
    let type: SpecializedListType
    @State private var details = SpecializedTaskDetails()
    @State private var saving = false
    @State private var initialized = false
    @State private var mediaTitle = ""
    @State private var mediaNote = ""
    @State private var mediaTags = ""
    @State private var mediaLinks: [EditableMediaLink] = []
    @State private var location: TaskLocation?
    @State private var originalLocation: TaskLocation?
    @State private var locationQuery = ""
    @State private var locationResults: [LocationLookupResult] = []
    @State private var searchingLocation = false
    @State private var locationError = ""
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { details.fields[key] ?? "" }, set: { details.fields[key] = $0 })
    }
    var body: some View {
        Form {
            if type == .reading {
                Section("Streaming Service (optional)") {
                    Picker("Service", selection: field("Streaming Service")) {
                        Text("Not Set").tag("")
                        ForEach(Array(Set(repository.streamingServiceChoices + [details.fields["Streaming Service"] ?? ""]).filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Other service", text: field("Streaming Service"))
                }
                Section("Title & Notes") {
                    TextField("Title", text: $mediaTitle, axis: .vertical)
                    TextField("Notes", text: $mediaNote, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    TextField("Tags separated by commas", text: $mediaTags, axis: .vertical).textInputAutocapitalization(.never)
                    let suggestions = ReadingMedia.suggestedTags(details.fields.merging(["Watch Links": ReadingMedia.encodeLinks(mediaLinks.map(\.link))]) { _, new in new })
                    ForEach(suggestions, id: \.self) { tag in
                        Toggle("#" + tag, isOn: Binding(get: { ReadingMedia.tagNames(mediaTags).contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }, set: { included in
                            var tags = ReadingMedia.tagNames(mediaTags)
                            if included { tags.append(tag) } else { tags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
                            mediaTags = Array(Set(tags)).sorted().joined(separator: ", ")
                        }))
                    }
                } header: { Text("Tags") } footer: { Text("Type and service tags are added on capture. Genre suggestions come from the page; you choose which to keep.") }
                if details.fields["Local Preview"] != nil || !(details.fields["Thumbnail URL"] ?? "").isEmpty {
                    Section {
                        Button("Remove Preview", role: .destructive) {
                            details.fields.removeValue(forKey: "Local Preview")
                            details.fields["Thumbnail URL"] = ""
                            details.fields["Suppress Preview"] = "true"
                        }
                    }
                }
                Section {
                    ForEach($mediaLinks) { $link in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Service or source", text: $link.provider)
                            ListURLField(title: "Link", value: $link.url)
                            TextField("Country (optional)", text: $link.region)
                            TextField("Subscription, rental, or availability note", text: $link.note, axis: .vertical)
                            Button("Remove Link", role: .destructive) { mediaLinks.removeAll { $0.id == link.id } }
                        }
                    }
                    Button("Add Watch Link", systemImage: "link.badge.plus") { mediaLinks.append(EditableMediaLink()) }
                    Menu("Choose Service Name") {
                        ForEach(repository.streamingServiceChoices, id: \.self) { service in
                            Button(service) { mediaLinks.append(EditableMediaLink(provider: service)) }
                        }
                    }
                } header: { Text(ReadingMedia.action(for: ReadingMedia.displayFormat(details.fields)) == "Watch" ? "Where to Watch · Saved Links" : "Source Links") } footer: { Text("These are saved links, not verified availability. Add a country or access note when useful. Clear Source Link as well to remove the original capture link.") }
            }
            Section {
                ForEach(type.fields.filter { !["Follow-up Date", "Essential", "Next Action", "Required", "Rating", "Shopping List ID"].contains($0) && !(type == .appointments && ["Preparation", "Questions", "Outcome"].contains($0)) && repository.listProfile(task.listID).settings["Hidden Field " + $0] != "true" }, id: \.self) { key in
                    if ["Renewal Date", "Notice Date", "Cancellation Deadline"].contains(key) {
                        Toggle(key, isOn: Binding(get: { !(details.fields[key] ?? "").isEmpty }, set: { details.fields[key] = $0 ? SpecializedTaskDetails.dateText(Date()) : "" }))
                        if !(details.fields[key] ?? "").isEmpty {
                            DatePicker(key, selection: Binding(get: { SpecializedTaskDetails.dateValue(details.fields[key] ?? "") ?? Date() }, set: { details.fields[key] = SpecializedTaskDetails.dateText($0) }), displayedComponents: .date)
                        }
                    } else if type == .reading, key == "Format" {
                        Picker("Media Type", selection: field(key)) {
                            Text("Not Set").tag("")
                            ForEach(ReadingMedia.formats, id: \.self) { Text($0).tag($0) }
                            if let existing = details.fields[key], !existing.isEmpty, !ReadingMedia.formats.contains(existing) { Text(existing).tag(existing) }
                        }
                    } else if ListFieldNumber.keys.contains(key) {
                        ListNumberField(title: key, value: field(key), integer: ListFieldNumber.integer(key), minimum: ListFieldNumber.minimum(key))
                    } else if ["Room", "Provider", "Milestone", "Section", "Category", "Destination", "Contact"].contains(key) {
                        NavigationLink {
                            ListFieldPicker(title: key, value: field(key), choices: repository.listFieldChoices(key, listID: task.listID))
                        } label: { LabeledContent(key, value: details.fields[key].flatMap { $0.isEmpty ? nil : $0 } ?? "Not Set") }
                    } else if ["Source Link", "Thumbnail URL", "Payment Link"].contains(key) {
                        ListURLField(title: key, value: field(key))
                    } else {
                        TextField(key, text: field(key), axis: .vertical).lineLimit(1...5)
                    }
                }
                ForEach(type.fields.filter { ["Essential", "Next Action", "Required"].contains($0) && repository.listProfile(task.listID).settings["Hidden Field " + $0] != "true" }, id: \.self) { key in
                    Toggle(key, isOn: Binding(get: { details.fields[key] == "Yes" }, set: { details.fields[key] = $0 ? "Yes" : "No" }))
                }
                if type == .reading, repository.listProfile(task.listID).settings["Hidden Field Rating"] != "true" { Picker("Rating", selection: field("Rating")) { Text("Unrated").tag(""); ForEach(1...5, id: \.self) { Text("\($0) stars").tag(String($0)) } } }
                if type == .errands, repository.listProfile(task.listID).settings["Hidden Field Shopping List ID"] != "true" {
                    Picker("Shopping List", selection: field("Shopping List ID")) {
                        Text("None").tag("")
                        ForEach(repository.lists.filter { repository.listProfile($0.id).type == .shopping }) { Text($0.title).tag($0.id) }
                    }
                }
                if type == .appointments {
                    NavigationLink {
                        EventLinkPicker(repository: repository, selection: field("Event ID"))
                    } label: {
                        LabeledContent("Linked Event", value: repository.calendarEvents.first { $0.id == details.fields["Event ID"] }?.title ?? "Choose Event")
                    }
                    Toggle("Follow-up Reminder", isOn: Binding(get: { !(details.fields["Follow-up Date"] ?? "").isEmpty }, set: { details.fields["Follow-up Date"] = $0 ? SpecializedTaskDetails.dateText(Date()) : "" }))
                    if !(details.fields["Follow-up Date"] ?? "").isEmpty {
                        DatePicker("Follow-up Date", selection: Binding(get: {
                            return SpecializedTaskDetails.dateValue(details.fields["Follow-up Date"] ?? "") ?? Date()
                        }, set: { details.fields["Follow-up Date"] = SpecializedTaskDetails.dateText($0) }), displayedComponents: .date)
                    }
                }
                if !type.stages.isEmpty {
                    Picker(type == .reading ? "Progress" : "Stage", selection: field(type == .reading ? "Progress" : "Stage")) {
                        Text("Not Set").tag("")
                        ForEach(type.stages, id: \.self) { Text($0).tag($0) }
                    }
                }
                if type == .shopping { Toggle("Favorite purchase", isOn: $details.isFavorite) }
                if type == .household {
                    Toggle("Repeat after completion", isOn: Binding(get: { details.repeatAfterDays != nil }, set: { details.repeatAfterDays = $0 ? 7 : nil }))
                    if details.repeatAfterDays != nil {
                        Stepper("Every \(details.repeatAfterDays ?? 7) days", value: Binding(get: { details.repeatAfterDays ?? 7 }, set: { details.repeatAfterDays = $0 }), in: 1...3650)
                        Text("Creates a new reminder after completion. Disable native repeat to use this schedule.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text(type.rawValue) } footer: { Text(type.syncExplanation) }
            if type == .errands { errandLocationSection }
            if type == .appointments {
                if repository.listProfile(task.listID).settings["Hidden Field Preparation"] != "true" { Section("Before · Preparation") { TextField("One preparation step per line", text: field("Preparation"), axis: .vertical).lineLimit(2...6) } }
                if repository.listProfile(task.listID).settings["Hidden Field Questions"] != "true" { Section("During · Questions") { TextField("Questions to ask", text: field("Questions"), axis: .vertical).lineLimit(2...6) } }
                if repository.listProfile(task.listID).settings["Hidden Field Outcome"] != "true" { Section("After · Outcome") { TextField("Outcome and next steps", text: field("Outcome"), axis: .vertical).lineLimit(2...6) } }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle(type == .reading ? "Edit Media" : type.detailsTitle)
        .navigationBarTitleDisplayMode(type == .reading ? .inline : .automatic)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") {
            saving = true
            Task {
                var saved = details
                for key in ListFieldNumber.keys where !(saved.fields[key] ?? "").isEmpty {
                    let raw = saved.fields[key] ?? ""
                    if let number = Double(raw.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")), number.isFinite { saved.fields[key] = ShoppingQuantity.text(number) }
                }
                if type == .errands, let location, (saved.fields["Destination"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saved.fields["Destination"] = location.displayTitle
                }
                if type == .reading { saved.fields["Watch Links"] = ReadingMedia.encodeLinks(mediaLinks.map(\.link)) }
                var succeeded = type == .reading
                    ? await repository.saveMediaItem(saved, title: mediaTitle, note: mediaNote, tags: ReadingMedia.tagNames(mediaTags), for: task)
                    : await repository.saveSpecializedDetails(saved, for: task, type: type)
                if succeeded, type == .errands, location != originalLocation {
                    // The place is saved on the reminder, where Reminders delivers its arrival alert.
                    var draft = TaskDraft(task: repository.tasks.first { $0.id == task.id } ?? task)
                    draft.location = location
                    succeeded = await repository.saveTask(draft)
                }
                if succeeded { dismiss() }
                saving = false
            }
        }.disabled(saving || searchingLocation || !validFields) } }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            details = repository.specializedDetails(task)
            if type == .reading {
                mediaTitle = task.title
                mediaNote = task.notes
                mediaTags = task.tags.joined(separator: ", ")
                mediaLinks = ReadingMedia.watchLinks(details.fields).map { EditableMediaLink(provider: $0.provider, url: $0.url, region: $0.region ?? "", note: $0.note ?? "") }
                details.fields["Format"] = ReadingMedia.displayFormat(details.fields)
            }
            location = (repository.tasks.first { $0.id == task.id } ?? task).location
            originalLocation = location
        }
    }

    private var validFields: Bool {
        if type == .reading {
            guard !mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            for link in mediaLinks {
                guard !link.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let url = URL(string: link.url), ReadingMedia.isWebURL(url) else { return false }
            }
            for key in ["Source Link", "Thumbnail URL"] {
                let raw = details.fields[key] ?? ""
                if !raw.isEmpty, URL(string: raw).map(ReadingMedia.isWebURL) != true { return false }
            }
        }
        for key in ListFieldNumber.keys where type.fields.contains(key) && repository.listProfile(task.listID).settings["Hidden Field " + key] != "true" {
            let raw = details.fields[key] ?? ""
            if !raw.isEmpty, ListFieldNumber.parse(raw, key: key) == nil { return false }
        }
        return true
    }

    @ViewBuilder private var errandLocationSection: some View {
        Section {
            if let current = location {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.displayTitle)
                        if current.displayAddress != current.displayTitle { Text(current.displayAddress).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: "mappin.circle.fill").foregroundStyle(.tint) }
                if current.latitude != nil, current.longitude != nil {
                    Picker("Remind Me", selection: Binding(get: { location?.proximity ?? .onArrival }, set: { location?.proximity = $0 })) {
                        ForEach(LocationProximity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Radius: \(Int(current.radius)) m", value: Binding(get: { location?.radius ?? 100 }, set: { location?.radius = $0 }), in: 50...1000, step: 50)
                }
                Button("Remove Place", role: .destructive) { location = nil }
            }
            HStack {
                TextField(location == nil ? "Search for a store or address" : "Change place", text: $locationQuery)
                    .onSubmit { searchLocation() }
                    .submitLabel(.search)
                if searchingLocation { ProgressView() }
            }
            ForEach(locationResults) { result in
                Button {
                    var chosen = result.location
                    chosen.radius = location?.radius ?? 100
                    chosen.proximity = location?.proximity ?? .onArrival
                    location = chosen
                    locationResults = []
                    locationQuery = ""
                } label: { LocationLookupRow(result: result) }
                    .tint(.primary)
            }
        } header: { Text("Place") } footer: {
            if !locationError.isEmpty { Text(locationError) }
            else { Text("Choose a place to get a Reminders alert when you arrive, and to open it in Maps.") }
        }
    }

    private func searchLocation() {
        let query = locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchingLocation, !query.isEmpty else { return }
        searchingLocation = true
        locationError = ""
        Task {
            defer { searchingLocation = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                let response = try await MKLocalSearch(request: request).start()
                locationResults = response.mapItems.prefix(5).map(LocationLookupResult.init(mapItem:))
                if locationResults.isEmpty { locationError = "No places found. Try a more specific name or address." }
            } catch { locationError = error.localizedDescription }
        }
    }
}

struct SpecializedTaskListView: View {
    @State private var artworkItem: TaskItem?
    @State private var showingListCleanup = false
    @State private var trackedShow: TaskItem?
    @Bindable var repository: TaskRepository
    let listID: String
    var viewMode: TaskRepository.TaskViewMode = .list
    @Binding var editorDraft: TaskDraft?
    @State private var pendingFilterTool: String?
    @State private var showingMediaFilters = false
    @State private var mediaProviderFilter = ""
    @State private var mediaFormatFilter = ""
    @State private var showingFilters = false
    @State private var selectingItems = false
    @State private var selectedIDs: Set<String> = []
    @State private var showingBulkEditor = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var recentPurchase: SpecializedListTemplate.Item?
    @State private var shoppingMode = false
    @State private var showFavorites = false
    @State private var showPreviousRuns = false
    @State private var groupByStore = false
    @State private var storeFilter: String?
    @State private var newSection = ""
    @State private var addingSection = false
    @State private var showsTemplates = false
    @State private var showingShoppingCategories = false
    @State private var timerEnd: Date?
    @State private var timerStep = ""
    @State private var showingNextActions = false
    @State private var linkedEvent: CalendarEvent?
    @State private var editingItem: TaskItem?
    @State private var showingSettings = false
    @State private var showingBulkCapture = false
    @State private var showingReadingCapture = false
    @State private var checklistTask: TaskItem?
    @State private var remainingOnly = false
    @State private var watchSort = "Recently Watched"
    @State private var sortByName = false
    @State private var completedExpanded = false
    @State private var pendingClearIDs: Set<String> = []
    @State private var clearingCompleted = false
    @State private var showingBuyAgain = false
    @State private var repeatPurchase: TaskItem?
    @State private var editingShoppingPrice: TaskItem?
    @State private var showingPriceEntry = false
    @State private var priceEntryIDs: [String] = []
    @State private var pendingShoppingDelete: TaskItem?
    @State private var deletingShoppingIDs: Set<String> = []
    @State private var shoppingDeleteError: String?
    @State private var collapsed: Set<String> = []
    @Environment(\.openURL) private var openURL
    private func persistPreferences() {
        var profile = repository.listProfile(listID)
        profile.settings["Media Provider Filter"] = mediaProviderFilter
        profile.settings["Media Format Filter"] = mediaFormatFilter
        profile.settings["Shopping Mode"] = String(shoppingMode)
        profile.settings["Group Store"] = String(groupByStore)
        profile.settings["Store Filter"] = storeFilter
        profile.settings["Favorites Only"] = String(showFavorites)
        profile.settings["Watch Sort"] = watchSort
        profile.settings["Sort Name"] = String(sortByName)
        profile.settings["Completed Expanded"] = String(completedExpanded)
        profile.settings["Collapsed"] = (try? String(data: JSONEncoder().encode(Array(collapsed)), encoding: .utf8)) ?? "[]"
        repository.setListProfile(profile, for: listID)
    }
    private var type: SpecializedListType { repository.listProfile(listID).type }
    private var items: [TaskItem] {
        let roots = repository.rootTasks
        let rootIDs = Set(roots.map(\.id))
        let finishedWatchItems = type == .reading ? repository.tasks.filter {
            $0.parentID == nil && $0.isCompleted && !rootIDs.contains($0.id) && ReadingMedia.action(for: ReadingMedia.displayFormat(repository.specializedDetails($0).fields)) == "Watch"
        } : []
        let values = (roots + finishedWatchItems).filter { $0.listID == listID && (type != .shopping || repository.shoppingTask($0, matchesStore: storeFilter)) && (type != .shopping || !showFavorites || repository.specializedDetails($0).isFavorite) && (showPreviousRuns || repository.listProfile(listID).settings["Current Run"] == nil || repository.specializedDetails($0).fields["Run ID"] == repository.listProfile(listID).settings["Current Run"]) }
        let visible = values.filter { mediaMatches($0) && (!$0.isCompleted || (type == .reading && ReadingMedia.action(for: ReadingMedia.displayFormat(repository.specializedDetails($0).fields)) == "Watch")) && (!remainingOnly || !["Packed", "Finished", "Paid"].contains(repository.specializedDetails($0).fields["Stage"] ?? "")) }
        if type == .reading {
            return visible.sorted { lhs, rhs in
                let left = repository.specializedDetails(lhs).fields
                let right = repository.specializedDetails(rhs).fields
                if watchSort != "Title" {
                    let a = watchSort == "New Releases" ? ReadingMedia.newestUnwatchedRelease(left) : left["Last Watched At"].flatMap { ISO8601DateFormatter().date(from: $0) }
                    let b = watchSort == "New Releases" ? ReadingMedia.newestUnwatchedRelease(right) : right["Last Watched At"].flatMap { ISO8601DateFormatter().date(from: $0) }
                    if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        if sortByName { return visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        if type == .routines { return visible.sorted { (Int(repository.specializedDetails($0).fields["Step Order"] ?? "") ?? Int.max) < (Int(repository.specializedDetails($1).fields["Step Order"] ?? "") ?? Int.max) } }
        return visible
    }
    private var unpricedShoppingItems: [TaskItem] {
        items.filter {
            guard let price = Double(repository.specializedDetails($0).fields["Price"] ?? "") else { return true }
            return !price.isFinite || price < 0
        }
    }
    private var progressTasks: [TaskItem] {
        repository.tasks.filter { task in
            task.listID == listID && task.parentID == nil && mediaMatches(task) && (type != .shopping || repository.shoppingTask(task, matchesStore: storeFilter)) && (showPreviousRuns || repository.listProfile(listID).settings["Current Run"] == nil || repository.specializedDetails(task).fields["Run ID"] == repository.listProfile(listID).settings["Current Run"])
        }
    }
    private func mediaMatches(_ task: TaskItem) -> Bool {
        guard type == .reading else { return true }
        let fields = repository.specializedDetails(task).fields
        return fields["Merged Into"] == nil && (mediaFormatFilter.isEmpty || ReadingMedia.displayFormat(fields) == mediaFormatFilter) && (mediaProviderFilter.isEmpty || fields["Streaming Service"]?.localizedCaseInsensitiveCompare(mediaProviderFilter) == .orderedSame || ReadingMedia.watchLinks(fields).contains { $0.provider.localizedCaseInsensitiveCompare(mediaProviderFilter) == .orderedSame })
    }
    private var mediaProviders: [String] {
        Array(Set(repository.rootTasks.filter { $0.listID == listID && repository.specializedDetails($0).fields["Merged Into"] == nil }.flatMap { ReadingMedia.watchLinks(repository.specializedDetails($0).fields).map(\.provider) + [repository.specializedDetails($0).fields["Streaming Service"] ?? ""] })).filter { !$0.isEmpty }.sorted()
    }
    @ViewBuilder private func readingHeader(_ progress: [TaskItem]) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(progress.filter { !$0.isCompleted }.count) saved").foregroundStyle(.secondary)
                Button("Save Link", systemImage: "link.badge.plus") { showingReadingCapture = true }.labelStyle(.titleAndIcon)
                Button("Filters", systemImage: "line.3.horizontal.decrease") { showingMediaFilters = true }.labelStyle(.titleAndIcon)
            }.font(.subheadline).buttonStyle(.borderless)
        } else {
            HStack {
                Text("\(progress.filter { !$0.isCompleted }.count) saved").foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Button("Save Link", systemImage: "link.badge.plus") { showingReadingCapture = true }.labelStyle(.titleAndIcon).fixedSize()
                Button { showingMediaFilters = true } label: { Image(systemName: mediaProviderFilter.isEmpty && mediaFormatFilter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }.accessibilityLabel("Filter media")
            }.font(.subheadline).buttonStyle(.borderless)
        }
        if !mediaProviderFilter.isEmpty || !mediaFormatFilter.isEmpty {
            HStack {
                Text([mediaProviderFilter, mediaFormatFilter].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Filters") { mediaProviderFilter = ""; mediaFormatFilter = "" }.font(.caption)
            }
        }
        NavigationLink {
            UpcomingWatchReleases(repository: repository, listID: listID)
        } label: {
            Label("Upcoming Episodes", systemImage: "calendar.badge.clock")
                .font(.subheadline)
        }
    }
    private var mediaFilters: some View {
        NavigationStack {
            Form {
                Section("Media Type") { Picker("Type", selection: $mediaFormatFilter) { Text("All Types").tag(""); ForEach(ReadingMedia.formats, id: \.self) { Text($0).tag($0) } } }
                Section("Saved Service or Source") { Picker("Provider", selection: $mediaProviderFilter) { Text("All Providers").tag(""); ForEach(Array(Set(mediaProviders + (mediaProviderFilter.isEmpty ? [] : [mediaProviderFilter]))).sorted(), id: \.self) { Text($0).tag($0) } } }
                Button("Reset Filters") { mediaProviderFilter = ""; mediaFormatFilter = "" }
            }
            .navigationTitle("Media Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMediaFilters = false } } }
        }
    }
    private var filteredCompletedIDs: Set<String> { Set(progressTasks.filter(\.isCompleted).map(\.id)) }
    private var storeChoices: [String] {
        var stores = repository.shoppingStores(for: listID)
        if let storeFilter, !storeFilter.isEmpty, !stores.contains(storeFilter) { stores.append(storeFilter) }
        return stores.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var groups: [String] {
        var values = Set(items.map { group($0) })
        if type == .projects {
            values.formUnion((repository.listProfile(listID).settings["Sections"] ?? "").split(separator: "\n").map(String.init))
        }
        let order = type == .shopping && !groupByStore ? repository.shoppingCategoryOrder(listID: listID, store: storeFilter) : (repository.listProfile(listID).settings["Aisle Order"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let effectiveOrder = type == .reading ? ReadingMedia.watchGroupOrder : order
        return values.sorted {
            let left = effectiveOrder.firstIndex(of: $0) ?? Int.max
            let right = effectiveOrder.firstIndex(of: $1) ?? Int.max
            return left == right ? $0.localizedStandardCompare($1) == .orderedAscending : left < right
        }
    }
    private func group(_ task: TaskItem) -> String {
        let fields = repository.specializedDetails(task).fields
        if type == .reading, ReadingMedia.action(for: ReadingMedia.displayFormat(fields)) == "Watch" {
            return ReadingMedia.watchGroup(fields, completed: task.isCompleted)
        }
        let value = repository.specializedDetails(task).fields[type == .shopping && groupByStore ? "Store" : type.groupField] ?? ""
        return value.isEmpty ? (type == .reading ? "Saved" : "Other") : (type == .shopping && !groupByStore ? ShoppingCatalog.canonicalCategory(value) : value)
    }
    var body: some View {
        let visible = items
        let progress = progressTasks
        let rowsByGroup = Dictionary(grouping: visible, by: group)
        let progressByGroup = Dictionary(grouping: progress, by: group)
        let completed = progress.filter { $0.isCompleted && !(type == .reading && ReadingMedia.action(for: ReadingMedia.displayFormat(repository.specializedDetails($0).fields)) == "Watch") }
        let sectionNames = groups
        let milestoneMembers = Dictionary(grouping: progress, by: { repository.specializedDetails($0).fields["Milestone"] ?? "" })
        let milestones = milestoneMembers.mapValues { (done: $0.filter { $0.isCompleted }.count, total: $0.count) }
        Group {
        if type == .projects && viewMode == .board && !dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
            if visible.isEmpty { ContentUnavailableView(type == .shopping && emptyState == .finished ? "All done shopping" : emptyState.title(type: type), systemImage: type.icon, description: Text(type == .reading && (!mediaFormatFilter.isEmpty || !mediaProviderFilter.isEmpty) ? "Clear your filters to see all saved titles." : emptyState.message(type: type))) }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(sectionNames.isEmpty ? ["Other"] : sectionNames, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(section).font(.headline); Spacer(); Text("\(rowsByGroup[section, default: []].count)").foregroundStyle(.secondary) }
                            let members = progressByGroup[section, default: []]
                            workflowSummary(members)
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(rowsByGroup[section, default: []]) { task in
                                        itemRow(task, milestones: milestones, sections: sectionNames).padding(12).background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: 12)).draggable(task.id)
                                    }
                                }
                            }
                            Button("Add Task", systemImage: "plus") { editorDraft = repository.makeDraft() }
                        }.padding(12).frame(width: 300, height: 480)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .dropDestination(for: String.self) { ids, _ in
                            let dropped = visible.filter { ids.contains($0.id) }
                            guard !dropped.isEmpty else { return false }
                            repository.moveProjectItems(dropped, to: section)
                            return true
                        }
                    }
                }.padding(12)
            }
            }
        } else {
        List {
            Section {
                if type == .shopping { shoppingHeader(progress) }
                else if type == .reading { readingHeader(progress) }
                else { Label(type.rawValue, systemImage: type.icon).font(.headline); workflowSummary(progress) }
                if type == .packing { Toggle("Still to Pack", isOn: $remainingOnly) }
                if type == .routines, let current = visible.first {
                    VStack(alignment: .leading) {
                        Text("Current Step").font(.caption).foregroundStyle(.secondary)
                        Text(current.title).font(.headline)
                        HStack {
                            Button("Complete & Next", systemImage: "checkmark.circle") { Task { await repository.toggleCompletion(for: current) } }
                            if timerEnd == nil { Button("Start Timer", systemImage: "timer") { startTimer(for: current) } }
                        }.buttonStyle(.borderless)
                    }
                }
                if type == .packing {
                    Text(repository.listProfile(listID).settings["Trip"] ?? "Packing List")
                    if let dates = repository.listProfile(listID).settings["Travel Dates"], !dates.isEmpty { Text(dates).foregroundStyle(.secondary) }
                }
                if type == .projects {
                    let nextCount = repository.projectNextActions.count
                    Button { showingNextActions = true } label: {
                        LabeledContent { Text("\(nextCount)") } label: { Label("Next Actions in All Projects", systemImage: "arrow.right.circle") }
                    }
                }
                if type == .bills {
                    ForEach(billTotals.keys.sorted(), id: \.self) { currency in
                        LabeledContent("Open total" + (currency == "Unspecified" ? " (no currency)" : ""), value: SpecializedFieldFormat.amount(billTotals[currency, default: 0], currency: currency == "Unspecified" ? nil : currency))
                    }
                    ForEach(monthlyBillTotals.keys.sorted(), id: \.self) { currency in
                        LabeledContent("Due this month" + (currency == "Unspecified" ? " (no currency)" : ""), value: SpecializedFieldFormat.amount(monthlyBillTotals[currency, default: 0], currency: currency == "Unspecified" ? nil : currency))
                    }
                    Text("Totals include open bills with a valid amount. Due dates and recurrence are set in task details.").font(.caption).foregroundStyle(.secondary)
                }
                if type == .routines, let timerEnd {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Timer")
                            if !timerStep.isEmpty { Text(timerStep).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(timerInterval: Date()...max(Date(), timerEnd), countsDown: true).monospacedDigit()
                    }
                    Button("Stop Timer", role: .destructive) {
                        self.timerEnd = nil
                        Task { await RoutineTimerCoordinator.stop(listID: listID) }
                    }
                    Text("Keeps running on the Lock Screen and alerts you when it ends.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if visible.isEmpty {
                ContentUnavailableView(type == .reading && (!mediaFormatFilter.isEmpty || !mediaProviderFilter.isEmpty) ? "No Matching Titles" : emptyState.title(type: type), systemImage: emptyState == .finished ? "checkmark.circle" : type.icon, description: Text(emptyState.message(type: type)))
                if emptyState == .filtered || (type == .reading && (!mediaFormatFilter.isEmpty || !mediaProviderFilter.isEmpty)) { Button("Reset Filters", systemImage: "line.3.horizontal.decrease") { storeFilter = nil; showFavorites = false; remainingOnly = false; showPreviousRuns = true; mediaProviderFilter = ""; mediaFormatFilter = "" } }
                Button("Add Item", systemImage: "plus") { editorDraft = repository.makeDraft() }
                if type == .shopping {
                    Button("Paste Items", systemImage: "text.badge.plus") { showingBulkCapture = true }
                    Button("Buy Again", systemImage: "cart.badge.plus") { showingBuyAgain = true }
                }
            }
            ForEach(sectionNames, id: \.self) { section in
                Section {
                    if type == .reading {
                        Button {
                            if collapsed.contains(section) { collapsed.remove(section) }
                            else { collapsed.insert(section) }
                            persistPreferences()
                        } label: {
                            HStack {
                                Text(section).font(.headline).foregroundStyle(.primary)
                                Spacer()
                                Text("\(rowsByGroup[section, default: []].count)").foregroundStyle(.secondary)
                                Image(systemName: collapsed.contains(section) ? "chevron.right" : "chevron.down")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityValue(collapsed.contains(section) ? "Collapsed" : "Expanded")
                        if !collapsed.contains(section) {
                            ForEach(rowsByGroup[section, default: []]) { task in
                                itemRow(task, milestones: milestones, sections: sectionNames)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    } else {
                    DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(section) }, set: { expanded in
                        if expanded { collapsed.remove(section) } else { collapsed.insert(section) }; persistPreferences()
                    })) {
                        ForEach(rowsByGroup[section, default: []]) { task in itemRow(task, milestones: milestones, sections: sectionNames) }
                    } label: {
                        HStack { Text(section).font(.headline); Spacer(); Text("\(rowsByGroup[section, default: []].count)").foregroundStyle(.secondary) }
                        if type == .packing || type == .projects {
                            let members = progressByGroup[section, default: []]
                            workflowSummary(members)
                        }
                    }
                    }
                }
            }
            if !(type == .packing && remainingOnly), !completed.isEmpty {
                Section {
                    if type == .reading {
                        Button { completedExpanded.toggle() } label: {
                            HStack {
                                Text("Finished (\(completed.count))").font(.headline)
                                Spacer()
                                Image(systemName: completedExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }.foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityValue(completedExpanded ? "Expanded" : "Collapsed")
                        if completedExpanded {
                            ForEach(completed) {
                                itemRow($0, milestones: milestones, sections: sectionNames)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    } else {
                        DisclosureGroup("\(type == .shopping ? "Purchased" : "Completed") (\(completed.count))", isExpanded: $completedExpanded) {
                            ForEach(completed) { itemRow($0, milestones: milestones, sections: sectionNames) }
                        }
                    }
                    if type == .shopping {
                        Button("Clear Completed", systemImage: "trash", role: .destructive) { pendingClearIDs = filteredCompletedIDs }
                            .disabled(clearingCompleted || repository.isUndoing)
                    }
                }
            }
            if let action = repository.taskUndo {
                Section { Button("Undo " + action.message, systemImage: "arrow.uturn.backward") { Task { await repository.undoLastTaskAction() } } }
            }
        }
        }
        }
        .safeAreaInset(edge: .bottom) {
            if type == .shopping, !selectingItems {
                shoppingBudgetSummary(progressTasks).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
            }
            if selectingItems {
                VStack(spacing: 8) {
                    Text("\(selectedIDs.count) selected").font(.subheadline)
                    HStack {
                        Button("Select Visible") { selectedIDs = Set(items.map(\.id)) }
                        Spacer()
                        Button("Edit") { showingBulkEditor = true }.disabled(selectedIDs.isEmpty || repository.isUndoing)
                        Button("Done") { selectingItems = false; selectedIDs = [] }
                    }.buttonStyle(.borderless)
                }.padding().background(.regularMaterial)
            }
        }
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        .onChange(of: listID) { selectingItems = false; selectedIDs = [] }
        .task(id: timerEnd) {
            // Clear the finished countdown; the notification and Live Activity report completion.
            guard let timerEnd else { return }
            try? await Task.sleep(for: .seconds(max(0, timerEnd.timeIntervalSinceNow)))
            if !Task.isCancelled { loadTimer() }
        }
        .onChange(of: listID) { loadTimer() }
        .onAppear {
            loadTimer()
            let settings = repository.listProfile(listID).settings
            mediaProviderFilter = settings["Media Provider Filter"] ?? ""
            mediaFormatFilter = settings["Media Format Filter"] ?? ""
            shoppingMode = settings["Shopping Mode"] == "true"
            groupByStore = settings["Group Store"] == "true"
            storeFilter = settings["Store Filter"]
            showFavorites = settings["Favorites Only"] == "true"
            watchSort = settings["Watch Sort"] ?? (settings["Sort Name"] == "true" ? "Title" : "Recently Watched")
            sortByName = settings["Sort Name"] == "true"
            completedExpanded = settings["Completed Expanded"] == "true"
            collapsed = Set(settings["Collapsed"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
            if type == .reading, settings["Episode Grouping Version"] != "1" {
                collapsed.formUnion(["Finished Series", "Finished", "Dropped"])
                var profile = repository.listProfile(listID)
                profile.settings["Episode Grouping Version"] = "1"
                repository.setListProfile(profile, for: listID)
                persistPreferences()
            }
        }
        .onChange(of: mediaProviderFilter) { persistPreferences() }
        .onChange(of: mediaFormatFilter) { persistPreferences() }
        .sheet(isPresented: $showingListCleanup) { ListCleanupView(repository: repository, listID: listID) }
        .sheet(item: $trackedShow) { item in WatchShowTracker(repository: repository, taskID: item.id) }
        .sheet(item: $artworkItem) { item in
            NavigationStack { ShowArtworkPicker(title: item.title) { show in
                Task { _ = await repository.applyShowArtwork(show, to: item) }
            } }
        }
        .sheet(isPresented: $showingMediaFilters) { mediaFilters }
        .onChange(of: shoppingMode) { persistPreferences() }
        .onChange(of: groupByStore) { persistPreferences() }
        .onChange(of: storeFilter) { persistPreferences() }
        .onChange(of: showFavorites) { persistPreferences() }
        .onChange(of: watchSort) { _, _ in persistPreferences() }
        .onChange(of: sortByName) { persistPreferences() }
        .onChange(of: completedExpanded) { persistPreferences() }
        .sheet(item: $editingItem) { task in NavigationStack { if type == .shopping { ShoppingItemEditor(repository: repository, draft: TaskDraft(task: task), task: task) } else { SpecializedTaskEditor(repository: repository, task: task, type: type) } } }
        .sheet(item: $checklistTask) { task in SpecializedChecklistView(repository: repository, task: task) }
        .sheet(isPresented: $showingFilters, onDismiss: {
            switch pendingFilterTool {
            case "paste": showingBulkCapture = true
            case "again": showingBuyAgain = true
            case "prices": showingPriceEntry = true
            default: break
            }
            pendingFilterTool = nil
        }) { shoppingFilters }
        .sheet(isPresented: $showingBulkEditor) { ListBulkEditor(repository: repository, listID: listID, selectedIDs: $selectedIDs) }
        .sheet(isPresented: $showingSettings) { SpecializedListOptions(repository: repository, listID: listID) }
        .sheet(isPresented: $showingReadingCapture) { ReadingLinkCapture(repository: repository, listID: listID) }
        .sheet(isPresented: $showingPriceEntry) { ShoppingPriceEntryMode(repository: repository, itemIDs: priceEntryIDs) }
        .sheet(item: $editingShoppingPrice) { item in ShoppingPriceEditor(repository: repository, task: item) }
        .sheet(item: $repeatPurchase) { item in
            NavigationStack {
                ShoppingItemEditor(repository: repository, draft: TaskDraft(listID: listID), initialDetails: repository.specializedDetails(item), initialTitle: item.title, initialNotes: item.notes)
            }
        }
        .sheet(isPresented: $showingShoppingCategories) { NavigationStack { ShoppingCategoryManager(repository: repository, listID: listID, store: storeFilter) } }
        .sheet(isPresented: Binding(get: { recentPurchase != nil }, set: { if !$0 { recentPurchase = nil } })) {
            if let suggestion = recentPurchase {
                NavigationStack { ShoppingItemEditor(repository: repository, draft: TaskDraft(listID: listID), initialDetails: suggestion.details, initialTitle: suggestion.title, initialNotes: suggestion.notes) }
            }
        }
        .sheet(isPresented: $showingBuyAgain) { NavigationStack { ShoppingItemEditor(repository: repository, draft: TaskDraft(listID: listID)) } }
        .sheet(isPresented: $showingBulkCapture) { ShoppingBulkCapture(repository: repository, listID: listID) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !type.bulkFields.isEmpty {
                        Button(selectingItems ? "Done Selecting" : "Select Items", systemImage: "checkmark.circle") { selectingItems.toggle(); selectedIDs = [] }
                    }
                    if type == .shopping { Button("Filters & Shopping Tools", systemImage: "line.3.horizontal.decrease") { showingFilters = true } }
                    if type == .reading {
                        Picker("Sort Within Groups", selection: $watchSort) {
                            ForEach(["Recently Watched", "New Releases", "Title"], id: \.self) { Text($0).tag($0) }
                        }
                    } else { Toggle("Sort by Name", isOn: $sortByName) }
                    Button("Clean Up Items", systemImage: "trash") { showingListCleanup = true }
                    Button("Customize List", systemImage: "slider.horizontal.3") { showingSettings = true }
                    if let action = repository.taskUndo { Button("Undo " + action.message, systemImage: "arrow.uturn.backward") { Task { await repository.undoLastTaskAction() } } }
                    if repository.listProfile(listID).settings["Current Run"] != nil { Toggle("Show Previous Runs", isOn: $showPreviousRuns) }
                    if type == .projects {
                        Button("Add Section", systemImage: "rectangle.split.3x1") { addingSection = true }
                        Button("Next Actions in All Projects", systemImage: "arrow.right.circle") { showingNextActions = true }
                    }
                    Button("Templates", systemImage: "doc.on.doc") { showsTemplates = true }
                    if type == .shopping {
                        Button("Estimate Missing Prices", systemImage: "dollarsign.circle") { priceEntryIDs = unpricedShoppingItems.map(\.id); showingPriceEntry = true }
                            .disabled(unpricedShoppingItems.isEmpty || repository.isUndoing)
                        Button("Categories & Aisle Order", systemImage: "arrow.up.arrow.down") { showingShoppingCategories = true }
                        Button("Buy Again", systemImage: "cart.badge.plus") { showingBuyAgain = true }
                        Button("Clear Completed", systemImage: "trash", role: .destructive) { pendingClearIDs = filteredCompletedIDs }
                            .disabled(clearingCompleted || repository.isUndoing || filteredCompletedIDs.isEmpty)
                    }
                    if type == .shopping { Button("Merge Duplicate Items", systemImage: "arrow.triangle.merge") { Task { await repository.mergeShoppingDuplicates(listID: listID) } } }
                } label: { Label("List Tools", systemImage: "list.bullet.rectangle") }
            }
        }
        .confirmationDialog("Delete Shopping Item?", isPresented: Binding(get: { pendingShoppingDelete != nil }, set: { if !$0 { pendingShoppingDelete = nil } }), titleVisibility: .visible) {
            if let item = pendingShoppingDelete {
                Button("Delete “\(item.title)”", role: .destructive) {
                    pendingShoppingDelete = nil
                    deletingShoppingIDs.insert(item.id)
                    Task {
                        await repository.deleteTask(item)
                        deletingShoppingIDs.remove(item.id)
                        if repository.tasks.contains(where: { $0.id == item.id }) {
                            shoppingDeleteError = repository.errorMessage ?? "The item could not be deleted. Please try again."
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingShoppingDelete = nil }
        } message: { Text("Removes this item from the shopping list and Reminders, including shared lists. You can undo the deletion afterward.") }
        .alert("Couldn’t Delete Item", isPresented: Binding(get: { shoppingDeleteError != nil }, set: { if !$0 { shoppingDeleteError = nil } })) {
            Button("OK", role: .cancel) { shoppingDeleteError = nil }
        } message: { Text(shoppingDeleteError ?? "") }
        .alert("Clear Completed Items?", isPresented: Binding(get: { !pendingClearIDs.isEmpty }, set: { if !$0 { pendingClearIDs = [] } })) {
            Button("Cancel", role: .cancel) { pendingClearIDs = [] }
            Button("Clear \(pendingClearIDs.count) Items", role: .destructive) {
                let ids = pendingClearIDs
                pendingClearIDs = []
                clearingCompleted = true
                Task {
                    await repository.clearCompletedShoppingItems(in: listID, confirmedIDs: ids)
                    clearingCompleted = false
                }
            }
        } message: { Text("Deletes the completed items from this shopping list and Reminders. You can undo this afterward.") }
        .alert("New Project Section", isPresented: $addingSection) {
            TextField("Section name", text: $newSection)
            Button("Cancel", role: .cancel) { newSection = "" }
            Button("Add") {
                let name = newSection.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                var profile = repository.listProfile(listID)
                let existing = profile.settings["Sections"] ?? ""
                profile.settings["Sections"] = existing.isEmpty ? name : existing + "\n" + name
                repository.setListProfile(profile, for: listID)
                newSection = ""
            }
        }
        .sheet(item: $linkedEvent) { event in
            CalendarEventDetailView(repository: repository, event: event, color: repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue)
        }
        .sheet(isPresented: $showsTemplates) { SpecializedTemplateManager(repository: repository, listID: listID) }
        .sheet(isPresented: $showingNextActions) { ProjectNextActionsView(repository: repository) }
    }
    /// Apple Maps link for an errand: exact coordinates when a place was chosen, otherwise a text search.
    static func mapsURL(place: TaskLocation?, destination: String, directions: Bool) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        if let place, let latitude = place.latitude, let longitude = place.longitude, latitude.isFinite, longitude.isFinite {
            let coordinate = "\(latitude),\(longitude)"
            components?.queryItems = directions
                ? [URLQueryItem(name: "daddr", value: coordinate)]
                : [URLQueryItem(name: "ll", value: coordinate), URLQueryItem(name: "q", value: place.displayTitle.isEmpty ? destination : place.displayTitle)]
        } else {
            let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            components?.queryItems = [URLQueryItem(name: directions ? "daddr" : "q", value: query)]
        }
        return components?.url
    }
    private func startTimer(for task: TaskItem) {
        let minutes = Int(repository.specializedDetails(task).fields["Timer Minutes"] ?? "") ?? task.durationMinutes ?? 5
        let listTitle = repository.lists.first { $0.id == listID }?.title ?? "Routine"
        Task {
            timerEnd = await RoutineTimerCoordinator.start(listID: listID, listTitle: listTitle, step: task.title, minutes: minutes)
            timerStep = task.title
        }
    }
    private func loadTimer() {
        let current = RoutineTimerCoordinator.current(listID: listID)
        timerEnd = current?.end
        timerStep = current?.step ?? ""
    }
    private var billTotals: [String: Double] { totals(for: items) }
    private var monthlyBillTotals: [String: Double] { totals(for: items.filter { task in guard let due = task.dueDate else { return false }; return Calendar.current.isDate(due, equalTo: Date(), toGranularity: .month) }) }
    private func totals(for tasks: [TaskItem]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for task in tasks where !task.isCompleted {
            let fields = repository.specializedDetails(task).fields
            guard fields["Stage"] != "Paid", fields["Stage"] != "Canceled", let amount = Double(fields["Amount"] ?? ""), amount.isFinite, amount >= 0 else { continue }
            let currency = fields["Currency"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "Unspecified"
            totals[currency.isEmpty ? "Unspecified" : currency, default: 0] += amount
        }
        return totals
    }
    private var shoppingCurrency: String { Locale.current.currency?.identifier ?? "USD" }
    @ViewBuilder private func shoppingBudgetSummary(_ tasks: [TaskItem]) -> some View {
        let priced = tasks.compactMap { task -> (Bool, Double)? in
            guard let cost = ShoppingQuantity.cost(repository.specializedDetails(task).fields) else { return nil }
            return (task.isCompleted, cost)
        }
        let purchased = priced.filter { $0.0 }.reduce(0) { $0 + $1.1 }
        let remaining = priced.filter { !$0.0 }.reduce(0) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 4) {
            Text("Estimated total: " + (purchased + remaining).formatted(.currency(code: shoppingCurrency))).font(.subheadline.weight(.semibold))
            Text("Remaining: " + remaining.formatted(.currency(code: shoppingCurrency))).font(.caption).foregroundStyle(.secondary)
            if tasks.count > priced.count { Text("\(tasks.count - priced.count) items without a price").font(.caption).foregroundStyle(.secondary) }
            if let budget = Double(repository.listProfile(listID).settings["Shopping Budget"] ?? ""), budget.isFinite, budget > 0 {
                Text("Budget: " + budget.formatted(.currency(code: shoppingCurrency)) + " · " + abs(budget - purchased - remaining).formatted(.currency(code: shoppingCurrency)) + (purchased + remaining > budget ? " over" : " left"))
                    .font(.caption).foregroundStyle(purchased + remaining > budget ? Color.orange : Color.secondary)
            }
        }
    }
    private func shoppingBadge(_ details: SpecializedTaskDetails, completed: Bool) -> some View {
        let raw = details.fields["Quantity"] ?? ""
        let quantity = raw.isEmpty ? "1" : raw
        let text = "×" + quantity + ((details.fields["Unit"] ?? "").isEmpty ? "" : " " + (details.fields["Unit"] ?? ""))
        let emphasized = !completed && (ShoppingQuantity.value(raw) ?? 0) > 1
        return Text(text).font(.caption.weight(.semibold))
            .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((emphasized ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
            .accessibilityLabel("Quantity " + quantity + " " + (details.fields["Unit"] ?? ""))
    }
    private var emptyState: ListEmptyState {
        let all = repository.rootTasks.filter { $0.listID == listID && (type != .reading || repository.specializedDetails($0).fields["Merged Into"] == nil) }
        return ListEmptyState.resolve(total: all.count, open: all.filter { !$0.isCompleted }.count)
    }
    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    @ViewBuilder private func workflowSummary(_ tasks: [TaskItem]) -> some View {
        let count = tasks.filter { type.workflowDone(completed: $0.isCompleted, fields: repository.specializedDetails($0).fields) }.count
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(count), total: Double(max(1, tasks.count)))
            Text("\(count) of \(tasks.count) " + type.workflowLabel).font(.subheadline).foregroundStyle(.secondary)
            if type == .packing {
                let prepared = tasks.filter { let stage = repository.specializedDetails($0).fields["Stage"]; return $0.isCompleted || stage == "Prepared" || stage == "Packed" }.count
                Text("\(prepared) prepared or packed").font(.caption).foregroundStyle(.secondary)
            }
            if type == .bills {
                let canceled = tasks.filter { repository.specializedDetails($0).fields["Stage"] == "Canceled" }.count
                if canceled > 0 { Text("\(canceled) canceled").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func shoppingHeader(_ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    shoppingStoreChip("All Stores", value: nil)
                    ForEach(storeChoices + [""], id: \.self) { store in
                        shoppingStoreChip(store.isEmpty ? "No Store" : store, value: store)
                    }
                }
            }
            if storeFilter != nil || showFavorites {
                HStack {
                    Text([storeFilter.map { $0.isEmpty ? "No Store" : $0 }, showFavorites ? "Favorites" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Filters") { storeFilter = nil; showFavorites = false }.font(.caption)
                }
            }
            workflowSummary(tasks)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Add Item", systemImage: "plus") { editorDraft = repository.makeDraft() }.fixedSize(horizontal: true, vertical: true)
                    Spacer()
                    Button(showFavorites ? "Filters · Favorites" : "Filters", systemImage: "line.3.horizontal.decrease") { showingFilters = true }.fixedSize(horizontal: true, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Add Item", systemImage: "plus") { editorDraft = repository.makeDraft() }
                    Button(showFavorites ? "Filters · Favorites" : "Filters", systemImage: "line.3.horizontal.decrease") { showingFilters = true }
                }
            }.buttonStyle(.borderless).labelStyle(.titleAndIcon)
            let suggestions = repository.shoppingRepeatSuggestions(listID: listID).filter { suggestion in
                (storeFilter == nil || (suggestion.details.fields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(storeFilter ?? "") == .orderedSame) && !items.contains { ShoppingQuantity.key(title: $0.title, fields: repository.specializedDetails($0).fields) == ShoppingQuantity.key(title: suggestion.title, fields: suggestion.details.fields) }
            }
            if !suggestions.isEmpty {
                Text("Buy Again").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(suggestions.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                            Button(suggestion.title, systemImage: "plus") { recentPurchase = suggestion }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }.padding(.vertical, 4)
    }
    private func shoppingStoreChip(_ title: String, value: String?) -> some View {
        Button { storeFilter = value } label: {
            Text(title).font(.subheadline.weight(storeFilter == value ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(storeFilter == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(storeFilter == value ? .isSelected : [])
    }
    private var shoppingFilters: some View {
        NavigationStack {
            Form {
                Section("Filters") {
                    Picker("Store", selection: $storeFilter) {
                        Text("All Stores").tag(String?.none)
                        Text("No Store").tag(Optional(""))
                        ForEach(storeChoices, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Toggle("Favorites Only", isOn: $showFavorites)
                    Toggle("Group by Store", isOn: $groupByStore)
                    Toggle("Sort by Name", isOn: $sortByName)
                    Toggle("Shopping Mode", isOn: $shoppingMode)
                    Button("Reset Filters") { storeFilter = nil; showFavorites = false }
                }
                Section("Shopping Tools") {
                    Button("Paste Several Items", systemImage: "text.badge.plus") { pendingFilterTool = "paste"; showingFilters = false }
                    Button("Buy Again", systemImage: "cart.badge.plus") { pendingFilterTool = "again"; showingFilters = false }
                    Button("Estimate Missing Prices (\(unpricedShoppingItems.count))", systemImage: "dollarsign.circle") {
                        priceEntryIDs = unpricedShoppingItems.map(\.id); pendingFilterTool = "prices"; showingFilters = false
                    }.disabled(unpricedShoppingItems.isEmpty || repository.isUndoing)
                    NavigationLink("Categories & Aisle Order") { ShoppingCategoryManager(repository: repository, listID: listID, store: storeFilter) }
                }
            }.taskFlowThemedBackground().navigationTitle("Filters & Shopping Tools")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingFilters = false } } }
        }
    }
    @ViewBuilder private func quickActions(_ task: TaskItem, sections: [String]) -> some View {
        let fields = repository.specializedDetails(task).fields
        if type == .projects {
            Menu {
                Button("No Section") { repository.moveProjectItems([task], to: "") }
                ForEach(Array(Set(sections + repository.listFieldChoices("Section", listID: listID))).filter { $0 != "Other" }.sorted(), id: \.self) { section in
                    Button(section) { repository.moveProjectItems([task], to: section) }
                }
            } label: {
                Label("Move to Section", systemImage: "rectangle.split.3x1")
            }.font(.caption).buttonStyle(.borderless).disabled(repository.isUndoing)
        }
        if !type.stages.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stageMenu(task); primaryStageAction(task) }
                VStack(alignment: .leading, spacing: 6) { stageMenu(task); primaryStageAction(task) }
            }.font(.caption).buttonStyle(.borderless).disabled(repository.isUndoing)
        }
        if type == .shopping, !task.isCompleted, dynamicTypeSize.isAccessibilitySize {
            HStack {
                Button("Decrease Quantity", systemImage: "minus.circle") { Task { await repository.adjustShoppingQuantity(task, by: -1) } }
                    .disabled((ShoppingQuantity.value(fields["Quantity"]) ?? 1) <= 1)
                Button("Increase Quantity", systemImage: "plus.circle") { Task { await repository.adjustShoppingQuantity(task, by: 1) } }
            }.font(.caption).buttonStyle(.borderless).disabled(repository.isUndoing || repository.shoppingQuantityIsUpdating(task.id))
        }
    }
    private func stageMenu(_ task: TaskItem) -> some View {
        let stage = type.displayedStage(completed: task.isCompleted, fields: repository.specializedDetails(task).fields)
        return Menu {
            ForEach(type.stages, id: \.self) { value in
                Button(value) { Task { await repository.setSpecializedStage(value, for: task, type: type) } }
            }
        } label: { Label(stage, systemImage: "arrow.triangle.2.circlepath") }
    }
    @ViewBuilder private func primaryStageAction(_ task: TaskItem) -> some View {
        if !task.isCompleted {
            let current = type.displayedStage(completed: task.isCompleted, fields: repository.specializedDetails(task).fields)
            let next = type == .bills ? "Paid" : (current == type.stages.first ? (type.stages.dropFirst().first ?? current) : (type.stages.last ?? current))
            Button(type == .bills ? "Mark Paid" : (type == .packing ? (next == "Prepared" ? "Mark Prepared" : "Mark Packed") : (next == "In Progress" ? "Start" : "Finish")), systemImage: "checkmark.circle") {
                Task { await repository.setSpecializedStage(next, for: task, type: type) }
            }
        }
    }
    private func readingCardMenu(_ task: TaskItem) -> some View {
                Menu {
                    Button("Details", systemImage: "info.circle") { repository.selectedTaskID = task.id }
                    let fields = repository.specializedDetails(task).fields
                    if fields["Preview Status"] != "Pending" {
                        Button("Retry Link Preview", systemImage: "arrow.clockwise") { repository.retryReadingPreview(task) }
                    }
                    let format = ReadingMedia.displayFormat(fields)
                    if ReadingMedia.action(for: format) == "Watch", format != "Movie", format != "Episode" { Button("Show & Episodes", systemImage: "tv") { trackedShow = task } }
                    if ReadingMedia.action(for: format) == "Watch", format != "Movie", format != "Episode" {
                        Button("Change Poster", systemImage: "photo.on.rectangle") { artworkItem = task }
                    }
                    ForEach(type.stages, id: \.self) { value in
                        Button(value) { Task { await repository.setSpecializedStage(value, for: task, type: type) } }
                    }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 48, minHeight: 48) }
                    .buttonStyle(.borderless).disabled(repository.isUndoing).accessibilityLabel("Actions for " + task.title)
    }

    private func itemRow(_ task: TaskItem, milestones: [String: (done: Int, total: Int)], sections: [String]) -> some View {
        let isWatchCard = type == .reading && ReadingMedia.action(for: ReadingMedia.displayFormat(repository.specializedDetails(task).fields)) == "Watch"
        return HStack(alignment: .top, spacing: 12) {
            if selectingItems {
                Button { toggleSelection(task.id) } label: {
                    Image(systemName: selectedIDs.contains(task.id) ? "checkmark.square.fill" : "square").font(.title2).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.borderless).accessibilityLabel((selectedIDs.contains(task.id) ? "Deselect " : "Select ") + task.title)
            }
            if !isWatchCard, type == .reading, !selectingItems, !dynamicTypeSize.isAccessibilitySize, repository.listProfile(listID).settings["Show Thumbnails"] != "false" {
                let fields = repository.specializedDetails(task).fields
                Button {
                    repository.openTask(id: task.id)
                } label: {
                    let isWatch = ReadingMedia.action(for: ReadingMedia.displayFormat(fields)) == "Watch"
                    let matchedPoster = fields["Suppress Preview"] == "true" ? nil : (fields["Artwork Override"] == "true" ? fields["Thumbnail URL"] : ReadingMedia.tracking(fields)?.show.thumbnail?.absoluteString)
                    CachedMediaPreview(rawURL: isWatch ? (matchedPoster ?? fields["Thumbnail URL"]) : fields["Thumbnail URL"], format: ReadingMedia.displayFormat(fields), localPreview: isWatch && matchedPoster != nil ? nil : fields["Local Preview"], poster: isWatch)
                }
                    .buttonStyle(.borderless).accessibilityLabel("Open " + task.title)
            }
            if type != .reading {
                Button { Task { await repository.toggleCompletion(for: task) } } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(type == .shopping ? .title : .title2).frame(minWidth: type == .shopping ? 56 : 44, minHeight: type == .shopping ? 56 : 44).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(selectingItems).accessibilityLabel((task.isCompleted ? "Reopen " : "Complete ") + task.title)
            }
            VStack(alignment: .leading, spacing: isWatchCard ? 12 : 4) {
            Button {
                if selectingItems { toggleSelection(task.id) }
                else if isWatchCard, ReadingMedia.tracking(repository.specializedDetails(task).fields) != nil { trackedShow = task }
                else if type == .reading { repository.openTask(id: task.id) }
                else { repository.selectedTaskID = task.id }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    if isWatchCard, !selectingItems, !dynamicTypeSize.isAccessibilitySize, repository.listProfile(listID).settings["Show Thumbnails"] != "false" {
                        let fields = repository.specializedDetails(task).fields
                        let matchedPoster = fields["Suppress Preview"] == "true" ? nil : (fields["Artwork Override"] == "true" ? fields["Thumbnail URL"] : ReadingMedia.tracking(fields)?.show.thumbnail?.absoluteString)
                        CachedMediaPreview(rawURL: matchedPoster ?? fields["Thumbnail URL"], format: ReadingMedia.displayFormat(fields), localPreview: matchedPoster == nil ? fields["Local Preview"] : nil, poster: true)
                    }
                VStack(alignment: .leading, spacing: isWatchCard ? 6 : 4) {
                    if type == .errands {
                        let destination = repository.specializedDetails(task).fields["Destination"] ?? ""
                        if let place = task.location, place.latitude != nil {
                            Label(destination.isEmpty ? place.displayTitle : destination, systemImage: place.proximity == .onDeparture ? "location.north.circle" : "mappin.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !destination.isEmpty { Text(destination).font(.caption).foregroundStyle(.secondary) }
                    }
                    let details = repository.specializedDetails(task)
                    HStack(alignment: .firstTextBaseline) {
                        Text(task.title).foregroundStyle(.primary).font(shoppingMode ? .title3 : .body).strikethrough(task.isCompleted).fixedSize(horizontal: false, vertical: true)
                        if type == .shopping { shoppingBadge(details, completed: task.isCompleted) }
                    }
                    if type == .shopping {
                        let subtitle = [storeFilter == nil && !groupByStore ? details.fields["Store"] : nil, groupByStore ? details.fields["Category"] : nil, details.fields["Shopper"].flatMap { $0.isEmpty ? nil : "Shopper: " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }

                        if task.isCompleted {
                            if let actor = details.fields["Purchased By"], let timestamp = details.fields["Purchased At"], let purchasedAt = ISO8601DateFormatter().date(from: timestamp), let completedAt = task.completedAt, abs(completedAt.timeIntervalSince(purchasedAt)) < 60 {
                                Text("Purchased by " + actor).font(.caption2).foregroundStyle(.secondary)
                            } else { Text("Purchased in Reminders").font(.caption2).foregroundStyle(.secondary) }
                        } else if let actor = details.fields["Added By"], actor != repository.shoppingShopperName { Text("Added by " + actor).font(.caption2).foregroundStyle(.secondary) }
                    } else if type == .bills {
                        let amount = Double(details.fields["Amount"] ?? "").flatMap { $0.isFinite ? SpecializedFieldFormat.amount($0, currency: details.fields["Currency"]) : nil }
                        let line = ([amount] + [details.fields["Provider"], details.fields["Stage"]]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !line.isEmpty { Text(line).font(.subheadline).foregroundStyle(.secondary) }
                    } else if type != .reading, !details.summary.isEmpty { Text(details.summary).font(.subheadline).foregroundStyle(.secondary) }
                    if type == .projects {
                        if !(details.fields["Blocked Reason"] ?? "").isEmpty { Label("Blocked: " + (details.fields["Blocked Reason"] ?? ""), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        if details.fields["Next Action"] == "Yes" { Label("Next Action", systemImage: "arrow.right.circle").font(.caption).foregroundStyle(.tint) }
                        if let milestone = details.fields["Milestone"], !milestone.isEmpty {
                            let counts = milestones[milestone] ?? (done: 0, total: 0)
                            Text(milestone + " · \(counts.done)/\(counts.total)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if type == .packing, details.fields["Essential"] == "Yes" { Label("Essential", systemImage: "star.fill").font(.caption).foregroundStyle(.orange) }
                    if type == .routines, details.fields["Required"] == "Yes" { Text("Required").font(.caption).foregroundStyle(.secondary) }
                    if type == .household, let last = details.fields["Last Completed"], !last.isEmpty {
                        // Past its repeat interval reads as due again.
                        let age = SpecializedTaskDetails.dateValue(last).map { -SpecializedFieldFormat.dayOffset($0) }
                        let isDue = !task.isCompleted && age != nil && details.repeatAfterDays.map { (age ?? 0) >= $0 } == true
                        Text("Last done: " + (SpecializedFieldFormat.date(last) ?? last)).font(.caption).foregroundStyle(isDue ? .orange : .secondary)
                    }
                    if type == .bills {
                        let isOpen = !task.isCompleted && !["Paid", "Canceled"].contains(details.fields["Stage"] ?? "")
                        ForEach(SpecializedListType.billDeadlineFields, id: \.self) { key in
                            if let value = details.fields[key], !value.isEmpty {
                                let isPast = isOpen && SpecializedTaskDetails.dateValue(value).map { SpecializedFieldFormat.dayOffset($0) < 0 } == true
                                Label(key + ": " + (SpecializedFieldFormat.date(value) ?? value), systemImage: isPast ? "exclamationmark.circle" : "calendar")
                                    .font(.caption).foregroundStyle(isPast ? .red : .secondary)
                            }
                        }
                    }
                    if type == .errands, let preparation = details.fields["Before Leaving"], !preparation.isEmpty { Text("Before leaving: " + preparation).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                    if type == .appointments, let followUp = SpecializedFieldFormat.date(details.fields["Follow-up Date"]) { Label("Follow-up: " + followUp, systemImage: "arrow.uturn.forward").font(.caption).foregroundStyle(.secondary) }
                    if type == .appointments, let outcome = details.fields["Outcome"], !outcome.isEmpty { Text("Outcome: " + outcome).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                    if type == .reading {
                        let fields = details.fields
                        let source = (fields["Creator"] ?? "").isEmpty ? URL(string: fields["Source Link"] ?? "")?.host : fields["Creator"]
                        let minutes = ReadingMedia.action(for: ReadingMedia.displayFormat(fields)) == "Read" ? fields["Estimated Minutes"].flatMap { Int($0) }.flatMap { $0 > 0 ? "\($0) min read" : nil } : nil
                        let format = ReadingMedia.displayFormat(fields)
                        let provider = fields["Streaming Service"] ?? fields["Saved From"] ?? ReadingMedia.watchLinks(fields).first?.provider
                        let subtitle = ReadingMedia.action(for: format) == "Watch" ? [format, fields["Year"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") : [source, minutes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                        if let catalog = ReadingMedia.tracking(fields) {
                            if let summary = ReadingMedia.watchProgressSummary(fields, completed: task.isCompleted) {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                            if !["Finished Series", "Finished", "Dropped"].contains(ReadingMedia.watchGroup(fields, completed: task.isCompleted)), let remaining = ReadingMedia.remainingWatchTime(fields) {
                                Text(remaining).font(.caption).foregroundStyle(.secondary)
                            }
                            if ReadingMedia.hasNewEpisode(fields), !task.isCompleted, fields["Progress"] != "Finished" {
                                Label("New episode", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            }
                            if !["Finished Series", "Finished", "Dropped"].contains(ReadingMedia.watchGroup(fields, completed: task.isCompleted)), let season = (catalog.next() ?? catalog.upcoming())?.season ?? catalog.ordered.last?.season {
                                let episodes = catalog.episodes.filter { $0.season == season }
                                let watched = episodes.filter { catalog.watched.contains($0.id) }.count
                                Text("Season \(season) · \(watched) of \(episodes.count) watched")
                                    .font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: Double(watched), total: Double(max(1, episodes.count)))
                                    .accessibilityLabel("Season \(season): \(watched) of \(episodes.count) episodes watched")
                            }

                        }
                        if ReadingMedia.action(for: format) == "Watch", let provider {
                            Text(provider).font(.caption2).foregroundStyle(.tint).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6).padding(.vertical, 3).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    if type != .shopping, !shoppingMode, let date = task.dueDate { Text(date, format: .dateTime.month().day()).font(.caption).foregroundStyle(task.isOverdue() ? .red : .secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.trailing, isWatchCard && !selectingItems ? 48 : 0)
            }.buttonStyle(.plain)
            if !selectingItems, type != .reading { quickActions(task, sections: sections) }
            if type == .reading, !selectingItems {
                let fields = repository.specializedDetails(task).fields
                let links = ReadingMedia.watchLinks(fields)
                let action = ReadingMedia.action(for: ReadingMedia.displayFormat(fields))
                HStack(spacing: 10) {
                    if links.count > 1, !["Finished Series", "Finished", "Dropped"].contains(ReadingMedia.watchGroup(fields, completed: task.isCompleted)) {
                        Menu {
                            ForEach(links) { link in
                                if let url = URL(string: link.url) { Link(action + " on " + link.provider, destination: url) }
                            }
                        } label: {
                            Label(action == "Watch" ? "Watch On" : action, systemImage: "play.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    } else if let link = links.first, let url = URL(string: link.url), action != "Watch" || !["Finished Series", "Finished", "Dropped"].contains(ReadingMedia.watchGroup(fields, completed: task.isCompleted)) {
                        Link(destination: url) {
                            Label(action == "Watch" ? "Watch On" : action, systemImage: ReadingMedia.symbol(for: ReadingMedia.displayFormat(fields)))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel(action + " on " + link.provider)
                    }
                    if ReadingMedia.tracking(fields) != nil {
                        Button { trackedShow = task } label: {
                            Label("Episodes", systemImage: "list.number")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel("Episodes for " + task.title)
                    } else if action == "Watch", ReadingMedia.displayFormat(fields) != "Movie", ReadingMedia.displayFormat(fields) != "Episode" {
                        Button { trackedShow = task } label: {
                            Label("Match Show", systemImage: "tv").frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                if ReadingMedia.tracking(fields) != nil, !["Finished Series", "Finished", "Dropped"].contains(ReadingMedia.watchGroup(fields, completed: task.isCompleted)) {
                    EpisodeProgressActions(repository: repository, taskID: task.id, compact: true).font(.subheadline)
                }
                if fields["Preview Status"] == "Pending" { Text("Fetching preview…").font(.caption).foregroundStyle(.secondary) }
                if fields["Preview Status"] == "Unavailable" {
                    Button("Retry Preview") { repository.retryReadingPreview(task) }.font(.caption).buttonStyle(.borderless)
                }
            }
            if type == .shopping, !selectingItems {
                Button { editingShoppingPrice = task } label: {
                    let fields = repository.specializedDetails(task).fields
                    if let price = Double(fields["Price"] ?? ""), price.isFinite, price >= 0 {
                        Text((ShoppingQuantity.cost(fields) ?? price).formatted(.currency(code: shoppingCurrency)))
                    } else { Image(systemName: "dollarsign.circle") }
                }.font(.caption).buttonStyle(.borderless).disabled(repository.isUndoing)
                    .accessibilityLabel("Edit estimated price for " + task.title)
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if type == .reading, !selectingItems, !isWatchCard { readingCardMenu(task) }
            if type == .shopping, !task.isCompleted, !selectingItems, !dynamicTypeSize.isAccessibilitySize {
                let value = ShoppingQuantity.value(repository.specializedDetails(task).fields["Quantity"])
                HStack(spacing: 0) {
                    Button { Task { await repository.adjustShoppingQuantity(task, by: -1) } } label: { Image(systemName: "minus").frame(minWidth: 36, minHeight: 44) }
                        .disabled(value == nil || (value ?? 1) <= 1)
                        .accessibilityLabel("Decrease quantity of " + task.title)
                    Button { Task { await repository.adjustShoppingQuantity(task, by: 1) } } label: { Image(systemName: "plus").frame(minWidth: 36, minHeight: 44) }
                        .disabled(value == nil)
                        .accessibilityLabel("Increase quantity of " + task.title)
                }.buttonStyle(.borderless).disabled(repository.shoppingQuantityIsUpdating(task.id) || repository.isUndoing)
            }
        }
        .padding(.vertical, isWatchCard ? 16 : 0)
        .padding(.horizontal, isWatchCard ? 12 : 0)
        .background {
            if isWatchCard { RoundedRectangle(cornerRadius: 18).fill(TaskFlowTheme.surface) }
        }
        .overlay(alignment: .topTrailing) {
            if isWatchCard, !selectingItems { readingCardMenu(task).padding(8) }
        }
        .padding(.vertical, isWatchCard ? 6 : 0)
        .listRowSeparator(isWatchCard ? .hidden : .automatic)
        .id(task.id)
        .disabled(deletingShoppingIDs.contains(task.id))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if type == .shopping {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingShoppingDelete = task }
                    .disabled(repository.isUndoing || deletingShoppingIDs.contains(task.id))
            }
        }
        .contextMenu {
            Button(type.detailsTitle, systemImage: "pencil") { editingItem = task }
            if type == .shopping {
                Button("Delete Item", systemImage: "trash", role: .destructive) { pendingShoppingDelete = task }
                    .disabled(repository.isUndoing || deletingShoppingIDs.contains(task.id))
            }
            if type == .projects {
                Menu("Move to Section") {
                    ForEach(sections, id: \.self) { section in Button(section) { Task { await repository.setSpecializedField("Section", value: section, for: task) } } }
                }
                if repository.specializedDetails(task).fields["Next Action"] == "Yes" {
                    Button("Clear Next Action", systemImage: "arrow.right.circle.fill") { Task { await repository.setSpecializedField("Next Action", value: "No", for: task) } }
                } else {
                    Button("Mark as Next Action", systemImage: "arrow.right.circle") { Task { await repository.setSpecializedField("Next Action", value: "Yes", for: task) } }
                }
            }
            if type == .appointments || type == .errands { Button("Preparation Checklist", systemImage: "checklist") { checklistTask = task } }
            if type == .bills {
                ForEach(["Notice Date", "Cancellation Deadline"], id: \.self) { key in
                    if let date = SpecializedTaskDetails.dateValue(repository.specializedDetails(task).fields[key] ?? "") {
                        Button("Create " + key + " Reminder", systemImage: "calendar.badge.plus") {
                            var draft = repository.makeDraft(); draft.listID = listID; draft.title = key + ": " + task.title; draft.dueDate = date; editorDraft = draft
                        }
                    }
                }
            }
            if type == .errands {
                let destination = repository.specializedDetails(task).fields["Destination"] ?? ""
                if let url = Self.mapsURL(place: task.location, destination: destination, directions: false) {
                    Button("Open in Maps", systemImage: "map") { openURL(url) }
                }
                if let url = Self.mapsURL(place: task.location, destination: destination, directions: true) {
                    Button("Get Directions", systemImage: "arrow.triangle.turn.up.right.diamond") { openURL(url) }
                }
                Button(task.location == nil ? "Add Place" : "Change Place", systemImage: "mappin.and.ellipse") { editingItem = task }
                if let id = repository.specializedDetails(task).fields["Shopping List ID"], repository.lists.contains(where: { $0.id == id }) { Button("Open Shopping List", systemImage: "cart") { repository.selectedScope = .list(id) } }
            }
            if type == .shopping { Button("Buy Again", systemImage: "cart.badge.plus") { repeatPurchase = task } }
            if type == .routines {
                Button("Start Timer", systemImage: "timer") { startTimer(for: task) }
            }
            let fields = repository.specializedDetails(task).fields
            if type == .appointments {
                Button("Create Follow-up Reminder", systemImage: "calendar.badge.plus") {
                    var draft = repository.makeDraft()
                    draft.listID = listID
                    draft.title = "Follow up: " + task.title
                    draft.dueDate = SpecializedTaskDetails.dateValue(fields["Follow-up Date"] ?? "")
                    editorDraft = draft
                }
                if let eventID = fields["Event ID"], let event = repository.calendarEvents.first(where: { $0.id == eventID }) {
                    Button("Open Linked Event", systemImage: "calendar") { linkedEvent = event }
                }
            }
            if let raw = fields["Payment Link"] ?? fields["Source Link"], let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link("Open Link", destination: url)
            }
            ForEach(type.stages, id: \.self) { stage in
                Button(stage) { Task { await repository.setSpecializedStage(stage, for: task, type: type) } }
            }
        }
    }
}


/// Shopping uses a dedicated capture form; existing scheduling metadata is preserved on edits.
struct ShoppingItemEditor: View {
    @Bindable var repository: TaskRepository
    @State var draft: TaskDraft
    var task: TaskItem?
    var initialDetails: SpecializedTaskDetails? = nil
    var initialTitle: String = ""
    var initialNotes: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var details = SpecializedTaskDetails()
    @State private var saving = false
    @State private var loaded = false
    @State private var priceWasEdited = false
    @State private var recalledPrice: String?
    @State private var addingStore = false
    @State private var addingCategory = false
    @State private var newCategoryName = ""
    @State private var showingDuplicates = false
    @State private var addingShopper = false
    @State private var newShopperName = ""
    @State private var selectedSuggestions: [String: SpecializedListTemplate.Item] = [:]
    @FocusState private var nameFocused: Bool
    private var categories: [String] { repository.shoppingCategories(listID: draft.listID) }
    private let common: [(String, String)] = [("Milk", "Dairy & Eggs"), ("Eggs", "Dairy & Eggs"), ("Bread", "Bakery"), ("Bananas", "Produce"), ("Apples", "Produce"), ("Chicken", "Meat & Seafood"), ("Rice", "Pantry"), ("Pasta", "Pantry"), ("Coffee", "Beverages"), ("Yogurt", "Dairy & Eggs"), ("Paper towels", "Household"), ("Toothpaste", "Personal Care")]
    private var stores: [String] {
        var values = repository.shoppingStores(for: draft.listID)
        if let current = details.fields["Store"], !current.isEmpty, !values.contains(current) { values.append(current) }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var frequent: [SpecializedListTemplate.Item] { repository.shoppingRepeatSuggestions(listID: draft.listID) }
    private func suggestionKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    private var entriesToAdd: [SpecializedListTemplate.Item] {
        var entries = selectedSuggestions.keys.sorted().compactMap { selectedSuggestions[$0] }.map { item in
            var item = repository.pricedShoppingSuggestion(item, store: details.fields["Store"] ?? "")
            item.details.fields["Shopper"] = details.fields["Shopper"]
            return item
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            entries.removeAll { suggestionKey($0.title) == suggestionKey(title) }
            entries.insert(.init(title: title, notes: draft.notes, details: details), at: 0)
        }
        return entries
    }
    private func toggleSuggestion(_ item: SpecializedListTemplate.Item) {
        let key = suggestionKey(item.title)
        if selectedSuggestions[key] != nil { selectedSuggestions.removeValue(forKey: key) }
        else { selectedSuggestions[key] = item }
        nameFocused = false
    }
    private func suggestionPrice(_ item: SpecializedListTemplate.Item) -> String {
        let fields = repository.pricedShoppingSuggestion(item, store: details.fields["Store"] ?? "").details.fields
        let price = Double(fields["Price"] ?? "")
        guard let price, price.isFinite, price >= 0 else { return "" }
        let unit = (fields["Unit"] ?? "").isEmpty ? "unit" : (fields["Unit"] ?? "unit")
        return price.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")) + " / " + unit
    }
    private func suggestionRow(title: String, category: String, detail: String = "", price: String = "") -> some View {
        let selected = selectedSuggestions[suggestionKey(title)] != nil
        return HStack {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if !price.isEmpty { Text(price).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor) }
            }
            Spacer()
            if !category.isEmpty { Text(category).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func visible(_ key: String) -> Bool { repository.listProfile(draft.listID).settings["Hidden Field " + key] != "true" }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { details.fields[key] ?? "" }, set: { details.fields[key] = $0 })
    }
    private var shopperChoices: [String] {
        var names = repository.shoppingShopperChoices
        if let current = details.fields["Shopper"], !current.isEmpty, !names.contains(current) { names.append(current) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var price: Binding<Double?> {
        Binding(get: { Double(details.fields["Price"] ?? "") }, set: { value in
            priceWasEdited = true
            details.fields["Price"] = value.map { ShoppingQuantity.text($0) } ?? ""
        })
    }
    private func refreshPriceRecall() {
        guard task == nil, !priceWasEdited else { return }
        let current = details.fields["Price"] ?? ""
        guard current.isEmpty || current == recalledPrice else { return }
        let remembered = repository.rememberedShoppingPrice(title: draft.title, fields: details.fields).map(ShoppingQuantity.text)
        details.fields["Price"] = remembered ?? ""
        recalledPrice = remembered
    }
    private var quantityOptions: [String] {
        var values = ["0.25", "0.5", "0.75"] + (1...100).map(String.init)
        let current = details.fields["Quantity"] ?? ""
        if !current.isEmpty, !values.contains(current) { values.append(current) }
        return values.sorted {
            if let left = Double($0), let right = Double($1), left != right { return left < right }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    var body: some View {
        Form {
            Section {
                TextField("Item name", text: $draft.title).focused($nameFocused).submitLabel(.done).onSubmit { save() }
                if visible("Quantity") {
                    Picker("Quantity", selection: field("Quantity")) {
                        Text("Not Set").tag("")
                        ForEach(quantityOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    .tint((Double(details.fields["Quantity"] ?? "") ?? 0) > 1 ? Color.accentColor : Color.secondary)
                }
                Picker("Shopper", selection: Binding(get: { details.fields["Shopper"] ?? "" }, set: { details.fields["Shopper"] = repository.rememberShoppingShopper($0) })) {
                    Text("Not Set").tag("")
                    ForEach(shopperChoices, id: \.self) { Text($0).tag($0) }
                }
                Button("Add Shopper Name", systemImage: "person.badge.plus") { nameFocused = false; newShopperName = ""; addingShopper = true }
                LabeledContent("Estimated Price per Unit") {
                    TextField("Not Set", value: price, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityLabel("Estimated price per unit")
                }
                if visible("Store") {
                Picker("Store", selection: field("Store")) {
                    Text("None").tag("")
                    ForEach(stores, id: \.self) { Text($0).tag($0) }
                }
                Button("Add New Store", systemImage: "plus") { nameFocused = false; addingStore = true }
                }
                if visible("Category") {
                Picker("Category", selection: Binding(get: { ShoppingCatalog.canonicalCategory(details.fields["Category"] ?? "") }, set: { details.fields["Category"] = $0 })) {
                    Text("Not Set").tag("")
                    ForEach(categories.filter { $0 != "Other" }, id: \.self) { Text($0).tag($0) }
                    Text("Other").tag("Other")
                    if let raw = details.fields["Category"], !raw.isEmpty, case let category = ShoppingCatalog.canonicalCategory(raw), !categories.contains(category) { Text(category).tag(category) }
                }
                Button("Add Category", systemImage: "plus") { newCategoryName = ""; nameFocused = false; addingCategory = true }
                }
            }
            if task == nil {
                Section {
                    Text("Select several suggestions, then tap Add. Choose a store to apply it to all items, or leave None to keep each suggestion’s usual store.").font(.footnote).foregroundStyle(.secondary)
                    if !selectedSuggestions.isEmpty {
                        HStack { Text("\(selectedSuggestions.count) selected"); Spacer(); Button("Clear") { selectedSuggestions.removeAll() }.disabled(saving) }
                    }
                }
                if !frequent.isEmpty {
                    Section("Buy Again · Usual Purchases") {
                        ForEach(frequent, id: \.self) { item in
                            Button { toggleSuggestion(item) } label: {
                                suggestionRow(title: item.title, category: item.details.fields["Category"] ?? "", detail: [item.details.fields["Quantity"], item.details.fields["Unit"], item.details.fields["Store"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), price: suggestionPrice(item))
                            }.disabled(saving)
                        }
                    }
                }
                Section("Common Items") {
                    ForEach(common, id: \.0) { item in
                        Button {
                            var itemDetails = SpecializedTaskDetails()
                            itemDetails.fields["Category"] = item.1
                            toggleSuggestion(.init(title: item.0, notes: "", details: itemDetails))
                        } label: { suggestionRow(title: item.0, category: item.1, price: suggestionPrice(.init(title: item.0, notes: "", details: .init()))) }.disabled(saving)
                    }
                }
            }
            Section {
                DisclosureGroup("More Item Details") {
                    if visible("Unit") { TextField("Unit", text: field("Unit")) }

                    if visible("Substitute") { TextField("Substitute (optional)", text: field("Substitute")) }
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                    Toggle("Favorite", isOn: $details.isFavorite)
                }
            }
            if task != nil {
                Section("Shopping Activity") {
                    if let actor = details.fields["Added By"] { LabeledContent("Added by", value: actor) }
                    if let timestamp = details.fields["Added At"], let date = ISO8601DateFormatter().date(from: timestamp) { Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary) }
                    if let task, task.isCompleted, let actor = details.fields["Purchased By"], let timestamp = details.fields["Purchased At"], let date = ISO8601DateFormatter().date(from: timestamp), let completedAt = task.completedAt, abs(completedAt.timeIntervalSince(date)) < 60 {
                        LabeledContent("Purchased by", value: actor)
                        Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: details.fields["Store"]) { refreshPriceRecall() }
        .onChange(of: details.fields["Unit"]) { refreshPriceRecall() }
        .onChange(of: draft.title) {
            refreshPriceRecall()
            if task == nil, (details.fields["Category"] ?? "").isEmpty {
                let suggested = ShoppingCatalog.category(for: draft.title)
                if suggested != "Other" { details.fields["Category"] = suggested }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle(task == nil ? "Add Shopping Item" : "Shopping Item")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) { Button(task == nil ? (entriesToAdd.count > 1 ? "Add (\(entriesToAdd.count))" : "Add") : "Save") { save() }.disabled(saving || (task == nil ? entriesToAdd.isEmpty : draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }
        }
        .sheet(isPresented: $addingStore) {
            ShoppingStoreEntry { name in
                repository.rememberShoppingStore(name, for: draft.listID)
                details.fields["Store"] = repository.shoppingStores(for: draft.listID).first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? name
            }
        }
        .alert("Add Category", isPresented: $addingCategory) {
            TextField("Category name", text: $newCategoryName)
            Button("Cancel", role: .cancel) { }
            Button("Add") { details.fields["Category"] = repository.addShoppingCategory(newCategoryName, listID: draft.listID) }
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Add Shopper Name", isPresented: $addingShopper) {
            TextField("Name", text: $newShopperName).textContentType(.name)
            Button("Cancel", role: .cancel) { newShopperName = "" }
            Button("Add") { details.fields["Shopper"] = repository.rememberShoppingShopper(newShopperName); newShopperName = "" }
                .disabled(newShopperName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Items Already on Your List", isPresented: $showingDuplicates, titleVisibility: .visible) {
            Button("Increase Existing Quantities") { save(increaseDuplicates: true, confirmed: true) }
            Button("Keep Separate Items") { save(confirmed: true) }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Matching items use the same name, store, and unit. Increase their quantities or add separate items.") }
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let task { details = repository.specializedDetails(task) }
            else {
                draft.dueDate = nil; draft.recurrence = nil
                if let initialDetails {
                    details = initialDetails
                    draft.title = initialTitle
                    draft.notes = initialNotes
                } else { details.fields["Store"] = repository.shoppingCaptureStore(for: draft.listID); nameFocused = true }
            }
            if details.fields["Shopper"] == nil { details.fields["Shopper"] = repository.shoppingShopperName }
            refreshPriceRecall()
        }
    }
    private func save(increaseDuplicates: Bool = false, confirmed: Bool = false) {
        guard !saving else { return }
        if task == nil, !confirmed, repository.shoppingHasDuplicates(entriesToAdd, listID: draft.listID, store: details.fields["Store"] ?? "") { showingDuplicates = true; return }
        if task != nil {
            guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            saving = true
            Task { if await repository.saveShoppingItem(draft, details: details) { dismiss() }; saving = false }
            return
        }
        let entries = entriesToAdd
        guard !entries.isEmpty else { return }
        let customTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            let count = await repository.addShoppingSelection(entries, listID: draft.listID, store: details.fields["Store"] ?? "", increaseDuplicates: increaseDuplicates)
            for entry in entries.prefix(count) { selectedSuggestions.removeValue(forKey: suggestionKey(entry.title)) }
            if count > 0, !customTitle.isEmpty { draft.title = "" }
            saving = false
            if count == entries.count { dismiss() }
        }
    }
}


private struct ShoppingStoreEntry: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var isFocused: Bool
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Store Name") {
                    TextField("Enter store name", text: $name)
                        .font(.body)
                        .frame(minHeight: 44)
                        .textInputAutocapitalization(.words)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { add() }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("New Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(trimmedName.isEmpty) }
            }
            .task { isFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func add() {
        guard !trimmedName.isEmpty else { return }
        onAdd(trimmedName)
        dismiss()
    }
}

struct SpecializedListOptions: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    private var type: SpecializedListType { repository.listProfile(listID).type }
    var body: some View {
        NavigationStack {
            Form {
                if type == .shopping {
                    NavigationLink("Categories & Aisle Order") { ShoppingCategoryManager(repository: repository, listID: listID) }
                    Section {
                        ShoppingDefaultStorePicker(repository: repository, listID: listID, selection: Binding(get: { repository.listProfile(listID).settings["Default Store"] ?? "" }, set: { value in
                            var profile = repository.listProfile(listID)
                            profile.settings["Default Store"] = value
                            repository.setListProfile(profile, for: listID)
                        }))
                    } footer: {
                        Text("New items use this store unless you select another store filter. You can change the store on each item; existing items keep their stores.")
                    }
                    Section("Shopping Budget") {
                        TextField("Optional budget", text: Binding(get: { repository.listProfile(listID).settings["Shopping Budget"] ?? "" }, set: { value in
                            var profile = repository.listProfile(listID); profile.settings["Shopping Budget"] = value; repository.setListProfile(profile, for: listID)
                        })).keyboardType(.decimalPad)
                        Text("Prices and budget use " + (Locale.current.currency?.identifier ?? "USD") + ". Estimates exclude tax.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if type == .bills {
                    Section {
                        Toggle("Deadline Reminders", isOn: Binding(get: { repository.listProfile(listID).settings["Deadline Reminders"] != "false" }, set: { enabled in
                            var profile = repository.listProfile(listID); profile.settings["Deadline Reminders"] = String(enabled); repository.setListProfile(profile, for: listID)
                            Task { await repository.refreshDeadlineReminders() }
                        }))
                        if repository.listProfile(listID).settings["Deadline Reminders"] != "false" {
                            Picker("Advance Notice", selection: Binding(get: { Int(repository.listProfile(listID).settings["Deadline Lead Days"] ?? "") ?? 3 }, set: { days in
                                var profile = repository.listProfile(listID); profile.settings["Deadline Lead Days"] = String(days); repository.setListProfile(profile, for: listID)
                                Task { await repository.refreshDeadlineReminders() }
                            })) {
                                Text("On the Day Only").tag(0)
                                ForEach([1, 3, 7, 14], id: \.self) { Text("\($0) Day\($0 == 1 ? "" : "s") Before").tag($0) }
                            }
                        }
                    } header: { Text("Reminders") } footer: { Text("Open bills alert at 9 AM on their renewal, notice, and cancellation dates, plus the advance notice you choose. Paid or canceled bills stay quiet.") }
                }
                Section {
                    if type == .reading {
                        Toggle("Show Thumbnails", isOn: Binding(get: { repository.listProfile(listID).settings["Show Thumbnails"] != "false" }, set: { enabled in
                            var profile = repository.listProfile(listID); profile.settings["Show Thumbnails"] = String(enabled); repository.setListProfile(profile, for: listID)
                        }))
                    }
                    ForEach(type.fields, id: \.self) { key in
                        Toggle(key, isOn: Binding(get: { repository.listProfile(listID).settings["Hidden Field " + key] != "true" }, set: { visible in
                            var profile = repository.listProfile(listID)
                            profile.settings["Hidden Field " + key] = String(!visible)
                            repository.setListProfile(profile, for: listID)
                        }))
                    }
                } header: { Text("Visible Optional Fields") } footer: { Text("Hidden fields keep their saved values. " + type.syncExplanation) }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Customize List")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ShoppingBulkCapture: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var showingDuplicates = false
    private var parsed: [ShoppingCaptureItem] { ShoppingCatalog.parse(text) }
    var body: some View {
        NavigationStack {
            Form {
                Section { TextEditor(text: $text).frame(minHeight: 140) } header: { Text("One Item Per Line") } footer: { Text("Include a quantity if needed, such as ‘2 apples’. Items use the store filter, or your last selected store.") }
                Section("Preview (\(parsed.count))") {
                    ForEach(Array(parsed.enumerated()), id: \.offset) { _, item in
                        HStack { Text(item.quantity.isEmpty ? item.title : item.quantity + " × " + item.title); Spacer(); Text(item.category).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Add Several Items")
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Adding…" : "Add Items") { add() }.disabled(saving || parsed.isEmpty) }
            }
        }
        .confirmationDialog("Items Already on Your List", isPresented: $showingDuplicates, titleVisibility: .visible) {
            Button("Increase Existing Quantities") { add(increaseDuplicates: true, confirmed: true) }
            Button("Keep Separate Items") { add(confirmed: true) }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Increase matching quantities or keep separate items with the same name, store, and unit.") }
    }
    private func add(increaseDuplicates: Bool = false, confirmed: Bool = false) {
        guard !saving else { return }
        let entries = parsed
        let suggestions = entries.map { SpecializedListTemplate.Item(title: $0.title, notes: "", details: .init(fields: ["Quantity": $0.quantity, "Category": $0.category])) }
        let store = repository.shoppingCaptureStore(for: listID)
        if !confirmed, repository.shoppingHasDuplicates(suggestions, listID: listID, store: store) { showingDuplicates = true; return }
        saving = true
        Task {
            let count = await repository.addShoppingItems(entries, listID: listID, increaseDuplicates: increaseDuplicates)
            let remaining = Array(entries.dropFirst(count))
            text = remaining.map { ($0.quantity.isEmpty ? "" : $0.quantity + " ") + $0.title }.joined(separator: "\n")
            saving = false
            if remaining.isEmpty { dismiss() }
        }
    }
}

struct SpecializedTemplateManager: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SpecializedListTemplate?
    @State private var pendingDelete: SpecializedListTemplate?
    @State private var starting = false
    private var type: SpecializedListType { repository.listProfile(listID).type }
    private var starters: [(String, [String])] { type.starterSets }
    var body: some View {
        NavigationStack {
            List {
                Section { Button("Save Current List as Template") { repository.saveListTemplate(listID: listID, title: repository.lists.first { $0.id == listID }?.title ?? "Checklist") } }
                Section("Saved Templates") {
                    ForEach(repository.listTemplates.filter { $0.listID == listID }) { template in
                        Button { editing = template } label: {
                            HStack { VStack(alignment: .leading) { Text(template.title); Text("\(template.items.count) items · Preview and edit").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        }.foregroundStyle(.primary)
                        .swipeActions { Button("Delete", role: .destructive) { pendingDelete = template } }
                    }
                }
                if !starters.isEmpty {
                    Section("Starter Templates") {
                        ForEach(starters, id: \.0) { title, _ in
                            Button(title) {
                                guard let index = starters.firstIndex(where: { $0.0 == title }), let template = type.starterTemplate(index: index, listID: listID) else { return }
                                repository.listTemplates.append(template)
                                repository.updateListTemplate(template)
                                editing = template
                            }
                        }
                    }
                }
                if let run = repository.listProfile(listID).settings["Current Run"] {
                    Section("Run History") {
                        let tasks = repository.tasks.filter { $0.listID == listID }
                        let history = Dictionary(grouping: tasks.filter { repository.specializedDetails($0).fields["Run ID"] != nil }, by: { repository.specializedDetails($0).fields["Run ID"] ?? "" })
                        ForEach(history.keys.sorted(), id: \.self) { id in
                            let members = history[id] ?? []
                            VStack(alignment: .leading) {
                                Text(members.first.map { repository.specializedDetails($0).fields["Run"] ?? "Checklist" } ?? "Checklist")
                                Text("\(members.filter { $0.isCompleted }.count)/\(members.count) completed" + (id == run ? " · Current" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Templates")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { template in SpecializedTemplateEditor(repository: repository, template: template) }
            .alert("Delete Template?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) { if let pendingDelete { repository.deleteListTemplate(pendingDelete.id) }; pendingDelete = nil }
            } message: { Text("Existing checklist runs will remain.") }
        }
    }
}

struct SpecializedTemplateEditor: View {
    @Bindable var repository: TaskRepository
    @State var template: SpecializedListTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var starting = false
    var body: some View {
        NavigationStack {
            List {
                Section("Template Name") { TextField("Name", text: $template.title) }
                Section("Items") {
                    ForEach(template.items.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            TextField("Item", text: $template.items[index].title)
                            TextField("Notes", text: $template.items[index].notes, axis: .vertical).font(.subheadline)
                        }
                    }.onDelete { template.items.remove(atOffsets: $0) }.onMove { template.items.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add Item", systemImage: "plus") { template.items.append(.init(title: "", notes: "", details: .init())) }
                }
                Section {
                    Button(starting ? "Starting…" : "Start Fresh Run", systemImage: "play.fill") {
                        guard valid else { return }; starting = true
                        repository.updateListTemplate(template)
                        Task { await repository.createTemplateRun(template); starting = false; dismiss() }
                    }.disabled(!valid || starting)
                } footer: { Text("Creates new items and keeps previous runs. You can undo the created items from List Tools.") }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Template")
            .interactiveDismissDisabled(starting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(starting) }
                ToolbarItem(placement: .primaryAction) { EditButton().disabled(starting) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { repository.updateListTemplate(template); dismiss() }.disabled(!valid || starting) }
            }
        }
    }
    private var valid: Bool { !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !template.items.isEmpty && template.items.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

struct SpecializedChecklistView: View {
    @Bindable var repository: TaskRepository
    let task: TaskItem
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<Int> = []
    @State private var saving = false
    private var field: String { repository.listProfile(task.listID).type == .errands ? "Before Leaving" : "Preparation" }
    private var steps: [String] { (repository.specializedDetails(task).fields[field] ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var body: some View {
        NavigationStack {
            List {
                if steps.isEmpty { ContentUnavailableView("No Preparation Steps", systemImage: "checklist", description: Text("Add one step per line in List Details.")) }
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    Button { if checked.contains(index) { checked.remove(index) } else { checked.insert(index) } } label: {
                        Label(title, systemImage: checked.contains(index) ? "checkmark.circle.fill" : "circle").foregroundStyle(.primary)
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Preparation")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") {
                saving = true
                Task {
                    var details = repository.specializedDetails(task)
                    details.fields["Checked " + field] = (try? String(data: JSONEncoder().encode(Array(checked)), encoding: .utf8)) ?? "[]"
                    details.fields["Checklist Text " + field] = steps.joined(separator: "\n")
                    if await repository.saveSpecializedDetails(details, for: task, type: repository.listProfile(task.listID).type) { dismiss() }
                    saving = false
                }
            }.disabled(saving) } }
            .onAppear {
                let details = repository.specializedDetails(task)
                guard details.fields["Checklist Text " + field] == steps.joined(separator: "\n") else { return }
                checked = Set(details.fields["Checked " + field].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? [])
            }
        }
        .interactiveDismissDisabled(saving)
    }
}

/// Every open Next Action across Projects lists, the GTD "what can I do now" view.
struct ProjectNextActionsView: View {
    @Bindable var repository: TaskRepository
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let actions = repository.projectNextActions
        let byList = Dictionary(grouping: actions, by: \.listID)
        let projectLists = repository.lists.filter { byList[$0.id] != nil }
        NavigationStack {
            List {
                if actions.isEmpty {
                    ContentUnavailableView("No Next Actions", systemImage: "arrow.right.circle", description: Text("Mark a task as Next Action in any Projects list and it appears here."))
                }
                ForEach(projectLists) { list in
                    Section(list.title) {
                        ForEach(byList[list.id] ?? []) { task in row(task) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .taskFlowThemedBackground()
            .navigationTitle("Next Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        let fields = repository.specializedDetails(task).fields
        let context = [fields["Section"], fields["Milestone"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 12) {
            Button { Task { await repository.toggleCompletion(for: task) } } label: {
                Image(systemName: "circle").font(.title2).frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderless).disabled(repository.isUndoing).accessibilityLabel("Complete " + task.title)
            Button {
                repository.selectedScope = .list(task.listID)
                repository.selectedTaskID = task.id
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).foregroundStyle(.primary)
                    if !context.isEmpty { Text(context).font(.caption).foregroundStyle(.secondary) }
                    if let blocked = fields["Blocked Reason"], !blocked.isEmpty {
                        Label("Blocked: " + blocked, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                    if let due = task.dueDate {
                        Text(SpecializedFieldFormat.date(SpecializedTaskDetails.dateText(due)) ?? due.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(task.isOverdue() ? .red : .secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .swipeActions {
            Button("Clear", systemImage: "arrow.right.circle") { Task { await repository.setSpecializedField("Next Action", value: "No", for: task) } }
                .tint(.gray)
        }
    }
}

struct ReadingLinkCapture: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var link = ""
    @State private var saving = false
    @State private var metadata: ReadingLinkMetadata?
    @State private var fetching = false
    /// The title last filled in from the page, so a user-typed title is never replaced.
    @State private var mergeIntoID = ""
    @State private var autoTitle = ""
    @State private var streamingService = ""
    @State private var note = ""
    private var url: URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private var duplicateMatches: [TaskItem] {
        guard let url else { return [] }
        let fields = (metadata?.fields ?? [:]).merging(["Source Link": url.absoluteString]) { _, new in new }
        return repository.mediaDuplicates(title: title, fields: fields, listID: listID)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("https://…", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        // The system paste button reads the clipboard without a permission prompt.
                        PasteButton(payloadType: URL.self) { urls in
                            if let pasted = urls.first { link = pasted.absoluteString }
                        }.labelStyle(.iconOnly).buttonBorderShape(.capsule)
                    }
                    HStack {
                        TextField("Title", text: $title)
                        if fetching { ProgressView() }
                    }
                    Picker("Streaming Service (optional)", selection: $streamingService) {
                        Text("Automatic").tag("")
                        ForEach(repository.streamingServiceChoices, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Optional note", text: $note, axis: .vertical).lineLimit(1...3)
                    LabeledContent("Destination", value: repository.lists.first { $0.id == listID }?.title ?? "Reading list")
                } footer: { Text("Save immediately. Missing previews and details are fetched after saving.") }
                if !duplicateMatches.isEmpty {
                    Section {
                        Picker("Save As", selection: $mergeIntoID) {
                            Text("New Entry").tag("")
                            ForEach(duplicateMatches) { Text("Add link to " + $0.title).tag($0.id) }
                        }
                    } header: { Text("Similar Title Already Saved") } footer: { Text("Choose an existing entry to combine provider links. Titles can identify different releases, so review before combining.") }
                }
                if let metadata, !metadata.fields.isEmpty {
                    Section("From the Page") {
                        HStack(alignment: .top, spacing: 12) {
                            if let thumbnail = metadata.thumbnailURL {
                                CachedMediaPreview(rawURL: thumbnail.absoluteString, format: metadata.format)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                if !metadata.creator.isEmpty { Text(metadata.creator).font(.subheadline) }
                                Text([metadata.format, metadata.estimatedMinutes.map { "\($0) min read" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Save a Link")
            .interactiveDismissDisabled(saving)
            .task(id: link) { mergeIntoID = ""; await lookUp() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    guard let url else { return }; saving = true
                    Task { if await repository.addReadingLink(title: title, url: url, listID: listID, metadata: metadata, note: note, mergeIntoID: duplicateMatches.contains(where: { $0.id == mergeIntoID }) ? mergeIntoID : nil, streamingService: streamingService) { dismiss() }; saving = false }
                }.disabled(saving || url == nil) }
            }
        }
    }

    private func lookUp() async {
        metadata = nil
        guard let url else { return }
        try? await Task.sleep(for: .milliseconds(500)) // Wait for typing to pause.
        guard !Task.isCancelled else { return }
        fetching = true
        defer { fetching = false }
        let found = await ReadingLinkMetadata.fetch(url)
        guard !Task.isCancelled, let found else { return }
        metadata = found
        let current = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !found.title.isEmpty, current.isEmpty || current == autoTitle {
            title = String(found.title.prefix(200))
            autoTitle = title
        }
    }
}


struct ShoppingCategoryManager: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let listID: String
    @State var store: String? = nil
    @State private var addingCategory = false
    @State private var name = ""
    var body: some View {
        let order = repository.shoppingCategoryOrder(listID: listID, store: store)
        Form {
            Section {
                Picker("Store Layout", selection: $store) {
                    Text("All Stores (Default)").tag(String?.none)
                    Text("No Store").tag(Optional(""))
                    ForEach(repository.shoppingStores(for: listID), id: \.self) { Text($0).tag(Optional($0)) }
                }
                Text("Drag categories into aisle order. A store without its own order uses All Stores.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Aisle Order") {
                ForEach(order, id: \.self) { Text($0) }
                    .onMove { indices, destination in
                        var reordered = order
                        reordered.move(fromOffsets: indices, toOffset: destination)
                        repository.setShoppingCategoryOrder(reordered, listID: listID, store: store)
                    }
                Button(store == nil ? "Reset Default Order" : "Use Default Order") {
                    repository.setShoppingCategoryOrder(nil, listID: listID, store: store)
                }
            }
            Section {
                Button("Add Category", systemImage: "plus") { name = ""; addingCategory = true }
                ForEach(repository.shoppingCustomCategories(listID: listID), id: \.self) { category in
                    HStack {
                        Text(category)
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) { repository.removeShoppingCategory(category, listID: listID) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            } header: { Text("Custom Categories") } footer: { Text("Removing a saved category keeps existing items and their category labels.") }
        }
        .environment(\.editMode, .constant(.active))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .navigationTitle("Categories & Aisle Order")
        .navigationBarTitleDisplayMode(.inline)
        .taskFlowThemedBackground()
        .alert("Add Category", isPresented: $addingCategory) {
            TextField("Category name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button("Add") { repository.addShoppingCategory(name, listID: listID) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}


private struct ShoppingPriceEditor: View {
    @Bindable var repository: TaskRepository
    let task: TaskItem
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var price: Double? { ShoppingPriceInput.value(text) }
    var body: some View {
        NavigationStack {
            Form {
                Section(task.title) {
                    TextField("Estimated Price per Unit", text: $text)
                        .keyboardType(.decimalPad).focused($focused)
                }
                Section {
                    Text("This estimate is remembered for this item, store, and unit, even after purchased items are deleted.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Estimated Price")
            .navigationBarTitleDisplayMode(.inline)
            .taskFlowThemedBackground()
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        focused = false
                        guard let price, price.isFinite, price >= 0 else { return }
                        saving = true
                        Task {
                            if await repository.saveShoppingEstimate(price, for: task) { dismiss() }
                            else { error = repository.errorMessage ?? "The price could not be saved. Please try again." }
                            saving = false
                        }
                    }.disabled(saving || price == nil || !(price?.isFinite ?? false) || (price ?? 0) < 0)
                }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                let fields = repository.specializedDetails(task).fields
                let savedPrice = Double(fields["Price"] ?? "") ?? repository.rememberedShoppingPrice(title: task.title, fields: fields)
                text = savedPrice.map { $0.formatted(.number.grouping(.never)) } ?? ""
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}


private struct ShoppingPriceEntryMode: View {
    @Bindable var repository: TaskRepository
    let itemIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var current: TaskItem? {
        guard itemIDs.indices.contains(index) else { return nil }
        return repository.tasks.first { $0.id == itemIDs[index] && !$0.isCompleted }
    }
    private var value: Double? { ShoppingPriceInput.value(text) }
    var body: some View {
        NavigationStack {
            Form {
                if let current {
                    Section {
                        Text(current.title).font(.headline)
                        let fields = repository.specializedDetails(current).fields
                        let context = [fields["Store"], fields["Unit"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !context.isEmpty { Text(context).font(.subheadline).foregroundStyle(.secondary) }
                        Text("Item \(index + 1) of \(itemIDs.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Estimated Price per Unit") {
                        TextField("Enter price", text: $text).keyboardType(.decimalPad).focused($focused)
                        if let value { Text(value.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))).foregroundStyle(.secondary) }
                        Button(index == itemIDs.count - 1 ? "Save & Done" : "Save & Next", action: saveAndNext)
                            .disabled(saving || value == nil || repository.isUndoing)
                        Button("Skip Item") { advance() }.disabled(saving)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                } else {
                    ContentUnavailableView("Price Entry Finished", systemImage: "checkmark.circle", description: Text("Saved estimates are remembered. Skipped items can be priced later."))
                }
            }
            .navigationTitle("Estimate Prices")
            .navigationBarTitleDisplayMode(.inline)
            .taskFlowThemedBackground()
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(saving) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(index == itemIDs.count - 1 ? "Save & Done" : "Next", action: saveAndNext)
                        .disabled(saving || value == nil || repository.isUndoing)
                }
            }
            .onAppear { loadCurrent() }
            .onChange(of: repository.tasksRevision) {
                if !saving, current == nil { advancePastRemovedItems(); loadCurrent() }
            }
        }
    }
    private func advancePastRemovedItems() {
        while index < itemIDs.count, current == nil { index += 1 }
    }
    private func loadCurrent() {
        advancePastRemovedItems()
        error = nil
        if let current {
            let fields = repository.specializedDetails(current).fields
            let price = Double(fields["Price"] ?? "") ?? repository.rememberedShoppingPrice(title: current.title, fields: fields)
            text = price.map { $0.formatted(.number.grouping(.never)) } ?? ""
            focused = true
        } else { text = ""; focused = false }
    }
    private func advance() {
        index += 1
        loadCurrent()
    }
    private func saveAndNext() {
        guard !saving, let current, let value else { return }
        saving = true
        Task {
            if await repository.saveShoppingEstimate(value, for: current) {
                advance()
                if index >= itemIDs.count { dismiss() }
            } else { error = repository.errorMessage ?? "The price could not be saved. Please try again." }
            saving = false
        }
    }
}

/// Disk-backed previews keep a fixed footprint while loading and work offline.
actor ReadingThumbnailCache {
    static let shared = ReadingThumbnailCache()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingPreviews", isDirectory: true)

    nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    func data(for url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        if let cached = try? Data(contentsOf: file), let thumbnail = Self.thumbnail(cached) { return thumbnail }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request),
              response.url?.scheme?.lowercased() == "https",
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true else { return nil }
        var raw = Data()
        do {
            for try await byte in stream {
                guard !Task.isCancelled, raw.count < 8_000_000 else { return nil }
                raw.append(byte)
            }
        } catch { return nil }
        guard let data = Self.thumbnail(raw) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let ordered = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var count = files.count
            for old in ordered {
                guard count > 120 || bytes > 64_000_000 else { break }
                bytes -= (try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                count -= 1
                try? FileManager.default.removeItem(at: old)
            }
        }
        return data
    }
}

struct CachedMediaPreview: View {
    let rawURL: String?
    let format: String
    var expanded = false
    var localPreview: String? = nil
    var poster = false
    @State private var image: UIImage?
    private var isAudio: Bool { ReadingMedia.action(for: format) == "Listen" }
    private var aspect: Double { ReadingMedia.artworkAspect(width: Double(image?.size.width ?? 0), height: Double(image?.size.height ?? 0), format: format) }
    private var previewHeight: CGFloat { poster && !expanded ? 108 : expanded ? (aspect < 0.9 ? 200 : 144) : (aspect < 0.9 ? 80 : 64) }
    private var previewWidth: CGFloat { poster && !expanded ? 72 : previewHeight * aspect }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
            if let image {
                if poster && !expanded {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: previewWidth, height: previewHeight).clipped()
                } else { Image(uiImage: image).resizable().scaledToFit() }
            }
            else { Image(systemName: ReadingMedia.symbol(for: format)).foregroundStyle(.secondary) }
        }
        .frame(width: previewWidth, height: previewHeight)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: (rawURL ?? "") + (localPreview ?? "")) {
            image = nil
            if let data = ReadingMedia.capturePreviewData(localPreview), let preview = UIImage(data: data) { image = preview; return }
            guard let rawURL, let url = URL(string: rawURL), let data = await ReadingThumbnailCache.shared.data(for: url), !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}


struct ListCleanupView: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var pending: Set<String> = []
    @State private var deleting = false
    private var items: [TaskItem] { repository.tasks.filter { $0.listID == listID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private var completed: Set<String> { Set(items.filter(\.isCompleted).map(\.id)) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose individual items or remove completed items in one step. This includes items hidden by your list filters.").font(.footnote).foregroundStyle(.secondary)
                    Button("Delete Completed (\(completed.count))", systemImage: "trash", role: .destructive) { prepare(completed) }.disabled(completed.isEmpty)
                    Button("Delete Selected (\(selected.count))", systemImage: "trash", role: .destructive) { prepare(selected) }.disabled(selected.isEmpty)
                    Button("Delete All Items (\(items.count))", systemImage: "trash", role: .destructive) { prepare(Set(items.map(\.id))) }.disabled(items.isEmpty)
                    if let action = repository.taskUndo {
                        Button("Undo " + action.message, systemImage: "arrow.uturn.backward") {
                            deleting = true
                            Task { await repository.undoLastTaskAction(); deleting = false }
                        }
                    }
                    if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
                }
                Section("Select Items") {
                    ForEach(items) { item in
                        Button {
                            if !selected.insert(item.id).inserted { selected.remove(item.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.isCompleted ? "Completed" : "Open").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.accessibilityLabel(item.title + (selected.contains(item.id) ? ", selected" : ", not selected"))
                    }
                }
            }
            .disabled(deleting || repository.isUndoing)
            .navigationTitle("Clean Up Items")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(deleting) } }
            .interactiveDismissDisabled(deleting)
            .confirmationDialog("Delete \(pending.count) items?", isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }), titleVisibility: .visible) {
                Button("Delete \(pending.count) Items", role: .destructive) {
                    let ids = pending.intersection(Set(items.map(\.id)))
                    pending = []
                    deleting = true
                    Task {
                        await repository.deleteTasks(ids)
                        selected.subtract(ids)
                        deleting = false
                    }
                }
                Button("Cancel", role: .cancel) { pending = [] }
            } message: { Text("Items are deleted from Apple Reminders and synced devices. Selected parent items include their subtasks. The list itself stays. Undo is available after deletion.") }
        }
    }
    private func prepare(_ ids: Set<String>) {
        var expanded = ids.intersection(Set(items.map(\.id)))
        while true {
            let children = Set(items.filter { $0.parentID.map { expanded.contains($0) } == true }.map(\.id))
            let next = expanded.union(children)
            if next == expanded { break }
            expanded = next
        }
        pending = expanded
    }
}
