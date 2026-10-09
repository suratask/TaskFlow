import SwiftUI
import UIKit
import EventKit
import CoreSpotlight
import Combine

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @Bindable var repository: TaskRepository

    @State private var hasLoadedLaunchData = false
    @State private var newListName = ""
    @State private var editorDraft: TaskDraft?
    @State private var smartListDraft: SmartListDefinition?
    @State private var isShowingSettings = false
    @State private var isShowingOnboarding = false
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
    @State private var compactTab: CompactNavigationTab = .today
    @State private var selectedCalendarEvent: CalendarEvent?
    @State private var showsSharedCapture = false
    @State private var sharedCaptureText = ""
    @State private var sharedCaptureKind = "Task"
    @State private var sharedEventDraft: EventDraft?

    var body: some View {
        Group {
            if usesCompactNavigation {
                CompactNavigationView(
                    repository: repository,
                    selectedTab: $compactTab,
                    newListName: $newListName,
                    editorDraft: $editorDraft,
                    smartListDraft: $smartListDraft,
                    isShowingSettings: $isShowingSettings,
                    isShowingOnboarding: $isShowingOnboarding,
                    selectedCalendarEvent: $selectedCalendarEvent
                )
            } else if usesLandscapeTaskSplit {
                landscapeTaskSplitView
            } else {
                splitNavigationView
            }
        }
        .task {
            hasLoadedLaunchData = false
            repository.resetLaunchSelection()
            preferredCompactColumn = .content
            await repository.bootstrap()
            TaskFlowAppShortcuts.updateAppShortcutParameters()
            await EventLiveActivityCoordinator.reconcile(events: repository.calendarEvents)
            await RoutineTimerCoordinator.reconcile()
            consumeSharedCaptureIfNeeded()
            if !repository.hasCompletedOnboarding {
                isShowingOnboarding = true
            }
            await repository.consumeWidgetCompletions()
            clearSelectionForLandscapeIfNeeded()
            openPendingNotificationTaskIfNeeded()
            hasLoadedLaunchData = true
            consumePendingIntentRoute()
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            if identifier.hasPrefix("task:") {
                let id = String(identifier.dropFirst(5))
                repository.openTask(id: id)
                preferredCompactColumn = .detail
            } else if identifier.hasPrefix("list:") {
                repository.selectedTaskID = nil
                repository.selectedScope = .list(String(identifier.dropFirst(5)))
                preferredCompactColumn = .content
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { TaskFlowAppDelegate.scheduleWatchRefresh() }
            guard phase == .active else { return }
            Task {
                await repository.reloadExternalData()
                await EventLiveActivityCoordinator.reconcile(events: repository.calendarEvents)
                await RoutineTimerCoordinator.reconcile()
                consumeSharedCaptureIfNeeded()
                consumePendingIntentRoute()
            }
        }
        .onChange(of: verticalSizeClass) { _, newValue in
            if newValue == .compact {
                clearSelectionForLandscapeIfNeeded()
            }
        }
        .onChange(of: repository.lastEventDeletion) { _, deletion in
            if let deletion, let selected = selectedCalendarEvent, deletion.includes(selected) {
                selectedCalendarEvent = nil
                preferredCompactColumn = .content
            }
        }
        .onChange(of: repository.selectedTaskID) { _, taskID in
            if taskID != nil {
                selectedCalendarEvent = nil
            }
        }
        .onChange(of: repository.selectedScope) { _, _ in
            selectedCalendarEvent = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in
            Task {
                await repository.reloadExternalData()
                await EventLiveActivityCoordinator.reconcile(events: repository.calendarEvents)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskFlowIntentRouteChanged)) { _ in
            consumePendingIntentRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskFlowFocusFilterChanged)) { _ in
            Task { await repository.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskFlowNotificationTaskTapped)) { notification in
            guard let taskID = notification.userInfo?[TaskFlowNotificationPayload.taskIDKey] as? String else { return }
            openNotificationTask(taskID)
        }
        .refreshable {
            await repository.reload()
        }
        .sheet(item: $editorDraft) { draft in
            TaskEditorView(repository: repository, draft: draft)
        }
        .sheet(isPresented: $showsSharedCapture) {
            QuickCaptureView(repository: repository, onTask: { draft in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editorDraft = draft }
            }, onEvent: { draft in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sharedEventDraft = draft }
            }, initialText: sharedCaptureText, initialKind: sharedCaptureKind)
        }
        .sheet(item: $sharedEventDraft) { draft in
            CalendarEventEditorView(repository: repository, draft: draft)
        }
        .sheet(item: $smartListDraft) { draft in
            SmartListEditorView(repository: repository, smartList: draft)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(repository: repository, onShowOnboarding: showOnboardingFromSettings)
        }
        .fullScreenCover(isPresented: selectedTaskSheetBinding) {
            NavigationStack {
                TaskDetailView(repository: repository, editorDraft: $editorDraft, showsCloseButton: true)
            }
        }
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView(repository: repository) {
                repository.completeOnboarding()
                isShowingOnboarding = false
            }
        }
        .onChange(of: repository.taskUndo?.id) { _, id in
            registerSystemUndo(id: id)
        }
        .sensoryFeedback(.success, trigger: repository.feedbackSequence)
        .sensoryFeedback(.selection, trigger: repository.selectionFeedbackSequence)
        .sensoryFeedback(.impact(weight: .light), trigger: repository.undoFeedbackSequence)
        .overlay(alignment: .bottom) {
            // Undo and error messages appear as toasts above the tab bar instead of alerts or list rows.
            StatusToastHost(repository: repository, bottomInset: usesCompactNavigation ? 64 : TaskFlowTheme.Spacing.large)
        }
        .taskFlowThemedBackground()
        .preferredColorScheme(preferredColorScheme)
        .tint(repository.appTheme.primary)
        .accentColor(repository.appTheme.primary)
    }

    private var landscapeTaskSplitView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                NavigationStack {
                    TaskCollectionView(
                        repository: repository,
                        editorDraft: $editorDraft,
                        smartListDraft: $smartListDraft,
                        selectedCalendarEvent: $selectedCalendarEvent,
                        presentsCalendarEventSheet: false
                    )
                }
                .frame(width: min(max(360, geometry.size.width * 0.43), 500))

                Divider()

                NavigationStack {
                    Group {
                        if let selectedCalendarEvent {
                            CalendarEventDetailView(
                                repository: repository,
                                event: selectedCalendarEvent,
                                color: eventColor(for: selectedCalendarEvent.calendarID)
                            )
                        } else {
                            TaskDetailView(repository: repository, editorDraft: $editorDraft)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var splitNavigationView: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            SidebarView(
                repository: repository,
                newListName: $newListName,
                smartListDraft: $smartListDraft,
                isShowingSettings: $isShowingSettings,
                preferredCompactColumn: $preferredCompactColumn
            )
        } content: {
            TaskCollectionView(
                repository: repository,
                editorDraft: $editorDraft,
                smartListDraft: $smartListDraft,
                selectedCalendarEvent: $selectedCalendarEvent,
                presentsCalendarEventSheet: false
            )
            .navigationSplitViewColumnWidth(min: 380, ideal: 520, max: 720)
        } detail: {
            Group {
                if let selectedCalendarEvent {
                    CalendarEventDetailView(
                        repository: repository,
                        event: selectedCalendarEvent,
                        color: eventColor(for: selectedCalendarEvent.calendarID)
                    )
                } else {
                    TaskDetailView(repository: repository, editorDraft: $editorDraft)
                }
            }
                .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 620)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Hands task changes to the system undo manager, so shake-to-undo, three-finger swipe, and ⌘Z all work.
    private func registerSystemUndo(id: UUID?) {
        guard id != nil, let action = repository.taskUndo, let undoManager else { return }
        undoManager.registerUndo(withTarget: repository) { repository in
            Task { @MainActor in await repository.performUndo(action) }
        }
        undoManager.setActionName(action.message)
    }

    private var preferredColorScheme: ColorScheme? {
        switch repository.appearanceMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var usesCompactNavigation: Bool {
        horizontalSizeClass == .compact
    }

    private var usesLandscapeTaskSplit: Bool {
        verticalSizeClass == .compact
    }

    private var selectedTaskSheetBinding: Binding<Bool> {
        Binding {
            usesCompactNavigation && repository.selectedTaskID != nil
        } set: { isPresented in
            if !isPresented {
                repository.selectedTaskID = nil
            }
        }
    }

    @State private var isImportingSharedNotes = false
    @State private var isImportingReadingLinks = false

    private func consumeSharedCaptureIfNeeded() {
        if let defaults = UserDefaults(suiteName: "group.com.surratt.TaskFlow"),
           let notes = defaults.array(forKey: "TaskFlow.pendingSharedNotes") as? [String], !notes.isEmpty, !isImportingSharedNotes {
            isImportingSharedNotes = true
            Task {
                defer { isImportingSharedNotes = false }
                for text in notes where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await repository.addQuickNote(title: "", text: text, tags: [], linkedTaskID: nil)
                }
                let current = defaults.array(forKey: "TaskFlow.pendingSharedNotes") as? [String] ?? []
                defaults.set(Array(current.dropFirst(notes.count)), forKey: "TaskFlow.pendingSharedNotes")
            }
        }
        for capture in TextShareCapture.pending() where capture.kind == "Note" {
            // Stable IDs make an interrupted import safe to retry.
            var note = QuickNote(text: capture.text)
            note.id = capture.id
            if repository.quickNotes.contains(where: { $0.id == capture.id }) || repository.saveNoteSnapshot(note) { capture.acknowledge() }
        }
        if !showsSharedCapture, editorDraft == nil, sharedEventDraft == nil,
           let capture = TextShareCapture.pending().first(where: { $0.kind != "Note" }) {
            sharedCaptureText = capture.text
            sharedCaptureKind = capture.kind
            capture.acknowledge()
            showsSharedCapture = true
        }
        let mediaDefaults = ReadingMedia.defaults
        let legacyLinks = mediaDefaults.stringArray(forKey: "TaskFlow.pendingReadingLinks") ?? []
        if !isImportingReadingLinks, repository.accessState == .granted,
           !legacyLinks.isEmpty || !ReadingMedia.captures().isEmpty {
            isImportingReadingLinks = true
            Task {
                defer { isImportingReadingLinks = false }
                var unsaved: [String] = []
                for link in legacyLinks {
                    guard let url = URL(string: link) else { unsaved.append(link); continue }
                    if !(await repository.addSharedReadingLink(url)) { unsaved.append(link) }
                }
                let current = mediaDefaults.stringArray(forKey: "TaskFlow.pendingReadingLinks") ?? []
                mediaDefaults.set(unsaved + Array(current.dropFirst(legacyLinks.count)), forKey: "TaskFlow.pendingReadingLinks")
                for capture in ReadingMedia.captures() {
                    if await repository.importMediaCapture(capture) { ReadingMedia.acknowledge(capture.id) }
                }
                if repository.preferredReadingListID == nil {
                    repository.errorMessage = "Create a Reading & Watch Later list to import your saved links. Your links are still saved."
                }
            }
        }
        guard !showsSharedCapture, let defaults = UserDefaults(suiteName: "group.com.surratt.TaskFlow"),
              let payload = defaults.dictionary(forKey: "TaskFlow.pendingShareCapture"),
              let text = payload["text"] as? String, !text.isEmpty else { return }
        sharedCaptureText = text
        sharedCaptureKind = payload["kind"] as? String ?? "Task"
        defaults.removeObject(forKey: "TaskFlow.pendingShareCapture")
        showsSharedCapture = true
    }

    private func openPendingNotificationTaskIfNeeded() {
        guard let taskID = NotificationTapRouter.shared.consumePendingTaskID() else { return }
        openNotificationTask(taskID)
    }

    private func openNotificationTask(_ taskID: String) {
        selectedCalendarEvent = nil
        repository.openTask(id: taskID)
        preferredCompactColumn = .detail
        if repository.pendingOpenTaskID != nil {
            Task { await repository.reload() }
        }
    }

    private func consumePendingIntentRoute() {
        guard hasLoadedLaunchData else { return }
        guard let url = TaskFlowIntentRoute.consume() else { return }
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == TaskFlowDeepLink.scheme else { return }

        if url.host == "capture" {
            sharedCaptureText = ""
            sharedCaptureKind = "Task"
            showsSharedCapture = true
        } else if url == TaskFlowDeepLink.newNoteURL || url == TaskFlowDeepLink.dictateNoteURL {
            selectedCalendarEvent = nil
            repository.selectedTaskID = nil
            compactTab = .notes
            repository.selectedScope = .notes
            preferredCompactColumn = .content
            repository.pendingNoteCapture = url == TaskFlowDeepLink.dictateNoteURL ? .dictateNote : .newNote
        } else if url.host == "note", let value = url.pathComponents.dropFirst().first, let id = UUID(uuidString: value) {
            compactTab = .notes
            repository.selectedTaskID = nil
            repository.selectedScope = .notes
            repository.pendingOpenNoteID = id
            preferredCompactColumn = .content
        } else if url.host == "event", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            openCalendarView()
            if let event = repository.calendarEvents.first(where: { $0.id == id }) {
                selectedCalendarEvent = event
            } else {
                Task {
                    await repository.reload()
                    selectedCalendarEvent = repository.calendarEvents.first { $0.id == id }
                }
            }
        } else if url.host == "calendar" {
            openCalendarView()
        } else if url.host == "task", let id = url.pathComponents.dropFirst().first {
            compactTab = .tasks
            repository.taskViewMode = .list
            repository.openTask(id: id)
            preferredCompactColumn = .detail
            if repository.pendingOpenTaskID != nil { Task { await repository.reload() } }
        } else if url.host == "list", let id = url.pathComponents.dropFirst().first {
            compactTab = .tasks
            repository.taskViewMode = .list
            repository.selectedTaskID = nil
            repository.selectedScope = .list(id)
            if usesCompactNavigation { repository.pendingOpenListID = id }
            preferredCompactColumn = .content
        }
    }

    private func openCalendarView() {
        compactTab = .calendar
        selectedCalendarEvent = nil
        repository.selectedScope = .inbox
        repository.selectedTaskID = nil
        repository.taskViewMode = .calendar
        preferredCompactColumn = .content
    }

    private func showOnboardingFromSettings() {
        isShowingSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            isShowingOnboarding = true
        }
    }

    private func clearSelectionForLandscapeIfNeeded() {
        guard verticalSizeClass == .compact else { return }
        selectedCalendarEvent = nil
        repository.selectedTaskID = nil
        preferredCompactColumn = .content
    }

    private func eventColor(for calendarID: String) -> Color {
        repository.eventCalendars.first { $0.id == calendarID }?.color ?? .blue
    }
}

