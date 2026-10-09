import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

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
    @State private var showingReceiptScan = false
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
                                        itemRow(task, milestones: milestones, sections: sectionNames).padding(12).background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius)).draggable(task.id)
                                    }
                                }
                            }
                            Button("Add Task", systemImage: "plus") { editorDraft = repository.makeDraft() }
                        }.padding(12).frame(width: 300, height: 480)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius))
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
                else { workflowSummary(progress) } // The list's name is already the title; controls live in List Tools.
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
                if type == .packing, let trip = repository.listProfile(listID).settings["Trip"], !trip.isEmpty {
                    let dates = repository.listProfile(listID).settings["Travel Dates"] ?? ""
                    Label(dates.isEmpty ? trip : trip + " · " + dates, systemImage: "airplane").foregroundStyle(.secondary)
                }
                if type == .projects, !repository.projectNextActions.isEmpty {
                    Button { showingNextActions = true } label: {
                        LabeledContent { Text("\(repository.projectNextActions.count)") } label: { Label("Next Actions in All Projects", systemImage: "arrow.right.circle") }
                    }
                }
                if type == .bills {
                    ForEach(billTotals.keys.sorted(), id: \.self) { currency in
                        LabeledContent("Open total" + (currency == "Unspecified" ? " (no currency)" : ""), value: SpecializedFieldFormat.amount(billTotals[currency, default: 0], currency: currency == "Unspecified" ? nil : currency))
                    }
                    ForEach(monthlyBillTotals.keys.sorted(), id: \.self) { currency in
                        LabeledContent("Due this month" + (currency == "Unspecified" ? " (no currency)" : ""), value: SpecializedFieldFormat.amount(monthlyBillTotals[currency, default: 0], currency: currency == "Unspecified" ? nil : currency))
                    }
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
                        DisclosureGroup("Completed (\(completed.count))", isExpanded: $completedExpanded) {
                            ForEach(completed) { itemRow($0, milestones: milestones, sections: sectionNames) }
                        }
                    }
                    if type == .shopping {
                        Button("Clear Completed", systemImage: "trash", role: .destructive) { pendingClearIDs = filteredCompletedIDs }
                            .disabled(clearingCompleted || repository.isUndoing)
                    }
                }
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
        .sheet(isPresented: $showingReceiptScan) { ReceiptScanSheet(repository: repository, listID: listID) }
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
                // One menu for every list control, grouped View / Add / Manage.
                Menu {
                    Section("View") {
                        if type == .shopping { Button("Filters", systemImage: "line.3.horizontal.decrease") { showingFilters = true } }
                        if type == .packing { Toggle("Still to Pack Only", isOn: $remainingOnly) }
                        if type == .reading {
                            Picker("Sort Within Groups", selection: $watchSort) {
                                ForEach(["Recently Watched", "New Releases", "Title"], id: \.self) { Text($0).tag($0) }
                            }
                        } else { Toggle("Sort by Name", isOn: $sortByName) }
                        if repository.listProfile(listID).settings["Current Run"] != nil { Toggle("Show Previous Runs", isOn: $showPreviousRuns) }
                        if type == .projects { Button("Next Actions in All Projects", systemImage: "arrow.right.circle") { showingNextActions = true } }
                    }
                    Section("Add") {
                        Button("Templates", systemImage: "doc.on.doc") { showsTemplates = true }
                        if type == .shopping { Button("Buy Again", systemImage: "cart.badge.plus") { showingBuyAgain = true } }
                        if type == .projects { Button("Add Section", systemImage: "rectangle.split.3x1") { addingSection = true } }
                    }
                    Section("Manage") {
                        if !type.bulkFields.isEmpty {
                            Button(selectingItems ? "Done Selecting" : "Select Items", systemImage: "checkmark.circle") { selectingItems.toggle(); selectedIDs = [] }
                        }
                        if type == .shopping {
                            Button("Fill Prices from History", systemImage: "wand.and.stars") {
                                Task {
                                    let filled = await repository.fillMissingShoppingPrices(listID: listID)
                                    if filled == 0 { repository.errorMessage = "No remembered prices match these items yet. Scan a receipt or enter prices once and TaskFlow will remember them." }
                                }
                            }
                            .disabled(unpricedShoppingItems.isEmpty || repository.isUndoing)
                            Button("Scan Receipt", systemImage: "doc.viewfinder") { showingReceiptScan = true }
                            Button("Estimate Missing Prices", systemImage: "dollarsign.circle") { priceEntryIDs = unpricedShoppingItems.map(\.id); showingPriceEntry = true }
                                .disabled(unpricedShoppingItems.isEmpty || repository.isUndoing)
                            Button("Categories & Aisle Order", systemImage: "arrow.up.arrow.down") { showingShoppingCategories = true }
                            Button("Merge Duplicate Items", systemImage: "arrow.triangle.merge") { Task { await repository.mergeShoppingDuplicates(listID: listID) } }
                        }
                        Button("Customize List", systemImage: "slider.horizontal.3") { showingSettings = true }
                        Button("Clean Up Items", systemImage: "trash") { showingListCleanup = true }
                        if type == .shopping {
                            Button("Clear Completed", systemImage: "trash", role: .destructive) { pendingClearIDs = filteredCompletedIDs }
                                .disabled(clearingCompleted || repository.isUndoing || filteredCompletedIDs.isEmpty)
                        }
                    }
                } label: { Label("List Tools", systemImage: "ellipsis.circle") }
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
                    Button("Paste Items", systemImage: "text.badge.plus") { pendingFilterTool = "paste"; showingFilters = false }
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
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: task.isCompleted).font(type == .shopping ? .title : .title2).frame(minWidth: type == .shopping ? 56 : 44, minHeight: type == .shopping ? 56 : 44).contentShape(Rectangle())
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
                            Text(provider).font(.caption2).foregroundStyle(.tint).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6).padding(.vertical, 3).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius))
                        }
                    }
                    if type != .shopping, !shoppingMode, let date = task.dueDate { Text(date, format: .dateTime.month().day()).font(.caption).foregroundStyle(TaskFlowTheme.dueColor(isOverdue: task.isOverdue())) }
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
            if isWatchCard { RoundedRectangle(cornerRadius: TaskFlowTheme.panelRadius).fill(TaskFlowTheme.surface) }
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
                Button(task.location == nil ? "Add Location" : "Change Location", systemImage: "mappin.and.ellipse") { editingItem = task }
                if let id = repository.specializedDetails(task).fields["Shopping List ID"], repository.lists.contains(where: { $0.id == id }) { Button("Open Shopping List", systemImage: "cart") { repository.selectedScope = .list(id) } }
            }
            if type == .shopping { Button("Buy Again", systemImage: "cart.badge.plus") { repeatPurchase = task } }
            if type == .routines {
                Button("Start Timer", systemImage: "timer") { startTimer(for: task) }
            }
            let fields = repository.specializedDetails(task).fields
            if type == .appointments {
                Button("Create Follow-up Task", systemImage: "calendar.badge.plus") {
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
