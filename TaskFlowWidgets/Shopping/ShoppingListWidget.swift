import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct ShoppingWidgetListEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Shopping List")
    static var defaultQuery = ShoppingWidgetListQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "cart"))
    }
}

struct ShoppingWidgetListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShoppingWidgetListEntity] {
        let available = availableLists()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [ShoppingWidgetListEntity] { availableLists() }
    func entities(matching string: String) async throws -> [ShoppingWidgetListEntity] {
        availableLists().filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
    }
    func availableLists() -> [ShoppingWidgetListEntity] {
        guard hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder)) else { return [] }
        let types = TaskFlowSharedSettings.defaults.dictionary(forKey: "TaskFlow.specializedListTypes") as? [String: String] ?? [:]
        return EKEventStore().calendars(for: .reminder)
            .filter { $0.allowsContentModifications && types[$0.calendarIdentifier] == "Shopping & Groceries" }
            .map { ShoppingWidgetListEntity(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct ShoppingWidgetStoreOptions: DynamicOptionsProvider {
    static let allStores = "All Stores"
    @IntentParameterDependency<ShoppingListWidgetConfigurationIntent>(\.$list)
    var configuration

    func results() async throws -> [String] {
        let available = ShoppingWidgetListQuery().availableLists()
        let selected = (configuration?.list).flatMap { chosen in available.first { $0.id == chosen.id } }
            ?? (configuration?.list == nil ? available.first : nil)
        guard let selected else { return [Self.allStores] }
        let result = await ReminderWidgetStore().loadShoppingItems(listID: selected.id, includeCompleted: true)
        var names: [String: String] = [:]
        for task in result.tasks {
            let name = (task.specializedFields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            names[name.lowercased()] = names[name.lowercased()] ?? name
        }
        return [Self.allStores] + names.values.filter { $0 != Self.allStores }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct ShoppingListWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Shopping List"
    static var description = IntentDescription("Choose a Shopping & Groceries list created in TaskFlow. Leave blank to use the first shopping list.")
    @Parameter(title: "Shopping List") var list: ShoppingWidgetListEntity?
    @Parameter(title: "Store", description: "Choose a store from the selected shopping list, or show every store.", optionsProvider: ShoppingWidgetStoreOptions()) var store: String?
    @Parameter(title: "Maximum Items", default: .ten) var maximumItems: WidgetMaximumItems
    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$list)") {
            \.$store
            \.$maximumItems
        }
    }
}

struct ShoppingListWidgetEntry: TimelineEntry {
    let date: Date
    var listID: String?
    var title: String
    var tasks: [WidgetTask]
    var store: String
    var accessNeeded: Bool
    var listUnavailable: Bool
    var theme: TaskFlowSharedTheme
    var itemLimit: Int = 10
}

struct ShoppingListWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShoppingListWidgetEntry {
        let samples = [("Apples", "4", "", "Produce"), ("Oat milk", "2", "cartons", "Dairy"), ("Sourdough bread", "1", "loaf", "Bakery"), ("Eggs", "1", "dozen", "Dairy"), ("Spinach", "1", "bag", "Produce"), ("Pasta", "2", "packs", "Pantry")]
        let tasks = samples.enumerated().map { index, item in
            WidgetTask(id: "shopping-preview-\(index)", externalID: nil, title: item.0, listID: "shopping-preview", listTitle: "Groceries", dueDate: nil, priority: 0, isCompleted: false, status: "Not Started", isFlagged: false, parentID: nil, durationMinutes: nil, tags: [], blockedByTaskIDs: [], listColor: .green, specializedFields: ["Quantity": item.1, "Unit": item.2, "Category": item.3, "Store": "Market"], specializedListType: "Shopping & Groceries")
        }
        return ShoppingListWidgetEntry(date: Date(), listID: nil, title: "Groceries", tasks: tasks, store: "", accessNeeded: false, listUnavailable: false, theme: TaskFlowSharedSettings.theme)
    }
    func snapshot(for configuration: ShoppingListWidgetConfigurationIntent, in context: Context) async -> ShoppingListWidgetEntry {
        if context.isPreview {
            var preview = placeholder(in: context)
            preview.itemLimit = configuration.maximumItems.value
            return preview
        }
        return await entry(configuration)
    }
    func timeline(for configuration: ShoppingListWidgetConfigurationIntent, in context: Context) async -> Timeline<ShoppingListWidgetEntry> {
        Timeline(entries: [await entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func entry(_ configuration: ShoppingListWidgetConfigurationIntent) async -> ShoppingListWidgetEntry {
        let available = ShoppingWidgetListQuery().availableLists()
        let selected = configuration.list.flatMap { chosen in available.first { $0.id == chosen.id } } ?? (configuration.list == nil ? available.first : nil)
        let chosenStore = (configuration.store ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let storeFilter = chosenStore == ShoppingWidgetStoreOptions.allStores ? "" : chosenStore
        let hasAccess = hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder))
        guard let selected else {
            return ShoppingListWidgetEntry(date: Date(), listID: nil, title: "Shopping List", tasks: [], store: storeFilter, accessNeeded: !hasAccess, listUnavailable: configuration.list != nil, theme: TaskFlowSharedSettings.theme, itemLimit: configuration.maximumItems.value)
        }
        let result = await ReminderWidgetStore().loadShoppingItems(listID: selected.id)
        let tasks = result.tasks.filter { storeFilter.isEmpty || ($0.specializedFields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(storeFilter) == .orderedSame }
        return ShoppingListWidgetEntry(date: Date(), listID: selected.id, title: selected.title, tasks: tasks, store: storeFilter, accessNeeded: result.accessNeeded, listUnavailable: false, theme: TaskFlowSharedSettings.theme, itemLimit: configuration.maximumItems.value)
    }
}

struct TaskFlowShoppingListWidget: Widget {
    private var families: [WidgetFamily] {
        var result: [WidgetFamily] = [.systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { result.append(.systemExtraLargePortrait) }
        return result
    }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskFlowShoppingListWidget", intent: ShoppingListWidgetConfigurationIntent.self, provider: ShoppingListWidgetProvider()) { entry in
            ShoppingListWidgetView(entry: entry)
        }
        .configurationDisplayName("Shopping List")
        .description("Check off groceries, see quantities and stores, and open your shopping list.")
        .supportedFamilies(families)
    }
}

struct ShoppingListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: ShoppingListWidgetEntry
    private var rowLimit: Int {
        let configuredLimit = min(10, max(1, entry.itemLimit))
        if dynamicTypeSize.isAccessibilitySize { return min(configuredLimit, family == .systemLarge ? 3 : 6) }
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return configuredLimit }
        return min(configuredLimit, family == .systemExtraLarge ? 10 : 5)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cart.fill").foregroundStyle(entry.theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text(entry.store.isEmpty ? "Shopping & Groceries" : entry.store).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(entry.tasks.count)").font(.headline.monospacedDigit())
                    .padding(8).background(entry.theme.primary.opacity(0.12), in: Circle())
                    .accessibilityLabel("\(entry.tasks.count) items remaining")
            }
            if entry.accessNeeded {
                AccessNeededView(theme: entry.theme)
            } else if entry.listID == nil && !entry.tasks.isEmpty {
                rows
            } else if entry.listID == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.listUnavailable ? "Shopping list unavailable" : "Choose a shopping list").font(.headline)
                    Text(entry.listUnavailable ? "Edit this widget to select another shopping list." : "Set a list’s type to Shopping & Groceries in TaskFlow, then select it in Edit Widget.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else if entry.tasks.isEmpty {
                Label(entry.store.isEmpty ? "Shopping complete" : "No items for this store", systemImage: "checkmark.circle")
                    .font(.headline).foregroundStyle(entry.theme.primary)
                Spacer(minLength: 0)
            } else {
                rows
            }
            Spacer(minLength: 0)
            HStack {
                if entry.tasks.count > rowLimit {
                    Text("+\(entry.tasks.count - rowLimit) more").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Link(destination: entry.listID.map(TaskFlowDeepLink.listURL) ?? TaskFlowDeepLink.captureURL) {
                    Label(entry.listID == nil ? "Open TaskFlow" : "Open List", systemImage: "arrow.up.forward")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.listID.map(TaskFlowDeepLink.listURL) ?? TaskFlowDeepLink.captureURL)
    }
    @ViewBuilder
    private var rows: some View {
        let visible = Array(entry.tasks.prefix(rowLimit))
        if family == .systemExtraLarge {
            let split = (visible.count + 1) / 2
            HStack(alignment: .top, spacing: 16) {
                shoppingRows(Array(visible.prefix(split)))
                shoppingRows(Array(visible.dropFirst(split)))
            }
        } else {
            shoppingRows(visible)
        }
    }

    private func shoppingRows(_ tasks: [WidgetTask]) -> some View {
        VStack(spacing: 0) {
            ForEach(tasks) { task in
                HStack(spacing: 10) {
                    Button(intent: CompleteReminderIntent(reminderID: task.id, title: task.title)) {
                        Image(systemName: "circle").font(.title3).foregroundStyle(entry.theme.primary)
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bought \(task.title)")
                    Link(destination: TaskFlowDeepLink.taskURL(task.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            let details = [task.specializedFields["Category"], task.specializedFields["Store"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                            if !details.isEmpty { Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let quantity = [task.specializedFields["Quantity"], task.specializedFields["Unit"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                    if !quantity.isEmpty {
                        Text("×" + quantity).font(.caption.weight(.semibold))
                            .foregroundStyle((Double(task.specializedFields["Quantity"] ?? "") ?? 0) > 1 ? Color.accentColor : Color.secondary)
                            .lineLimit(1).frame(maxWidth: 75, alignment: .trailing)
                    }
                }
                .padding(.vertical, 5)
                if task.id != tasks.last?.id { Divider() }
            }
        }
    }
}