private enum CompactNavigationTab: String, Hashable, CaseIterable {
    case today
    case tasks
    case calendar
    case notes
    case search

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .tasks: "Tasks"
        case .notes: "Notes"
        case .today: "Today"
        case .search: "Search"
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .tasks: "checklist"
        case .notes: "note.text"
        case .today: "sun.max"
        case .search: "magnifyingglass"
        }
    }
}

private struct OnboardingView: View {
    @Bindable var repository: TaskRepository
    let onFinish: () -> Void

    private let features = OnboardingPage.pages.filter { $0.action == .none }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(.largeTitle))
                            .foregroundStyle(.tint)
                        Text("Welcome to TaskFlow Studio")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text("Your reminders, calendar, and notes in one place.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                NavigationLink("Set Up TaskFlow") { GuidedSetupView(repository: repository) }

                Section("What You Can Do") {
                    ForEach(features) { page in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.title).font(.headline)
                                Text(page.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: page.icon).foregroundStyle(page.color)
                        }
                    }
                }

                Section {
                    permissionRow("Reminders", icon: "checklist", isGranted: repository.accessState == .granted) {
                        Task { await repository.requestAccess() }
                    }
                    permissionRow("Calendar", icon: "calendar", isGranted: repository.eventAccessState == .granted) {
                        Task { await repository.requestEventCalendarAccess() }
                    }
                    permissionRow("Notifications", icon: "bell", isGranted: repository.notificationStatus == .granted) {
                        Task { await repository.requestNotificationAccess() }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("TaskFlow Studio stores tasks in Apple Reminders. Calendar and notifications are optional and can be changed later in Settings.")
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onFinish()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .interactiveDismissDisabled()
        }
    }

    private func permissionRow(_ title: String, icon: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            } else {
                // Neutral wording (App Review 5.1.1(iv)): the system prompt is where the user decides.
                Button("Continue", action: action)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Continue to \(title) permission")
            }
        }
    }
}

