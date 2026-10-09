import SwiftUI
import AVFoundation
import Speech
import EventKit
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismissSettings
    @Bindable var repository: TaskRepository
    var onShowOnboarding: () -> Void = {}
    @State private var newTag = ""
    @State private var addingShopper = false
    @State private var newShopperName = ""
    @State private var tagToRename: String?
    @State private var renameTagText = ""
    @State private var tagToDelete: String?

    var body: some View {
        NavigationStack {
            Form {
                NavigationLink("Set Up TaskFlow") { GuidedSetupView(repository: repository) }
                SettingsPermissionsSection(repository: repository)

                Section("Shopping") {
                    Picker("Your Shopper Name", selection: Binding(get: { repository.shoppingShopperName }, set: { repository.selectShoppingShopper($0) })) {
                        Text("Not Set").tag("")
                        ForEach(repository.shoppingShopperChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Add Shopper Name", systemImage: "person.badge.plus") { newShopperName = ""; addingShopper = true }
                    Text("Shown when you add or purchase items in shared shopping lists. Changes arrive through the list’s Reminders account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                .alert("Add Shopper Name", isPresented: $addingShopper) {
                    TextField("Name", text: $newShopperName).textContentType(.name)
                    Button("Cancel", role: .cancel) { newShopperName = "" }
                    Button("Add") { repository.selectShoppingShopper(newShopperName); newShopperName = "" }
                        .disabled(newShopperName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Share Extension") {
                    ForEach([false, true], id: \.self) { watch in
                        Picker(watch ? "Watch Later List" : "Read Later List", selection: Binding(get: {
                            ReadingMedia.defaults.string(forKey: ReadingMedia.preferenceKey(watch: watch)) ?? ""
                        }, set: { ReadingMedia.defaults.set($0, forKey: ReadingMedia.preferenceKey(watch: watch)) })) {
                            Text("Automatic").tag("")
                            ForEach(repository.lists.filter { repository.listProfile($0.id).type == .reading }) { list in
                                Text(list.title).tag(list.id)
                            }
                        }
                    }
                    Text("Shared videos default to Watch Later; articles and other links default to Read Later. Choose any Reading & Watch Later list. Links are kept safely until TaskFlow opens and imports them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("iCloud Sync") {
                    Text(repository.cloudSyncStatus).font(.footnote).foregroundStyle(.secondary)
                    Button("Sync Now") { Task { await repository.synchronizeCloud() } }
                    Text("Syncs notes, tags, comments, pinned lists, specialized list details, templates, and appearance and task-view settings. Reminders and events use their calendar accounts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        Form {
                        Section {
                            Picker("Appearance", selection: $repository.appearanceMode) {
                                ForEach(TaskRepository.AppearanceMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }

                            NavigationLink {
                                AppThemePicker(repository: repository)
                            } label: {
                                HStack {
                                    Text("App Theme")
                                    Spacer()
                                    Text(repository.appTheme.rawValue).foregroundStyle(.secondary)
                                    Image(systemName: "circle.fill").foregroundStyle(repository.appTheme.primary)
                                }
                            }

                        } header: {
                            Text("Appearance")
                        }
                        Section {
                            Picker("Task Density", selection: $repository.taskDensity) {
                                ForEach(TaskRepository.TaskDensity.allCases) { density in
                                    Text(density.rawValue).tag(density)
                                }
                            }
                        } header: {
                            Text("Accessibility")
                        } footer: {
                            Text("Text size follows your device’s Dynamic Type setting. Choose compact, comfortable, or detailed task rows.")
                        }
                        }
                        .taskFlowThemedBackground()
                        .navigationTitle("Appearance")
                    } label: {
                        Label { Text("Appearance") } icon: { SettingsIcon(systemName: "paintbrush.fill", color: .blue) }
                    }
                    NavigationLink {
                        Form {
                        Section {
                            Toggle("Show Completed Tasks", isOn: $repository.includeCompletedTasks)

                            Picker("Group By", selection: $repository.taskGroupOption) {
                                ForEach(TaskRepository.TaskGroupOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }

                            Picker("Sort By", selection: $repository.taskSortOption) {
                                ForEach(TaskRepository.TaskSortOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }

                            Picker("Sort Direction", selection: $repository.taskSortDirection) {
                                ForEach(TaskRepository.TaskSortDirection.allCases) { direction in
                                    Text(direction.rawValue).tag(direction)
                                }
                            }
                        } header: {
                            Text("Display")
                        }
                        Section {
                            Picker("Default List", selection: $repository.defaultListID) {
                                Text("First Available").tag("")
                                ForEach(repository.lists) { list in
                                    Text(list.title).tag(list.id)
                                }
                            }

                            NavigationLink("Edit Reminder Lists") {
                                List {
                                    ForEach(repository.lists) { list in
                                        NavigationLink { ReminderListSettings(repository: repository, list: list) } label: { Label(list.title, systemImage: repository.listIcon(for: list.id)).foregroundStyle(list.color) }
                                    }.onMove { repository.moveLists(fromOffsets: $0, toOffset: $1) }
                                }
                                .navigationTitle("Reminder Lists")
                                .toolbar { EditButton() }
                            }
                            if repository.lists.isEmpty {
                                Text("Enable Reminders access or create a list before choosing a default.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Tasks")
                        } footer: {
                            Text("New tasks created outside a specific list will use this list.")
                        }
                        }
                        .taskFlowThemedBackground()
                        .navigationTitle("Tasks & Lists")
                    } label: {
                        Label { Text("Tasks & Lists") } icon: { SettingsIcon(systemName: "checklist", color: .orange) }
                    }
                    NavigationLink {
                        Form {
                        Section {
                            LabeledContent("Permission", value: repository.eventAccessState.rawValue)

                            if repository.eventAccessState == .unknown {
                                Button {
                                    Task { await repository.requestEventCalendarAccess() }
                                } label: {
                                    Label("Continue", systemImage: "calendar.badge.plus")
                                }
                            } else if repository.eventAccessState == .granted {
                                if repository.eventCalendars.isEmpty {
                                    Text("No event calendars are available.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    if !repository.writableEventCalendars.isEmpty {
                                        Picker("Default Calendar", selection: $repository.defaultEventCalendarID) {
                                            Text("First Writable").tag("")
                                            ForEach(repository.writableEventCalendars) { calendar in
                                                Text(calendar.title).tag(calendar.id)
                                            }
                                        }
                                    }

                                    Button("Use my calendars") { Task { await repository.useMyCalendars() } }
                                    DisclosureGroup("Customize") {
                                    ForEach(repository.eventCalendars) { calendar in
                                        Toggle(isOn: eventCalendarSelection(for: calendar)) {
                                            HStack(spacing: 12) {
                                                Circle()
                                                    .fill(calendar.color)
                                                    .frame(width: 16, height: 16)
                                                Text(calendar.title)
                                            }
                                        }
                                    }
                                    }
                                }
                            } else {
                                Text(repository.eventAccessState.message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Event Calendars")
                        } footer: {
                            Text("Selected calendars appear as events in the task calendar view. New events use the default calendar when one is set.")
                        }
                        if repository.eventAccessState == .granted && !repository.eventCalendars.isEmpty {
                            Section {
                                ForEach(repository.eventCalendars) { calendar in
                                    Toggle(isOn: Binding(
                                        get: { repository.calendarAffectsAvailability(calendar.id) },
                                        set: { repository.setCalendarAffectsAvailability(calendar, $0) }
                                    )) {
                                        HStack(spacing: 12) {
                                            Circle().fill(calendar.color).frame(width: 16, height: 16)
                                            Text(calendar.title)
                                        }
                                    }
                                }
                            } header: { Text("Affects Availability") }
                            footer: { Text("Turn off calendars that should not block your time, such as holidays or reference calendars. Their events stay visible but are excluded from conflict checks and open-time suggestions. This does not change the events’ Show As status.") }
                        }
                        }
                        .taskFlowThemedBackground()
                        .navigationTitle("Calendars")
                    } label: {
                        Label { Text("Calendars") } icon: { SettingsIcon(systemName: "calendar", color: .red) }
                    }
                    NavigationLink {
                        Form {
                        Section {
                            Toggle(isOn: notificationToggle) {
                                Label("Background Notifications", systemImage: "bell.badge")
                            }
                            Toggle(isOn: $repository.showsDueTodayLiveActivity) {
                                Label("Today\u{2019}s Tasks on Lock Screen", systemImage: "rectangle.inset.filled.and.person.filled")
                            }

                            LabeledContent("Permission", value: repository.notificationStatus.rawValue)

                            if repository.notificationStatus == .denied {
                                Text("Notifications are turned off in system Settings.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Alerts")
                        } footer: {
                            Text("TaskFlow Studio schedules local notifications for incomplete tasks with future due dates and refreshes them when reminders change.")
                        }
                        }
                        .taskFlowThemedBackground()
                        .navigationTitle("Notifications")
                    } label: {
                        Label { Text("Notifications") } icon: { SettingsIcon(systemName: "bell.badge.fill", color: .pink) }
                    }
                    NavigationLink {
                        Form {
                        Section("Tags") {
                            HStack {
                                TextField("New tag", text: $newTag)
                                    .textInputAutocapitalization(.never)
                                Button {
                                    addTag()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .disabled(MetadataStore.normalizedTag(newTag).isEmpty)
                            }

                            if repository.allTags.isEmpty {
                                Text("Create a tag here or from any reminder, event, or note.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(repository.allTags, id: \.self) { tagName in
                                    let tag = repository.savedTags.first { $0.name.localizedCaseInsensitiveCompare(tagName) == .orderedSame }
                                    let tagColor = tag?.color ?? MetadataSnapshot.defaultColor(for: tagName)
                                    HStack(spacing: 12) {
                                        Circle()
                                            .fill(tagColor.color)
                                            .frame(width: 16, height: 16)
                                        Label(tagName, systemImage: "tag.fill")
                                            .foregroundStyle(tagColor.color)
                                        Spacer()
                                        Text("\(repository.tagUsageCount(tagName))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Menu {
                                            Button("Rename", systemImage: "pencil") {
                                                tagToRename = tagName
                                                renameTagText = tagName
                                            }
                                            Menu("Color") {
                                                ForEach(TaskTagColor.allCases) { color in
                                                    Button {
                                                        repository.setTagColor(color, for: tagName)
                                                    } label: {
                                                        Label(color.title, systemImage: tagColor == color ? "checkmark.circle.fill" : "circle.fill")
                                                    }
                                                }
                                            }
                                            Button("Delete Tag", systemImage: "trash", role: .destructive) {
                                                tagToDelete = tagName
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .foregroundStyle(tagColor.color)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        }
                        .taskFlowThemedBackground()
                        .navigationTitle("Tags")
                    } label: {
                        Label { Text("Tags") } icon: { SettingsIcon(systemName: "number", color: .purple) }
                    }
                }

                Section {
                    Button("Show Welcome Screen") { onShowOnboarding() }
                    LabeledContent("Version", value: appVersionDisplay)
                } footer: {
                    Text("TaskFlow Studio keeps your tasks in Apple Reminders and reads events from Apple Calendar.")
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismissSettings() }
                }
            }
            .confirmationDialog(
                "Delete #\(tagToDelete ?? "")?",
                isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Tag", role: .destructive) {
                    guard let name = tagToDelete else { return }
                    tagToDelete = nil
                    Task { await repository.deleteSavedTag(name) }
                }
            } message: {
                Text("This removes the tag from every reminder, event, and note that uses it.")
            }
            .alert("Rename Tag", isPresented: Binding(
                get: { tagToRename != nil },
                set: { if !$0 { tagToRename = nil } }
            )) {
                TextField("Tag name", text: $renameTagText)
                Button("Cancel", role: .cancel) { tagToRename = nil }
                Button("Save") {
                    guard let oldName = tagToRename else { return }
                    let newName = renameTagText
                    tagToRename = nil
                    Task { await repository.renameSavedTag(oldName, to: newName) }
                }
                .disabled(MetadataStore.normalizedTag(renameTagText).isEmpty)
            } message: {
                Text("The new name will update every reminder, event, and note using this tag.")
            }
        }
    }

    private var appVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty,
              build != version
        else {
            return version
        }
        return "\(version) (\(build))"
    }

    private var notificationToggle: Binding<Bool> {
        Binding {
            repository.notificationsEnabled
        } set: { isEnabled in
            if isEnabled {
                Task { await repository.requestNotificationAccess() }
            } else {
                repository.notificationsEnabled = false
            }
        }
    }

    private func eventCalendarSelection(for calendar: EventCalendar) -> Binding<Bool> {
        Binding {
            repository.selectedEventCalendarIDs.contains(calendar.id)
        } set: { isSelected in
            repository.setEventCalendar(calendar, isSelected: isSelected)
        }
    }

    private func addTag() {
        repository.saveTag(newTag)
        newTag = ""
    }
}

struct ReminderListSettings: View {
    @Environment(\.dismiss) private var dismiss
    let repository: TaskRepository
    let list: TaskList
    @State private var title = ""
    @State private var color = Color.blue
    @State private var icon = "list.bullet"
    @State private var profile = SpecializedListProfile()
    @State private var includeStarter = false
    @State private var starterIndex = 0
    @State private var initialized = false
    @State private var saving = false
    @State private var error = ""
    var body: some View {
        Form {
            TextField("List name", text: $title)
            Section {
                NavigationLink { ListTypeChooser(selection: $profile.type) } label: {
                    LabeledContent("List Type", value: profile.type.rawValue)
                }
                if profile.type == .standard, let suggestion = SpecializedListType.suggested(for: title) {
                    Button("Use \(suggestion.rawValue) Layout", systemImage: suggestion.icon) { profile.type = suggestion }
                }
                Text(profile.type.shortDescription).font(.subheadline).foregroundStyle(.secondary)
                ListTypeSample(type: profile.type)
                if !profile.type.fields.isEmpty { Text("Example fields: " + profile.type.fields.prefix(4).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            } footer: { Text(profile.type.syncExplanation) }
            if !profile.type.starterSets.isEmpty {
                Section {
                    Toggle("Include Starter Template", isOn: $includeStarter)
                    if includeStarter {
                        Picker("Template", selection: $starterIndex) {
                            ForEach(profile.type.starterSets.indices, id: \.self) { index in Text(profile.type.starterSets[index].0).tag(index) }
                        }
                        if profile.type.starterSets.indices.contains(starterIndex) {
                            ForEach(profile.type.starterSets[starterIndex].1, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                } footer: { Text("The template is saved under List Tools → Templates. Start it when you're ready; existing reminders stay as they are.") }
            }
            if profile.type == .packing {
                TextField("Trip name", text: Binding(get: { profile.settings["Trip"] ?? "" }, set: { profile.settings["Trip"] = $0 }))
                TextField("Travel dates", text: Binding(get: { profile.settings["Travel Dates"] ?? "" }, set: { profile.settings["Travel Dates"] = $0 }))
            }
            if profile.type == .shopping {
                NavigationLink("Categories & Aisle Order") { ShoppingCategoryManager(repository: repository, listID: list.id) }
                Section {
                    ShoppingDefaultStorePicker(repository: repository, listID: list.id, selection: Binding(get: { profile.settings["Default Store"] ?? "" }, set: { profile.settings["Default Store"] = $0 }))
                } footer: {
                    Text("New items use this store unless you select another store filter. You can change the store on each item; existing items keep their stores.")
                }
            }
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            NavigationLink { ListIconPicker(selection: $icon) } label: {
                Label("List Icon", systemImage: icon)
            }
            Label(title.isEmpty ? "List Preview" : title, systemImage: icon)
                .font(.title3).foregroundStyle(color)
            Text("Name and color sync with Apple Reminders. The icon is saved in TaskFlow on this device.").font(.footnote).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Button(saving ? "Saving…" : "Save") {
                saving = true
                Task {
                    let saved = (title == list.title && color == list.color) ? true : await repository.updateList(id: list.id, title: title, color: color)
                    if saved {
                        repository.setListIcon(icon, for: list.id)
                        // Category settings may have changed in their own manager while this form was open.
                        let latest = repository.listProfile(list.id)
                        for key in ["Shopping Categories", "Shopping Category Orders", "Aisle Order"] { profile.settings[key] = latest.settings[key] }
                        repository.setListProfile(profile, for: list.id)
                        if includeStarter, let template = profile.type.starterTemplate(index: starterIndex, listID: list.id) {
                            repository.listTemplates.append(template)
                            repository.updateListTemplate(template)
                        }
                        dismiss()
                    }
                    else { error = repository.errorMessage ?? "Unable to save list." }
                    saving = false
                }
            }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .taskFlowThemedBackground()
        .navigationTitle("Edit List")
        .onChange(of: profile.type) { includeStarter = false; starterIndex = 0 }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            title = list.title
            color = list.color
            icon = repository.listIcon(for: list.id)
            profile = repository.listProfile(list.id)
        }
    }
}

/// The rounded, colored icon used for rows in the iOS Settings app.
private struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}


private struct AppThemePicker: View {
    @Bindable var repository: TaskRepository
    var body: some View {
        List {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Today", systemImage: "sun.max.fill").font(.title2.bold()).foregroundStyle(repository.appTheme.primary)
                    HStack {
                        Image(systemName: "circle").font(.title2).foregroundStyle(repository.appTheme.secondary)
                        VStack(alignment: .leading) {
                            Text("Plan your day").font(.headline)
                            Text("Tasks, calendar, and notes").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Label("Quick Capture", systemImage: "plus").foregroundStyle(repository.appTheme.primary)
                }
                .padding(.vertical, 8)
            }
            Section {
                ForEach(TaskRepository.AppTheme.selectableCases) { theme in
                    Button { repository.appTheme = theme } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.fill").font(.title2).foregroundStyle(theme.primary)
                            Text(theme.rawValue).foregroundStyle(.primary)
                            Spacer()
                            if repository.appTheme == theme {
                                Image(systemName: "checkmark").foregroundStyle(theme.primary)
                            }
                        }.frame(minHeight: 44)
                    }
                    .accessibilityLabel(theme.rawValue)
                    .accessibilityAddTraits(repository.appTheme == theme ? .isSelected : [])
                }
            } header: { Text("Themes") } footer: {
                Text("Themes change app backgrounds, surfaces, controls, and widget accents. Calendar and reminder list colors stay distinct. Light and Dark appearance follow your separate appearance setting.")
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle("App Themes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsPermissionsSection: View {
    @Bindable var repository: TaskRepository
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var microphoneStatus = AVAudioApplication.shared.recordPermission
    @State private var requesting = false

    var body: some View {
        Section {
            permissionRow("Reminders", icon: "checklist", status: eventStatus(.reminder), canRequest: EKEventStore.authorizationStatus(for: .reminder) == .notDetermined) {
                await repository.requestAccess()
            }
            permissionRow("Calendar", icon: "calendar", status: eventStatus(.event), canRequest: [.notDetermined, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event))) {
                await repository.requestEventCalendarAccess()
            }
            permissionRow("Notifications", icon: "bell.badge", status: notificationLabel, canRequest: notificationStatus == .notDetermined) {
                await repository.requestNotificationAccess()
            }
            permissionRow("Microphone", icon: "mic", status: microphoneLabel, canRequest: microphoneStatus == .undetermined) {
                _ = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
            }
            permissionRow("Speech Recognition", icon: "waveform", status: speechLabel, canRequest: speechStatus == .notDetermined) {
                _ = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
            Button("Open System Settings", systemImage: "arrow.up.forward.app") { openSystemSettings() }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Reminders and Calendar connect your tasks and events. Notifications provide due-date alerts. Microphone and Speech Recognition enable note dictation. Change previously granted or denied access in system Settings.")
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh(); await repository.reloadExternalData() } }
        }
    }

    private func permissionRow(_ title: String, icon: String, status: String, canRequest: Bool, request: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent { Text(status).foregroundStyle(.secondary) } label: { Label(title, systemImage: icon) }
            if canRequest {
                // Neutral wording (App Review 5.1.1(iv)): the system prompt is where the user decides.
                Button("Continue") {
                    requesting = true
                    Task {
                        await request()
                        await refresh()
                        requesting = false
                    }
                }
                .disabled(requesting)
                .accessibilityLabel("Continue to \(title) permission")
            } else if status == "Denied" || status == "Add-only Access" {
                Button("Manage in Settings") { openSystemSettings() }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func refresh() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        microphoneStatus = AVAudioApplication.shared.recordPermission
    }

    private func eventStatus(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined: "Not Requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized, .fullAccess: "Allowed"
        case .writeOnly: "Add-only Access"
        @unknown default: "Unknown"
        }
    }

    private var notificationLabel: String {
        switch notificationStatus {
        case .notDetermined: "Not Requested"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .provisional: "Quiet Delivery"
        case .ephemeral: "Temporary Access"
        @unknown default: "Unknown"
        }
    }

    private var microphoneLabel: String {
        switch microphoneStatus {
        case .undetermined: "Not Requested"
        case .denied: "Denied"
        case .granted: "Allowed"
        @unknown default: "Unknown"
        }
    }

    private var speechLabel: String {
        switch speechStatus {
        case .notDetermined: "Not Requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .authorized: "Allowed"
        @unknown default: "Unknown"
        }
    }
}


struct ShoppingDefaultStorePicker: View {
    let repository: TaskRepository
    let listID: String
    @Binding var selection: String
    @State private var adding = false
    @State private var name = ""
    private var choices: [String] {
        Array(Set(repository.shoppingStores(for: listID) + (selection.isEmpty ? [] : [selection]))).sorted()
    }
    var body: some View {
        Picker("Default Store", selection: $selection) {
            Text("None").tag("")
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
        Button("Add Store", systemImage: "plus") { name = ""; adding = true }
            .alert("Add Store", isPresented: $adding) {
                TextField("Store name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Add") { selection = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
    }
}

struct GuidedSetupView: View {
    @Bindable var repository: TaskRepository
    @State private var settingUp = false
    @State private var attempted = false
    var body: some View {
        Form {
            Section {
                Text("Connect your reminders and calendars, then choose layouts for your lists. You can change these choices later.")
                Button(settingUp ? "Setting up…" : "Set Up TaskFlow") {
                    settingUp = true
                    Task {
                        if repository.accessState != .granted { await repository.requestAccess() }
                        await repository.useMyCalendars()
                        settingUp = false
                        attempted = true
                    }
                }.disabled(settingUp)
                if attempted {
                    Label(repository.accessState == .granted ? "Reminders connected" : "Allow Reminders in Settings to connect your lists", systemImage: repository.accessState == .granted ? "checkmark.circle" : "exclamationmark.circle")
                    Label(repository.eventAccessState == .granted ? "Calendars connected" : "Calendar access is optional; enable it in Settings", systemImage: repository.eventAccessState == .granted ? "checkmark.circle" : "calendar")
                }
            }
            Section("Suggested List Layouts") {
                ForEach(repository.lists) { list in
                    if let suggestion = SpecializedListType.suggested(for: list.title), repository.listProfile(list.id).type == .standard {
                        Button {
                            var profile = repository.listProfile(list.id)
                            profile.type = suggestion
                            repository.setListProfile(profile, for: list.id)
                        } label: {
                            Label("Use \(suggestion.rawValue) for \(list.title)", systemImage: suggestion.icon)
                        }
                    }
                }
                Text("Suggestions change the layout and keep your existing items.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Shopping Defaults") {
                ForEach(repository.lists.filter { repository.listProfile($0.id).type == .shopping }) { list in
                    NavigationLink(list.title) { ReminderListSettings(repository: repository, list: list) }
                }
            }
        }.navigationTitle("Set Up TaskFlow")
    }
}
