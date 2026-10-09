import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

struct SpecializedListOptions: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    private var type: SpecializedListType { repository.listProfile(listID).type }
    var body: some View {
        NavigationStack {
            Form {
                if type == .shopping {
                    ShopperNameSection(repository: repository)
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
                            .font(.caption).foregroundStyle(TaskFlowTheme.dueColor(isOverdue: task.isOverdue()))
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