private struct OnboardingPage: Identifiable {
    enum Action {
        case reminders
        case calendar
        case notifications
        case none
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let bullets: [String]
    let actionTitle: String?
    let action: Action

    static let pages: [OnboardingPage] = [
        OnboardingPage(
            id: "welcome",
            title: "Shape The Work Before You Do It",
            subtitle: "TaskFlow Studio turns reminders, notes, timelines, and planning into one focused workspace.",
            icon: "sparkles",
            color: .cyan,
            bullets: ["Capture tasks quickly", "Plan a realistic day", "Review progress through milestones"],
            actionTitle: nil,
            action: .none
        ),
        OnboardingPage(
            id: "reminders",
            title: "Connect Reminders",
            subtitle: "Your tasks are powered by Apple Reminders, so completion state and due dates stay available across the system.",
            icon: "checklist",
            color: .green,
            bullets: ["Create and edit reminder tasks", "Use lists as workspaces", "Complete tasks from widgets"],
            actionTitle: "Continue",
            action: .reminders
        ),
        OnboardingPage(
            id: "planning",
            title: "Plan Your Day",
            subtitle: "Use Plan My Day to review overdue, due today, flagged, and high-priority work before committing.",
            icon: "sun.max.fill",
            color: .yellow,
            bullets: ["Commit selected work to today", "Defer tasks intentionally", "Track estimated workload"],
            actionTitle: nil,
            action: .none
        ),
        OnboardingPage(
            id: "timeline",
            title: "Read The Timeline",
            subtitle: "Timeline cards show lifecycle milestones like creation, due dates, completion, notes, and attachments.",
            icon: "timeline.selection",
            color: .purple,
            bullets: ["See task progress at a glance", "Review recent notes and files", "Search across task context"],
            actionTitle: nil,
            action: .none
        ),
        OnboardingPage(
            id: "calendar",
            title: "Bring In Calendar Context",
            subtitle: "Calendar events can appear alongside due tasks, making the day easier to schedule.",
            icon: "calendar.badge.plus",
            color: .teal,
            bullets: ["Show selected event calendars", "Open event locations in Maps", "Compare tasks and meetings"],
            actionTitle: "Continue",
            action: .calendar
        ),
        OnboardingPage(
            id: "alerts",
            title: "Stay In Flow",
            subtitle: "Widgets and local notifications keep today visible without needing to open the app.",
            icon: "bell.badge.fill",
            color: .orange,
            bullets: ["Use the Today widget", "Complete tasks from the widget", "Get due-task alerts"],
            actionTitle: "Continue",
            action: .notifications
        )
    ]
}

private struct CompactNavigationView: View {
    @Bindable var repository: TaskRepository
    @Binding var selectedTab: CompactNavigationTab
    @Binding var newListName: String
    @Binding var editorDraft: TaskDraft?
    @Binding var smartListDraft: SmartListDefinition?
    @Binding var isShowingSettings: Bool
    @Binding var isShowingOnboarding: Bool
    @Binding var selectedCalendarEvent: CalendarEvent?

