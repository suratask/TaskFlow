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
            let subviewSize = subview.sizeThatFits(.unspecified)
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
            let size = subview.sizeThatFits(.unspecified)
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

    /// Rows with checkmarks, like choosing tags in Reminders. Meant to sit inside a Form or List section.
    var body: some View {
        ForEach(allTagNames, id: \.self) { name in
            Button {
                toggle(name)
            } label: {
                HStack {
                    Text("#\(name)").foregroundStyle(.primary)
                    Spacer()
                    if contains(name) {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(contains(name) ? .isSelected : [])
        }
        TextField("New Tag", text: $newTag)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(addTag)
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

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                if let event = todayEvents.first(where: { !$0.isAllDay && $0.endDate > Date() }) ?? todayEvents.first(where: { $0.isAllDay }) {
                    Button {
                        repository.selectedTaskID = nil
                        selectedCalendarEvent = event
                    } label: {
                        LabeledContent {
                            Text(event.isAllDay ? "All Day" : event.startDate.formatted(date: .omitted, time: .shortened))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).foregroundStyle(.primary).lineLimit(1)
                                    Text(event.isAllDay ? "On your calendar today" : (event.startDate <= Date() ? "Happening now" : "Up next"))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "calendar").foregroundStyle(eventColor(event))
                            }
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            } footer: {
                Text(summaryText)
            }

            if repository.accessState != .granted {
                Section {
                    Text(repository.accessState.message).foregroundStyle(.secondary)
                    if repository.accessState == .unknown {
                        Button("Continue") { Task { await repository.requestAccess() } }
                    }
                }
            }

            taskSection("Overdue", tasks: repository.overdueTasks, canDefer: true)
            taskSection("Today", tasks: openTodayTasks)

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
                }
            }

            let tomorrowTasks = repository.upcomingTasks.filter { task in
                guard let due = task.dueDate else { return false }
                return Calendar.current.isDateInTomorrow(due)
            }
            taskSection("Tomorrow", tasks: tomorrowTasks, canCommit: true)
            if !suggestedTasks.isEmpty || !repository.overdueTasks.isEmpty {
                TipView(PlanTodayTip())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            taskSection("Suggested", tasks: suggestedTasks, canCommit: true,
                        footer: "Flagged and high-priority tasks that aren\u{2019}t due today. Swipe right to add one to Today.")

            if repository.accessState == .granted {
                Section {
                    InlineNewTaskRow(repository: repository, defaultDue: .today, onShowDetails: { editorDraft = $0 }, onAdded: {
                        withAnimation { proxy.scrollTo(InlineNewTaskRow.scrollID, anchor: .bottom) }
                    })
                } footer: {
                    Text("New tasks here are due today.")
                }
            }
        }
        .listStyle(.insetGrouped)
        }
        .taskFlowThemedBackground()
        .navigationTitle("Today")
        .toolbar {
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
                    var draft = repository.makeDraft()
                    draft.dueDate = Calendar.current.startOfDay(for: Date())
                    editorDraft = draft
                }
                .popoverTip(AddMenuTip())
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

    private var summaryText: String {
        var parts = ["\(openTodayTasks.count) due today"]
        if !repository.overdueTasks.isEmpty { parts.append("\(repository.overdueTasks.count) overdue") }
        parts.append("\(todayEvents.count) event\(todayEvents.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private func eventColor(_ event: CalendarEvent) -> Color {
        repository.eventCalendars.first { $0.id == event.calendarID }?.color ?? .blue
    }

    /// Flagged or high-priority work without a date in the next day, offered for planning (formerly Plan My Day).
    private var suggestedTasks: [TaskItem] {
        let calendar = Calendar.current
        return repository.tasks.filter { task in
            guard !task.isCompleted, task.isFlagged || task.priority == .high else { return false }
            guard let due = task.dueDate else { return true }
            return !calendar.isDateInToday(due) && !calendar.isDateInTomorrow(due) && !task.isOverdue()
        }
    }

    @ViewBuilder private func taskSection(_ title: String, tasks: [TaskItem], canCommit: Bool = false, canDefer: Bool = false, footer: String? = nil) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) { task in
                    TaskRowView(task: task, subtasks: [], isSelected: repository.selectedTaskID == task.id,
                                listColor: repository.lists.first { $0.id == task.listID }?.color ?? repository.appTheme.primary,
                                tagColor: repository.color(forTag:),
                                density: .comfortable, repository: repository)
                        .swipeActions(edge: .leading) {
                            if canCommit {
                                Button {
                                    Task { await repository.setDueDate(Calendar.current.startOfDay(for: Date()), for: task) }
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
                            Button(role: .destructive) {
                                Task { await repository.deleteTask(task) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            if canDefer {
                                Button {
                                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                                    Task { await repository.setDueDate(tomorrow, for: task) }
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
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
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


struct SpecializedTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let task: TaskItem
    let type: SpecializedListType
    @State private var details = SpecializedTaskDetails()
    @State private var saving = false
    @State private var initialized = false
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
            Section {
                ForEach(type.fields.filter { !["Follow-up Date", "Essential", "Next Action", "Required", "Rating", "Shopping List ID"].contains($0) && !(type == .appointments && ["Preparation", "Questions", "Outcome"].contains($0)) && repository.listProfile(task.listID).settings["Hidden Field " + $0] != "true" }, id: \.self) { key in
                    if ["Renewal Date", "Notice Date", "Cancellation Deadline"].contains(key) {
                        Toggle(key, isOn: Binding(get: { !(details.fields[key] ?? "").isEmpty }, set: { details.fields[key] = $0 ? SpecializedTaskDetails.dateText(Date()) : "" }))
                        if !(details.fields[key] ?? "").isEmpty {
                            DatePicker(key, selection: Binding(get: { SpecializedTaskDetails.dateValue(details.fields[key] ?? "") ?? Date() }, set: { details.fields[key] = SpecializedTaskDetails.dateText($0) }), displayedComponents: .date)
                        }
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
                    Picker("Linked Event", selection: field("Event ID")) {
                        Text("None").tag("")
                        ForEach(repository.calendarEvents, id: \.occurrenceKey) { event in
                            Text(event.title + " · " + event.startDate.formatted(date: .abbreviated, time: .shortened)).tag(event.id)
                        }
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
            } header: { Text(type.rawValue) } footer: { Text("These optional details are saved in TaskFlow. Changing list type keeps them.") }
            if type == .errands { errandLocationSection }
            if type == .appointments {
                if repository.listProfile(task.listID).settings["Hidden Field Preparation"] != "true" { Section("Before · Preparation") { TextField("One preparation step per line", text: field("Preparation"), axis: .vertical).lineLimit(2...6) } }
                if repository.listProfile(task.listID).settings["Hidden Field Questions"] != "true" { Section("During · Questions") { TextField("Questions to ask", text: field("Questions"), axis: .vertical).lineLimit(2...6) } }
                if repository.listProfile(task.listID).settings["Hidden Field Outcome"] != "true" { Section("After · Outcome") { TextField("Outcome and next steps", text: field("Outcome"), axis: .vertical).lineLimit(2...6) } }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("Specialized Details")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") {
            saving = true
            Task {
                var saved = details
                if type == .errands, let location, (saved.fields["Destination"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saved.fields["Destination"] = location.displayTitle
                }
                var succeeded = await repository.saveSpecializedDetails(saved, for: task, type: type)
                if succeeded, type == .errands, location != originalLocation {
                    // The place is saved on the reminder, where Reminders delivers its arrival alert.
                    var draft = TaskDraft(task: repository.tasks.first { $0.id == task.id } ?? task)
                    draft.location = location
                    succeeded = await repository.saveTask(draft)
                }
                if succeeded { dismiss() }
                saving = false
            }
        }.disabled(saving || searchingLocation) } }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            details = repository.specializedDetails(task)
            location = (repository.tasks.first { $0.id == task.id } ?? task).location
            originalLocation = location
        }
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
    @Bindable var repository: TaskRepository
    let listID: String
    var viewMode: TaskRepository.TaskViewMode = .list
    @Binding var editorDraft: TaskDraft?
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
        profile.settings["Shopping Mode"] = String(shoppingMode)
        profile.settings["Group Store"] = String(groupByStore)
        profile.settings["Store Filter"] = storeFilter
        profile.settings["Favorites Only"] = String(showFavorites)
        profile.settings["Sort Name"] = String(sortByName)
        profile.settings["Completed Expanded"] = String(completedExpanded)
        profile.settings["Collapsed"] = (try? String(data: JSONEncoder().encode(Array(collapsed)), encoding: .utf8)) ?? "[]"
        repository.setListProfile(profile, for: listID)
    }
    private var type: SpecializedListType { repository.listProfile(listID).type }
    private var items: [TaskItem] {
        let values = repository.rootTasks.filter { $0.listID == listID && (!showFavorites || repository.specializedDetails($0).isFavorite) && (showPreviousRuns || repository.listProfile(listID).settings["Current Run"] == nil || repository.specializedDetails($0).fields["Run ID"] == repository.listProfile(listID).settings["Current Run"]) }
        let visible = values.filter { !$0.isCompleted && (!remainingOnly || !["Packed", "Finished", "Paid"].contains(repository.specializedDetails($0).fields["Stage"] ?? "")) }
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
            task.listID == listID && task.parentID == nil && (type != .shopping || repository.shoppingTask(task, matchesStore: storeFilter)) && (showPreviousRuns || repository.listProfile(listID).settings["Current Run"] == nil || repository.specializedDetails(task).fields["Run ID"] == repository.listProfile(listID).settings["Current Run"])
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
        return values.sorted {
            let left = order.firstIndex(of: $0) ?? Int.max
            let right = order.firstIndex(of: $1) ?? Int.max
            return left == right ? $0.localizedStandardCompare($1) == .orderedAscending : left < right
        }
    }
    private func group(_ task: TaskItem) -> String {
        let value = repository.specializedDetails(task).fields[type == .shopping && groupByStore ? "Store" : type.groupField] ?? ""
        return value.isEmpty ? (type == .reading ? "Saved" : "Other") : (type == .shopping && !groupByStore ? ShoppingCatalog.canonicalCategory(value) : value)
    }
    var body: some View {
        let visible = items
        let progress = progressTasks
        let rowsByGroup = Dictionary(grouping: visible, by: group)
        let progressByGroup = Dictionary(grouping: progress, by: group)
        let completed = progress.filter { $0.isCompleted }
        let sectionNames = groups
        let milestoneMembers = Dictionary(grouping: progress, by: { repository.specializedDetails($0).fields["Milestone"] ?? "" })
        let milestones = milestoneMembers.mapValues { (done: $0.filter { $0.isCompleted }.count, total: $0.count) }
        Group {
        if type == .projects && viewMode == .board {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(sectionNames.isEmpty ? ["Other"] : sectionNames, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(section).font(.headline); Spacer(); Text("\(rowsByGroup[section, default: []].count)").foregroundStyle(.secondary) }
                            let members = progressByGroup[section, default: []]
                            Text("\(members.filter { $0.isCompleted }.count)/\(members.count) complete").font(.caption).foregroundStyle(.secondary)
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
        } else {
        List {
            Section {
                Label(type.rawValue, systemImage: type.icon).font(.headline)
                ProgressView(value: Double(completed.count), total: Double(max(1, progress.count)))
                Text("\(completed.count) of \(progress.count) completed").font(.subheadline).foregroundStyle(.secondary)
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
                if type == .shopping {
                    Button("Add Shopping Item", systemImage: "plus") { editorDraft = repository.makeDraft() }
                    Label(storeFilter.map { $0.isEmpty ? "No Store" : $0 } ?? "All Stores", systemImage: "storefront").font(.subheadline).foregroundStyle(.secondary)
                    shoppingBudgetSummary(progress)
                    Button("Estimate Missing Prices (\(unpricedShoppingItems.count))", systemImage: "dollarsign.circle") { priceEntryIDs = unpricedShoppingItems.map(\.id); showingPriceEntry = true }
                        .disabled(unpricedShoppingItems.isEmpty || repository.isUndoing)
                    Picker("Store", selection: $storeFilter) {
                        Text("All Stores").tag(String?.none)
                        Text("No Store").tag(Optional(""))
                        ForEach(storeChoices, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Toggle("Shopping Mode", isOn: $shoppingMode)
                    Toggle("Favorites Only", isOn: $showFavorites)
                    Toggle("Group by Store", isOn: $groupByStore)
                    Button("Paste Several Items", systemImage: "text.badge.plus") { showingBulkCapture = true }
                }
                if type == .projects {
                    let nextCount = repository.projectNextActions.count
                    Button { showingNextActions = true } label: {
                        LabeledContent { Text("\(nextCount)") } label: { Label("Next Actions in All Projects", systemImage: "arrow.right.circle") }
                    }
                }
                if type == .reading { Button("Save a Link", systemImage: "link.badge.plus") { showingReadingCapture = true } }
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
                ContentUnavailableView(type == .shopping ? "Ready for Your Next Trip" : "No Items", systemImage: type.icon, description: Text(type == .shopping ? "Add items, paste a list, or choose previous purchases for this store." : "Add an item or start a saved template."))
                Button("Add Item", systemImage: "plus") { editorDraft = repository.makeDraft() }
                if type == .shopping {
                    Button("Paste Items", systemImage: "text.badge.plus") { showingBulkCapture = true }
                    Button("Buy Again", systemImage: "cart.badge.plus") { showingBuyAgain = true }
                }
            }
            ForEach(sectionNames, id: \.self) { section in
                Section {
                    DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(section) }, set: { expanded in
                        if expanded { collapsed.remove(section) } else { collapsed.insert(section) }; persistPreferences()
                    })) {
                        ForEach(rowsByGroup[section, default: []]) { task in itemRow(task, milestones: milestones, sections: sectionNames) }
                    } label: {
                        HStack { Text(section).font(.headline); Spacer(); Text("\(rowsByGroup[section, default: []].count)").foregroundStyle(.secondary) }
                        if type == .packing || type == .projects {
                            let members = progressByGroup[section, default: []]
                            Text("\(members.filter { $0.isCompleted }.count)/\(members.count) complete").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !(type == .packing && remainingOnly), !completed.isEmpty {
                Section {
                    DisclosureGroup("\(type == .shopping ? "Purchased" : "Completed") (\(completed.count))", isExpanded: $completedExpanded) {
                        ForEach(completed) { itemRow($0, milestones: milestones, sections: sectionNames) }
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
            shoppingMode = settings["Shopping Mode"] == "true"
            groupByStore = settings["Group Store"] == "true"
            storeFilter = settings["Store Filter"]
            showFavorites = settings["Favorites Only"] == "true"
            sortByName = settings["Sort Name"] == "true"
            completedExpanded = settings["Completed Expanded"] == "true"
            collapsed = Set(settings["Collapsed"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        }
        .onChange(of: shoppingMode) { persistPreferences() }
        .onChange(of: groupByStore) { persistPreferences() }
        .onChange(of: storeFilter) { persistPreferences() }
        .onChange(of: showFavorites) { persistPreferences() }
        .onChange(of: sortByName) { persistPreferences() }
        .onChange(of: completedExpanded) { persistPreferences() }
        .sheet(item: $editingItem) { task in NavigationStack { if type == .shopping { ShoppingItemEditor(repository: repository, draft: TaskDraft(task: task), task: task) } else { SpecializedTaskEditor(repository: repository, task: task, type: type) } } }
        .sheet(item: $checklistTask) { task in SpecializedChecklistView(repository: repository, task: task) }
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
        .sheet(isPresented: $showingBuyAgain) { NavigationStack { ShoppingItemEditor(repository: repository, draft: TaskDraft(listID: listID)) } }
        .sheet(isPresented: $showingBulkCapture) { ShoppingBulkCapture(repository: repository, listID: listID) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Sort by Name", isOn: $sortByName)
                    Button("Customize Fields", systemImage: "slider.horizontal.3") { showingSettings = true }
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
            Text("Purchased: " + purchased.formatted(.currency(code: shoppingCurrency)) + " · Remaining: " + remaining.formatted(.currency(code: shoppingCurrency))).font(.caption).foregroundStyle(.secondary)
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
    private func itemRow(_ task: TaskItem, milestones: [String: (done: Int, total: Int)], sections: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if type == .reading, repository.listProfile(listID).settings["Show Thumbnails"] == "true",
               let raw = repository.specializedDetails(task).fields["Thumbnail URL"], let url = URL(string: raw), url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "book").foregroundStyle(.secondary) }
                    .frame(width: 40, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            }
            Button { Task { await repository.toggleCompletion(for: task) } } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(shoppingMode ? .title : .title2).frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderless).accessibilityLabel((task.isCompleted ? "Reopen " : "Complete ") + task.title)
            VStack(alignment: .leading, spacing: 4) {
            Button { repository.selectedTaskID = task.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if type == .errands {
                        let destination = repository.specializedDetails(task).fields["Destination"] ?? ""
                        if let place = task.location, place.latitude != nil {
                            Label(destination.isEmpty ? place.displayTitle : destination, systemImage: place.proximity == .onDeparture ? "location.north.circle" : "mappin.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !destination.isEmpty { Text(destination).font(.caption).foregroundStyle(.secondary) }
                    }
                    let details = repository.specializedDetails(task)
                    HStack(alignment: .firstTextBaseline) {
                        Text(task.title).foregroundStyle(.primary).font(shoppingMode ? .title3 : .body).strikethrough(task.isCompleted)
                        if type == .shopping { shoppingBadge(details, completed: task.isCompleted) }
                    }
                    if type == .shopping {
                        let subtitle = [details.fields["Store"], details.fields["Category"], details.fields["Shopper"].flatMap { $0.isEmpty ? nil : "Shopper: " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }

                        if task.isCompleted {
                            if let actor = details.fields["Purchased By"], let timestamp = details.fields["Purchased At"], let purchasedAt = ISO8601DateFormatter().date(from: timestamp), let completedAt = task.completedAt, abs(completedAt.timeIntervalSince(purchasedAt)) < 60 {
                                Text("Purchased by " + actor).font(.caption2).foregroundStyle(.secondary)
                            } else { Text("Purchased in Reminders").font(.caption2).foregroundStyle(.secondary) }
                        } else if let actor = details.fields["Added By"] { Text("Added by " + actor).font(.caption2).foregroundStyle(.secondary) }
                    } else if type == .bills {
                        let amount = Double(details.fields["Amount"] ?? "").flatMap { $0.isFinite ? SpecializedFieldFormat.amount($0, currency: details.fields["Currency"]) : nil }
                        let line = ([amount] + [details.fields["Provider"], details.fields["Stage"]]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !line.isEmpty { Text(line).font(.subheadline).foregroundStyle(.secondary) }
                    } else if !details.summary.isEmpty { Text(details.summary).font(.subheadline).foregroundStyle(.secondary) }
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
                        if let progress = details.fields["Progress Detail"], !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary) }
                        if let rating = details.fields["Rating"], !rating.isEmpty { Text("Rating: " + rating + "/5").font(.caption).foregroundStyle(.secondary) }
                        if let minutes = details.fields["Estimated Minutes"], !minutes.isEmpty { Text(minutes + " min").font(.caption).foregroundStyle(.secondary) }
                    }
                    if type != .shopping, !shoppingMode, let date = task.dueDate { Text(date, format: .dateTime.month().day()).font(.caption).foregroundStyle(task.isOverdue() ? .red : .secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if type == .shopping {
                Button { editingShoppingPrice = task } label: {
                    let fields = repository.specializedDetails(task).fields
                    if let price = Double(fields["Price"] ?? ""), price.isFinite, price >= 0 {
                        let unit = (fields["Unit"] ?? "").isEmpty ? "unit" : (fields["Unit"] ?? "unit")
                        Text(price.formatted(.currency(code: shoppingCurrency)) + " / " + unit + (ShoppingQuantity.cost(fields).map { " · " + $0.formatted(.currency(code: shoppingCurrency)) + " total" } ?? ""))
                    } else { Label("Add Price", systemImage: "plus.circle") }
                }.font(.caption).buttonStyle(.borderless).disabled(repository.isUndoing)
                    .accessibilityLabel("Edit estimated price for " + task.title)
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if type == .shopping, !task.isCompleted {
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
        .id(task.id)
        .disabled(deletingShoppingIDs.contains(task.id))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if type == .shopping {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingShoppingDelete = task }
                    .disabled(repository.isUndoing || deletingShoppingIDs.contains(task.id))
            }
        }
        .contextMenu {
            Button("Edit List Details", systemImage: "pencil") { editingItem = task }
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
                } else { details.fields["Store"] = repository.listProfile(draft.listID).settings["Store Filter"] ?? ""; nameFocused = true }
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
                        Toggle("Show Thumbnails", isOn: Binding(get: { repository.listProfile(listID).settings["Show Thumbnails"] == "true" }, set: { enabled in
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
                } header: { Text("Visible Optional Fields") } footer: { Text("Hidden fields keep their saved values.") }
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
        let store = repository.listProfile(listID).settings["Store Filter"] ?? repository.listProfile(listID).settings["Last Store"] ?? ""
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
    private var starters: [(String, [String])] {
        switch type {
        case .shopping: [("Grocery Staples", ["Milk", "Eggs", "Bread", "Apples", "Rice", "Coffee"])]
        case .household: [("Weekly Home Reset", ["Kitchen: Clean counters", "Bathroom: Clean sink", "Laundry: Wash towels", "Living Room: Vacuum"]), ("Seasonal Home Care", ["Replace air filters", "Check smoke detectors", "Clean gutters"])]
        case .packing: [("Weekend Trip", ["Travel documents", "Medication", "Phone charger", "Clothes", "Toiletries"]), ("Business Trip", ["Travel documents", "Laptop", "Laptop charger", "Work clothes", "Medication"])]
        case .appointments: [("Appointment Preparation", ["Confirm time and location", "Prepare questions", "Bring documents", "Record outcome", "Schedule follow-up"])]
        case .routines: [("Morning Routine", ["Review today's plan", "Prepare essentials", "Start priority task"]), ("Evening Reset", ["Review completed tasks", "Prepare for tomorrow", "Tidy workspace"])]
        case .projects: [("Project Kickoff", ["Define outcome", "Break into milestones", "Choose next action", "Review progress"])]
        case .errands: [("Before You Leave", ["Check opening hours", "Bring returns and receipts", "Check shopping list"])]
        default: []
        }
    }
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
                        ForEach(starters, id: \.0) { title, names in
                            Button(title) {
                                var template = SpecializedListTemplate(title: title, listID: listID, items: [])
                                template.items = names.enumerated().map { index, name in
                                    var details = SpecializedTaskDetails()
                                    if type == .shopping { details.fields["Category"] = ShoppingCatalog.category(for: name) }
                                    if type == .routines { details.fields["Step Order"] = String(index + 1) }
                                    if type == .packing { details.fields["Essential"] = ["Travel documents", "Medication"].contains(name) ? "Yes" : "No" }
                                    if type == .household {
                                        details.fields["Season"] = title.contains("Seasonal") ? "Seasonal" : "Weekly"
                                        if let room = name.split(separator: ":").first, name.contains(":") { details.fields["Room"] = String(room) }
                                    }
                                    return .init(title: name, notes: "", details: details)
                                }
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
    @State private var autoTitle = ""
    private var url: URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
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
                } footer: { Text("Paste a link to an article, book, or video. TaskFlow fills in the title and details from the page.") }
                if let metadata, !metadata.fields.isEmpty {
                    Section("From the Page") {
                        HStack(alignment: .top, spacing: 12) {
                            if let thumbnail = metadata.thumbnailURL {
                                AsyncImage(url: thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                                    .frame(width: 56, height: 72).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
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
            .task(id: link) { await lookUp() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    guard let url else { return }; saving = true
                    Task { if await repository.addReadingLink(title: title, url: url, listID: listID, metadata: metadata) { dismiss() }; saving = false }
                }.disabled(saving || url == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
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
    @State private var price: Double?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section(task.title) {
                    TextField("Estimated Price per Unit", value: $price, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
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
                price = Double(fields["Price"] ?? "") ?? repository.rememberedShoppingPrice(title: task.title, fields: fields)
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