    var body: some View {
        if #available(iOS 18.0, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    /// iOS 18+ tab bar with a dedicated Search tab; on iOS 26 it also shrinks while scrolling.
    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $selectedTab) {
            Tab(CompactNavigationTab.today.title, systemImage: CompactNavigationTab.today.icon, value: CompactNavigationTab.today) {
                todayTab
            }
            Tab(CompactNavigationTab.tasks.title, systemImage: CompactNavigationTab.tasks.icon, value: CompactNavigationTab.tasks) {
                tasksTab
            }
            Tab(CompactNavigationTab.calendar.title, systemImage: CompactNavigationTab.calendar.icon, value: CompactNavigationTab.calendar) {
                calendarTab
            }
            Tab(CompactNavigationTab.notes.title, systemImage: CompactNavigationTab.notes.icon, value: CompactNavigationTab.notes) {
                notesTab
            }
            Tab(value: CompactNavigationTab.search, role: .search) {
                searchTab
            }
        }
        .minimizingTabBarOnScroll()
    }

    private var legacyTabs: some View {
        TabView(selection: $selectedTab) {
            todayTab
                .tabItem { Label(CompactNavigationTab.today.title, systemImage: CompactNavigationTab.today.icon) }
                .tag(CompactNavigationTab.today)
            tasksTab
                .tabItem { Label(CompactNavigationTab.tasks.title, systemImage: CompactNavigationTab.tasks.icon) }
                .tag(CompactNavigationTab.tasks)
            calendarTab
                .tabItem { Label(CompactNavigationTab.calendar.title, systemImage: CompactNavigationTab.calendar.icon) }
                .tag(CompactNavigationTab.calendar)
            notesTab
                .tabItem { Label(CompactNavigationTab.notes.title, systemImage: CompactNavigationTab.notes.icon) }
                .tag(CompactNavigationTab.notes)
        }
    }

    private var todayTab: some View {
        NavigationStack {
            TodayDashboardView(repository: repository, editorDraft: $editorDraft)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                    }
                }
        }
    }

    private var searchTab: some View {
        NavigationStack {
            UnifiedSearchView(repository: repository, selectedCalendarEvent: $selectedCalendarEvent)
        }
    }

    private var calendarTab: some View {
        CompactTaskTabView(
            repository: repository,
            editorDraft: $editorDraft,
            smartListDraft: $smartListDraft,
            title: "Calendar",
            selectedCalendarEvent: $selectedCalendarEvent,
            viewModeOverride: .calendar
        )
    }

    private var tasksTab: some View {
        TasksHomeView(repository: repository, editorDraft: $editorDraft, smartListDraft: $smartListDraft, selectedCalendarEvent: $selectedCalendarEvent)
    }

    private var notesTab: some View {
        CompactNotesTabView(
            repository: repository,
            selectedCalendarEvent: $selectedCalendarEvent
        )
    }

}

private struct CompactTaskTabView: View {
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?
    @Binding var smartListDraft: SmartListDefinition?
    var title: String?
    @Binding var selectedCalendarEvent: CalendarEvent?
    var viewModeOverride: TaskRepository.TaskViewMode?

    var body: some View {
        NavigationStack {
            TaskCollectionView(
                repository: repository,
                editorDraft: $editorDraft,
                smartListDraft: $smartListDraft,
                selectedCalendarEvent: $selectedCalendarEvent,
                viewModeOverride: viewModeOverride,
                titleOverride: title
            )
        }
    }
}

private struct CompactNotesTabView: View {
    @Bindable var repository: TaskRepository
    @Binding var selectedCalendarEvent: CalendarEvent?

    var body: some View {
        NavigationStack {
            AllNotesView(
                repository: repository,
                selectedCalendarEvent: $selectedCalendarEvent
            )
        }
    }
}

private enum SidebarItem: Hashable {
    case scope(TaskScope)
    case calendar
}

private struct SidebarView: View {
    @Bindable var repository: TaskRepository
    @Binding var newListName: String
    @Binding var smartListDraft: SmartListDefinition?
    @Binding var isShowingSettings: Bool
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    var body: some View {
        List(selection: selection) {
            Section {
                scopeRow(.inbox, title: "Open", icon: "tray.full", color: .blue)
                scopeRow(.today, title: "Today", icon: "calendar", color: .teal)
                scopeRow(.next7Days, title: "Upcoming", icon: "calendar.badge.clock", color: .cyan)
                Label { Text("Calendar") } icon: { Image(systemName: "calendar").foregroundStyle(.indigo) }
                    .badge(repository.filteredCalendarEvents.count)
                    .tag(SidebarItem.calendar)
                scopeRow(.flagged, title: "Flagged", icon: "flag", color: .orange)
                scopeRow(.completed, title: "Completed", icon: "checkmark.circle", color: .green)
                scopeRow(.notes, title: "Notes", icon: "note.text", color: .purple)
            }

            if !repository.pinnedItemIDs.isEmpty {
                Section("Pinned") {
                    ForEach(repository.pinnedItemIDs, id: \.self) { itemID in
                        if itemID == PinnedTaskIdentifier.allTasks {
                            scopeRow(.all, title: "All Tasks", icon: "tray.full", color: repository.appTheme.primary)
                        } else if itemID == PinnedTaskIdentifier.upNext {
                            scopeRow(.upNext, title: "Upcoming", icon: "calendar.badge.clock", color: repository.appTheme.secondary)
                        } else if let list = repository.lists.first(where: { $0.id == itemID }) {
                            listRow(list, isPinned: true)
                        }
                    }
                }
            }

            Section("Lists") {
                ForEach(repository.unpinnedLists) { list in
                    listRow(list, isPinned: false)
                }

                TextField("New List", text: $newListName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(createList)
            }

            Section("Smart Lists") {
                ForEach(repository.smartLists) { smartList in
                    scopeRow(.smart(smartList.id), title: smartList.title, icon: smartList.icon, color: .purple)
                        .swipeActions {
                            Button(role: .destructive) {
                                repository.deleteSmartList(smartList)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                smartListDraft = smartList
                            } label: {
                                Label("Edit", systemImage: "slider.horizontal.3")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                smartListDraft = smartList
                            } label: {
                                Label("Edit Smart List", systemImage: "slider.horizontal.3")
                            }

                            Button(role: .destructive) {
                                repository.deleteSmartList(smartList)
                            } label: {
                                Label("Delete Smart List", systemImage: "trash")
                            }
                        }
                }

                Button {
                    smartListDraft = SmartListDefinition(title: "New Smart List")
                } label: {
                    Label("Add Smart List", systemImage: "plus")
                }
            }
        }
        .listStyle(.sidebar)
        .taskFlowThemedBackground()
        .navigationTitle("TaskFlow Studio")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
            }
        }
        .overlay {
            if repository.accessState != .granted {
                AccessOverlay(repository: repository)
            }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            if repository.taskViewMode == .calendar && repository.selectedScope == .inbox {
                return .calendar
            }
            return .scope(repository.selectedScope)
        } set: { item in
            guard let item else { return }
            repository.selectedTaskID = nil
            switch item {
            case .calendar:
                repository.selectedScope = .inbox
                repository.taskViewMode = .calendar
            case .scope(let scope):
                repository.selectedScope = scope
                if repository.taskViewMode == .calendar || repository.taskViewMode == .agenda {
                    repository.taskViewMode = .list
                }
            }
            preferredCompactColumn = .content
        }
    }

    private func scopeRow(_ scope: TaskScope, title: String, icon: String, color: Color) -> some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .badge(repository.taskCount(for: scope))
            .tag(SidebarItem.scope(scope))
    }

    private func listRow(_ list: TaskList, isPinned: Bool) -> some View {
        Label { Text(list.title) } icon: { Image(systemName: repository.listIcon(for: list.id)).foregroundStyle(list.color) }
            .badge(repository.taskCount(for: .list(list.id)))
            .tag(SidebarItem.scope(.list(list.id)))
            .dropDestination(for: String.self) { taskIDs, _ in
                // Drag tasks from the task list onto a sidebar list to move them, as in Reminders on iPad.
                Task { await repository.moveTasks(toListID: list.id, taskIDs: Set(taskIDs)) }
                return !taskIDs.isEmpty
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    repository.togglePinnedList(list)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                }
                .tint(isPinned ? .gray : .orange)
            }
            .contextMenu {
                Button {
                    repository.togglePinnedList(list)
                } label: {
                    Label(isPinned ? "Unpin List" : "Pin List", systemImage: isPinned ? "pin.slash" : "pin")
                }
            }
    }

    private func createList() {
        let title = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newListName = ""
        Task { await repository.createList(named: title) }
    }
}

private struct AccessOverlay: View {
    let repository: TaskRepository

    var body: some View {
        ContentUnavailableView {
            Label("Reminders Access", systemImage: "checklist")
        } description: {
            Text(repository.accessState.message)
        } actions: {
            if repository.accessState == .unknown {
                // Neutral wording (App Review 5.1.1(iv)): the system prompt is where the user decides.
                Button("Continue") {
                    Task { await repository.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                // Once denied, iOS won't ask again; only Settings can change it.
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .background(.regularMaterial)
    }
}

extension SmartListDefinition {
    static var new: SmartListDefinition {
        SmartListDefinition(title: "New Smart List")
    }
}
