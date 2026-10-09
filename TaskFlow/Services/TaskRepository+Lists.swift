import Foundation
import UserNotifications
import CloudKit
import EventKit
import Observation
import SwiftUI
import WidgetKit
import LinkPresentation
import UIKit

extension TaskRepository {
    func listProfile(_ id: String) -> SpecializedListProfile { listProfiles[id] ?? SpecializedListProfile() }
    func setListProfile(_ profile: SpecializedListProfile, for id: String) {
        guard listProfile(id) != profile else { return }
        listProfiles[id] = profile
        metadataStore.listProfiles = listProfiles
        publishReadingDestinations()
    }
    func specializedDetails(_ task: TaskItem) -> SpecializedTaskDetails {
        currentTask(id: task.id)?.sharedShoppingDetails ?? task.sharedShoppingDetails ?? specializedTasks[task.metadataID] ?? specializedTasks[task.id] ?? SpecializedTaskDetails()
    }
    func setSpecializedDetails(_ details: SpecializedTaskDetails, for task: TaskItem) {
        if specializedTasks[task.metadataID] != details {
            specializedTasks[task.metadataID] = details
            metadataStore.specializedTasks = specializedTasks
        }
        if let index = tasks.firstIndex(where: { $0.id == task.id }), tasks[index].sharedShoppingDetails != nil, tasks[index].sharedShoppingDetails != details {
            tasks[index].sharedShoppingDetails = details
        }
    }
    func setSpecializedStage(_ stage: String, for task: TaskItem, type: SpecializedListType) async {
        guard type.stages.contains(stage) else { return }
        var details = specializedDetails(task)
        details.fields[type == .reading ? "Progress" : "Stage"] = stage
        _ = await saveSpecializedDetails(details, for: task, type: type)
    }
    func saveSpecializedDetails(_ details: SpecializedTaskDetails, for task: TaskItem, type: SpecializedListType) async -> Bool {
        guard !isUndoing else { return false }
        let current = currentTask(id: task.id) ?? task
        let previous = specializedDetails(current)
        let stage = details.fields[type == .reading ? "Progress" : "Stage"] ?? ""
        let completionChanged = type.stages.contains(stage) && current.isCompleted != ["Paid", "Canceled", "Packed", "Finished"].contains(stage)
        guard previous != details || completionChanged else { return true }
        do {
            if type == .shopping {
                _ = try reminderService.saveTask(TaskDraft(task: current), metadataStore: metadataStore, shoppingDetails: details)
                // An older fetch must not replace this in-place quantity edit.
                taskFetchGeneration &+= 1
                taskRefresh = nil
            }
            if completionChanged {
                let completes = ["Paid", "Canceled", "Packed", "Finished"].contains(stage)
                if current.isCompleted != completes { try reminderService.setCompleted(completes, task: current, metadataStore: metadataStore) }
            }
            setSpecializedDetails(details, for: current)
            if type == .shopping { rememberShoppingEstimate(title: current.title, fields: details.fields) }
            if type == .shopping, let index = tasks.firstIndex(where: { $0.id == current.id }) { tasks[index].sharedShoppingDetails = details }
            offerUndo("Update List Details", previous: [current])
            taskUndo?.specializedPrevious = [current.id: previous]
            if completionChanged {
                await refreshTasks()
                await rescheduleNotifications()
            } else if type == .bills || type == .reading {
                await rescheduleNotifications() // Deadline dates feed reminders.
            }
            return true
        } catch { errorMessage = FriendlyError.message(for: error); return false }
    }
    func updateListTemplate(_ template: SpecializedListTemplate) {
        guard let index = listTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        var updated = template
        if listProfile(template.listID).type == .routines {
            for index in updated.items.indices { updated.items[index].details.fields["Step Order"] = String(index + 1) }
        }
        listTemplates[index] = updated
        metadataStore.listTemplates = listTemplates
    }
    func deleteListTemplate(_ id: UUID) {
        listTemplates.removeAll { $0.id == id }
        metadataStore.listTemplates = listTemplates
    }
    func setSpecializedField(_ key: String, value: String, for task: TaskItem) async {
        var details = specializedDetails(task)
        details.fields[key] = value
        _ = await saveSpecializedDetails(details, for: task, type: listProfile(task.listID).type)
    }
    func saveListTemplate(listID: String, title: String) {
        let items = tasks.filter { $0.listID == listID && $0.parentID == nil }.map {
            SpecializedListTemplate.Item(title: $0.title, notes: $0.notes, details: specializedDetails($0))
        }
        guard !items.isEmpty else { return }
        listTemplates.append(SpecializedListTemplate(title: title, listID: listID, items: items))
        metadataStore.listTemplates = listTemplates
    }
    func createTemplateRun(_ template: SpecializedListTemplate) async {
        guard lists.contains(where: { $0.id == template.listID }) else { return }
        let previousProfile = listProfile(template.listID)
        let run = Date().formatted(date: .abbreviated, time: .shortened)
        let runID = UUID().uuidString
        var createdAny = false
        var createdIDs: [String] = []
        for (itemIndex, item) in template.items.enumerated() {
            var draft = makeDraft()
            draft.listID = template.listID
            draft.title = item.title
            draft.notes = item.notes
            do {
                let shopping = listProfile(template.listID).type == .shopping
                var details = shopping ? recallingShoppingPrice(title: item.title, details: item.details) : item.details
                let id = try reminderService.saveTask(draft, metadataStore: metadataStore, shoppingDetails: shopping ? details : nil)
                if shopping { rememberShoppingEstimate(title: item.title, fields: details.fields) }
                if listProfile(template.listID).type == .routines { details.fields["Step Order"] = String(itemIndex + 1) }
                details.fields["Stage"] = nil
                details.fields["Progress"] = nil
                details.fields["Last Completed"] = nil
                details.fields["Run"] = run
                details.fields["Run ID"] = runID
                createdAny = true
                createdIDs.append(id)
                rememberStreamingServices(details.fields)
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
                metadataStore.specializedTasks = specializedTasks
            } catch { errorMessage = FriendlyError.message(for: error); break }
        }
        let type = listProfile(template.listID).type
        if createdAny && [.routines, .packing, .household].contains(type) {
            var profile = listProfile(template.listID)
            profile.settings["Current Run"] = runID
            setListProfile(profile, for: template.listID)
        }
        if !createdIDs.isEmpty {
            taskRedo = nil
            taskUndo = TaskUndo(message: "Start checklist", previous: [], wasDeleted: false, createdTaskIDs: createdIDs, listProfilesPrevious: [template.listID: previousProfile])
            feedbackSequence += 1
        }
        await refreshTasks()
        await rescheduleNotifications()
    }
    func shoppingPriceKey(title: String, fields: [String: String]) -> String {
        ShoppingQuantity.key(title: title, fields: fields) + "\u{001F}" + (Locale.current.currency?.identifier ?? "USD")
    }
    func seedShoppingPriceHistory(from items: [TaskItem]) {
        // Seed older items only when no explicit remembered price exists.
        // Newest records win; a reload must not overwrite a correction.
        for task in items.sorted(by: { ($0.modifiedAt ?? $0.createdAt ?? .distantPast) > ($1.modifiedAt ?? $1.createdAt ?? .distantPast) }) {
            guard listProfile(task.listID).type == .shopping || task.sharedShoppingDetails != nil else { continue }
            let fields = task.sharedShoppingDetails?.fields ?? specializedTasks[task.metadataID]?.fields ?? specializedTasks[task.id]?.fields ?? [:]
            if shoppingPriceHistory[shoppingPriceKey(title: task.title, fields: fields)] == nil { rememberShoppingEstimate(title: task.title, fields: fields) }
        }
    }
    /// The exact remembered price (same name, store, and unit), else the closest estimate.
    func rememberedShoppingPrice(title: String, fields: [String: String]) -> Double? {
        shoppingPriceHistory[shoppingPriceKey(title: title, fields: fields)] ?? shoppingPriceEstimate(title: title, fields: fields)?.price
    }
    /// Looser matches when there's no exact price: a similar name ("Egg" for "Eggs") at the same store,
    /// then the same item at another store. Units must match; the typical (median) price is used.
    func shoppingPriceEstimate(title: String, fields: [String: String]) -> (price: Double, source: String)? {
        let fold = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let currency = Locale.current.currency?.identifier ?? "USD"
        let unit = fold(fields["Unit"] ?? ""), store = fold(fields["Store"] ?? "")
        let wanted = ShoppingTitleNormalizer.normalize(title)
        guard !wanted.isEmpty else { return nil }
        var sameStore: [Double] = [], otherStores: [Double] = []
        for (key, price) in shoppingPriceHistory {
            let parts = key.components(separatedBy: "\u{001F}") // title, store, unit, currency
            guard parts.count == 4, parts[3] == currency, parts[2] == unit, price.isFinite, price >= 0,
                  ShoppingTitleNormalizer.normalize(parts[0]) == wanted else { continue }
            if parts[1] == store { sameStore.append(price) } else { otherStores.append(price) }
        }
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        if let price = median(sameStore) { return (price, "Similar item") }
        if let price = median(otherStores) { return (price, "Other stores") }
        return nil
    }
    /// Fills every open, unpriced item in a shopping list that has a remembered or estimated price.
    func fillMissingShoppingPrices(listID: String) async -> Int {
        let candidates = tasks.filter { $0.listID == listID && !$0.isCompleted && $0.parentID == nil }
        var filled = 0
        for task in candidates {
            var details = specializedDetails(task)
            guard Double(details.fields["Price"] ?? "") == nil, let price = rememberedShoppingPrice(title: task.title, fields: details.fields) else { continue }
            details.fields["Price"] = ShoppingQuantity.text(price)
            if await saveSpecializedDetails(details, for: task, type: .shopping) { filled += 1 }
        }
        return filled
    }
    /// Saves per-unit prices read from a receipt and remembers them for next time.
    func applyReceiptPrices(_ prices: [String: Double]) async -> Int {
        var saved = 0
        for (taskID, price) in prices {
            guard price.isFinite, price >= 0, let task = currentTask(id: taskID) else { continue }
            var details = specializedDetails(task)
            details.fields["Price"] = ShoppingQuantity.text(price)
            if await saveSpecializedDetails(details, for: task, type: .shopping) {
                rememberShoppingEstimate(title: task.title, fields: details.fields)
                saved += 1
            }
        }
        return saved
    }
    func rememberShoppingEstimate(title: String, fields: [String: String]) {
        guard let price = Double(fields["Price"] ?? ""), price.isFinite, price >= 0 else { return }
        let key = shoppingPriceKey(title: title, fields: fields)
        if shoppingPriceHistory[key] != price { shoppingPriceHistory[key] = price }
    }
    func recallingShoppingPrice(title: String, details: SpecializedTaskDetails) -> SpecializedTaskDetails {
        var result = details
        if (result.fields["Price"] ?? "").isEmpty, let price = rememberedShoppingPrice(title: title, fields: result.fields) {
            result.fields["Price"] = ShoppingQuantity.text(price)
        }
        return result
    }
    func pricedShoppingSuggestion(_ item: SpecializedListTemplate.Item, store: String) -> SpecializedListTemplate.Item {
        var result = item
        if !store.isEmpty { result.details.fields["Store"] = store }
        if let price = rememberedShoppingPrice(title: result.title, fields: result.details.fields) {
            result.details.fields["Price"] = ShoppingQuantity.text(price)
        }
        return result
    }
    func saveShoppingEstimate(_ price: Double, for task: TaskItem) async -> Bool {
        guard price.isFinite, price >= 0, let current = currentTask(id: task.id) else { return false }
        var details = specializedDetails(current)
        details.fields["Price"] = ShoppingQuantity.text(price)
        guard await saveSpecializedDetails(details, for: current, type: .shopping) else { return false }
        rememberShoppingEstimate(title: current.title, fields: details.fields)
        return true
    }
    var shoppingShopperChoices: [String] {
        var names: [String] = []
        let incoming = tasks.flatMap { task in
            let fields = specializedDetails(task).fields
            return [fields["Shopper"], fields["Added By"], fields["Purchased By"]].compactMap { $0 }.filter { $0 != "Unnamed shopper" }
        }
        for raw in [shoppingShopperName] + rememberedShoppingShopperNames + incoming {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !names.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    @discardableResult
    func rememberShoppingShopper(_ raw: String) -> String {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return "" }
        let canonical = shoppingShopperChoices.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
        if !rememberedShoppingShopperNames.contains(where: { $0.localizedCaseInsensitiveCompare(canonical) == .orderedSame }) {
            rememberedShoppingShopperNames.append(canonical)
        }
        return canonical
    }
    func selectShoppingShopper(_ raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        shoppingShopperName = shoppingShopperChoices.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
    }
    var shoppingActor: String {
        let name = shoppingShopperName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unnamed shopper" : String(name.prefix(80))
    }
    func shoppingQuantityIsUpdating(_ id: String) -> Bool { shoppingQuantityUpdates.contains(id) }
    func adjustShoppingQuantity(_ task: TaskItem, by change: Double) async {
        guard !shoppingQuantityUpdates.contains(task.id), !isUndoing,
              let current = currentTask(id: task.id), !current.isCompleted,
              let value = ShoppingQuantity.value(specializedDetails(current).fields["Quantity"]) else { return }
        let next = value + change
        guard next.isFinite, next > 0 else { return }
        shoppingQuantityUpdates.insert(task.id)
        defer { shoppingQuantityUpdates.remove(task.id) }
        var details = specializedDetails(current)
        details.fields["Quantity"] = ShoppingQuantity.text(next)
        if await saveSpecializedDetails(details, for: current, type: .shopping) { selectionFeedbackSequence &+= 1 }
    }
    func shoppingDuplicate(_ item: SpecializedListTemplate.Item, listID: String, store: String) -> TaskItem? {
        var fields = item.details.fields
        if !store.isEmpty { fields["Store"] = store }
        let key = ShoppingQuantity.key(title: item.title, fields: fields)
        return tasks.first { $0.listID == listID && $0.parentID == nil && !$0.isCompleted && ShoppingQuantity.key(title: $0.title, fields: specializedDetails($0).fields) == key }
    }
    func shoppingHasDuplicates(_ entries: [SpecializedListTemplate.Item], listID: String, store: String) -> Bool {
        var keys: Set<String> = []
        return entries.contains { item in
            var fields = item.details.fields
            if !store.isEmpty { fields["Store"] = store }
            return !keys.insert(ShoppingQuantity.key(title: item.title, fields: fields)).inserted || shoppingDuplicate(item, listID: listID, store: store) != nil
        }
    }
    func shoppingRepeatSuggestions(listID: String) -> [SpecializedListTemplate.Item] {
        let purchased = tasks.filter { $0.listID == listID && $0.parentID == nil && $0.isCompleted }
        let grouped = Dictionary(grouping: purchased) { ShoppingQuantity.key(title: $0.title, fields: specializedDetails($0).fields) }
        return grouped.values.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return (left.compactMap(\.completedAt).max() ?? .distantPast) > (right.compactMap(\.completedAt).max() ?? .distantPast)
        }.prefix(12).compactMap { purchases in
            // Prefer the most common quantity/unit/store combination, breaking ties by recency.
            let variants = Dictionary(grouping: purchases) { specializedDetails($0).fields["Quantity"] ?? "" }
            guard let usual = variants.values.sorted(by: {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.compactMap(\.completedAt).max() ?? .distantPast) > ($1.compactMap(\.completedAt).max() ?? .distantPast)
            }).first?.max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) else { return nil }
            var details = specializedDetails(usual)
            for key in ["Added By", "Added At", "Purchased By", "Purchased At", "Last Completed", "Run", "Run ID"] { details.fields[key] = nil }
            return .init(title: usual.title, notes: usual.notes, details: details)
        }
    }
    func buyAgain(_ task: TaskItem) async {
        let template = SpecializedListTemplate(title: task.title, listID: task.listID, items: [.init(title: task.title, notes: task.notes, details: specializedDetails(task))])
        await createTemplateRun(template)
    }
    func mergeShoppingDuplicates(listID: String) async {
        guard !isUndoing else { return }
        let open = tasks.filter { $0.listID == listID && !$0.isCompleted && $0.parentID == nil }
        let groups = Dictionary(grouping: open) { task in
            let fields = specializedDetails(task).fields
            return [task.title, fields["Store"] ?? "", fields["Unit"] ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "\u{001F}")
        }
        var previous: [TaskItem] = []
        var snapshots: [String: SpecializedTaskDetails] = [:]
        for group in groups.values where group.count > 1 {
            guard let first = group.first else { continue }
            let quantities = group.map { task -> Double? in
                let raw = specializedDetails(task).fields["Quantity"] ?? ""
                return raw.isEmpty ? 1 : Double(raw)
            }
            guard quantities.allSatisfy({ value in guard let value else { return false }; return value.isFinite && value > 0 }) else { continue }
            var total = quantities[0] ?? 1
            var merged: [TaskItem] = []
            for (index, duplicate) in group.dropFirst().enumerated() {
                let nextTotal = total + (quantities[index + 1] ?? 1)
                guard nextTotal.isFinite else { continue }
                do {
                    try reminderService.setCompleted(true, task: duplicate, metadataStore: metadataStore)
                    total = nextTotal
                    merged.append(duplicate)
                } catch { errorMessage = FriendlyError.message(for: error) }
            }
            guard !merged.isEmpty, total.isFinite else { continue }
            snapshots[first.metadataID] = specializedDetails(first)
            var details = specializedDetails(first)
            details.fields["Quantity"] = String(total)
            setSpecializedDetails(details, for: first)
            previous.append(contentsOf: [first] + merged)
        }
        offerUndo("Merge Shopping Items", previous: previous)
        taskUndo?.specializedPrevious = snapshots
        await refreshTasks()
        await rescheduleNotifications()
    }
    func scheduleNextChore(_ task: TaskItem) async -> String? {
        guard task.recurrence == nil, let days = specializedDetails(task).repeatAfterDays, (1...3650).contains(days) else { return nil }
        var draft = TaskDraft(task: task)
        draft.reminderID = nil
        draft.title = task.title
        draft.isCompleted = false
        draft.status = .notStarted
        draft.recurrence = nil
        draft.dueDate = Calendar.current.date(byAdding: .day, value: days, to: Date())
        do {
            let id = try reminderService.saveTask(draft, metadataStore: metadataStore)
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = specializedDetails(task)
            metadataStore.specializedTasks = specializedTasks
            return id
        } catch { errorMessage = FriendlyError.message(for: error); return nil }
    }
    var todaySectionOrder: [TodayDashboardSection] {
        _ = todaySectionRevision
        return TodayDashboardSection.normalized(preferences.stringArray(forKey: "TaskFlow.todaySectionOrder") ?? [])
    }
    var visibleTodaySections: [TodayDashboardSection] {
        _ = todaySectionRevision
        let hidden = Set(preferences.stringArray(forKey: "TaskFlow.todayHiddenSections") ?? [TodayDashboardSection.timeline.rawValue])
        return todaySectionOrder.filter { !hidden.contains($0.rawValue) }
    }
    func setTodaySectionVisible(_ section: TodayDashboardSection, _ visible: Bool) {
        var hidden = Set(preferences.stringArray(forKey: "TaskFlow.todayHiddenSections") ?? [TodayDashboardSection.timeline.rawValue])
        if visible { hidden.remove(section.rawValue) } else { hidden.insert(section.rawValue) }
        preferences.set(hidden.sorted(), forKey: "TaskFlow.todayHiddenSections")
        todaySectionRevision &+= 1
        scheduleCloudSync()
    }
    func moveTodaySections(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        selectionFeedbackSequence &+= 1
        var order = todaySectionOrder
        order.move(fromOffsets: offsets, toOffset: destination)
        preferences.set(order.map(\.rawValue), forKey: "TaskFlow.todaySectionOrder")
        todaySectionRevision &+= 1
        scheduleCloudSync()
    }
    func resetTodaySections() {
        preferences.removeObject(forKey: "TaskFlow.todaySectionOrder")
        preferences.removeObject(forKey: "TaskFlow.todayHiddenSections")
        todaySectionRevision &+= 1
        scheduleCloudSync()
    }
    @discardableResult
    func shoppingTask(_ task: TaskItem, matchesStore store: String?) -> Bool {
        guard let store else { return true }
        let actual = (specializedDetails(task).fields["Store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return actual.compare(store.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    func shoppingCustomCategories(listID: String) -> [String] {
        guard let data = listProfile(listID).settings["Shopping Categories"]?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    func shoppingCategories(listID: String) -> [String] {
        let assigned = tasks.filter { $0.listID == listID }.compactMap { specializedDetails($0).fields["Category"] }
        var result: [String] = []
        for raw in ShoppingCatalog.categories + shoppingCustomCategories(listID: listID) + assigned {
            let name = ShoppingCatalog.canonicalCategory(raw)
            if !name.isEmpty, !result.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) { result.append(name) }
        }
        return result
    }
    @discardableResult
    func addShoppingCategory(_ raw: String, listID: String) -> String {
        let name = ShoppingCatalog.canonicalCategory(String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
        guard !name.isEmpty else { return "" }
        if let existing = shoppingCategories(listID: listID).first(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return existing }
        var profile = listProfile(listID)
        var categories = shoppingCustomCategories(listID: listID)
        categories.append(name)
        profile.settings["Shopping Categories"] = String(data: (try? JSONEncoder().encode(categories)) ?? Data(), encoding: .utf8)
        setListProfile(profile, for: listID)
        return name
    }
    func removeShoppingCategory(_ name: String, listID: String) {
        var profile = listProfile(listID)
        let categories = shoppingCustomCategories(listID: listID).filter { $0.localizedCaseInsensitiveCompare(name) != .orderedSame }
        profile.settings["Shopping Categories"] = String(data: (try? JSONEncoder().encode(categories)) ?? Data(), encoding: .utf8)
        setListProfile(profile, for: listID)
    }
    func shoppingStoreOrderKey(_ store: String?) -> String {
        guard let store else { return "*" }
        return "store:" + store.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func shoppingCategoryOrders(listID: String) -> [String: [String]] {
        guard let data = listProfile(listID).settings["Shopping Category Orders"]?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
    func shoppingCategoryOrder(listID: String, store: String?) -> [String] {
        let orders = shoppingCategoryOrders(listID: listID)
        let legacy = (listProfile(listID).settings["Aisle Order"] ?? "").split(separator: ",").map(String.init)
        let saved = orders[shoppingStoreOrderKey(store)] ?? orders["*"] ?? legacy
        let available = shoppingCategories(listID: listID)
        var result: [String] = []
        for raw in saved + available {
            let name = ShoppingCatalog.canonicalCategory(raw)
            if available.contains(name), !result.contains(name) { result.append(name) }
        }
        return result
    }
    func setShoppingCategoryOrder(_ categories: [String]?, listID: String, store: String?) {
        var profile = listProfile(listID)
        var orders = shoppingCategoryOrders(listID: listID)
        orders[shoppingStoreOrderKey(store)] = categories
        if store == nil, categories == nil { profile.settings["Aisle Order"] = nil }
        profile.settings["Shopping Category Orders"] = String(data: (try? JSONEncoder().encode(orders)) ?? Data(), encoding: .utf8)
        setListProfile(profile, for: listID)
    }
    func shoppingStores(for listID: String) -> [String] {
        let saved = listProfile(listID).settings["Shopping Stores"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let existing = tasks.filter { $0.listID == listID }.compactMap { specializedDetails($0).fields["Store"] }
        var unique: [String: String] = [:]
        for value in saved + existing + [listProfile(listID).settings["Default Store"] ?? ""] {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if unique[key] == nil { unique[key] = name }
        }
        return unique.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    /// A selected store filter takes precedence for capture; item editors can override the result.
    func shoppingCaptureStore(for listID: String) -> String {
        let settings = listProfile(listID).settings
        for key in ["Store Filter", "Default Store", "Last Store"] {
            let value = (settings[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }
    func rememberShoppingStore(_ store: String, for listID: String) {
        let name = store.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var values = shoppingStores(for: listID)
        if !values.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { values.append(name) }
        guard let data = try? JSONEncoder().encode(values), let encoded = String(data: data, encoding: .utf8) else { return }
        var profile = listProfile(listID)
        profile.settings["Shopping Stores"] = encoded
        setListProfile(profile, for: listID)
    }
    func mediaDuplicates(title: String, fields: [String: String], listID: String, excluding id: String? = nil) -> [TaskItem] {
        tasks.filter { $0.id != id && $0.listID == listID && $0.parentID == nil && specializedDetails($0).fields["Merged Into"] == nil && ReadingMedia.sameTitle(title, fields: fields, $0.title, fields: specializedDetails($0).fields) }
    }
    func mediaTags(_ tags: [String], previous: [String: String], fields: [String: String]) -> [String] {
        let old = ReadingMedia.tagValues(previous["Auto Tags"] ?? "")
        let suggested = ReadingMedia.suggestedTags(fields, includeGenres: false)
        var result = tags.filter { !old.contains($0.lowercased()) || suggested.contains($0.lowercased()) }
        for tag in suggested where !old.contains(tag) && !result.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) { result.append(tag) }
        return result
    }
    func addReadingLink(title: String, url: URL, listID: String, metadata: ReadingLinkMetadata? = nil, note: String = "", captureID: UUID? = nil, mergeIntoID: String? = nil, watchHint: Bool = false, previewFilename: String? = nil, streamingService: String = "") async -> Bool {
        guard !isUndoing, ReadingMedia.isWebURL(url) else { return false }
        if let mergeIntoID, !tasks.contains(where: { $0.id == mergeIntoID && $0.listID == listID }) { return false }
        let existing = mergeIntoID.flatMap { currentTask(id: $0) } ?? tasks.first {
            ReadingMedia.identifiesItem(url) && $0.listID == listID && specializedDetails($0).fields["Merged Into"] == nil && (ReadingMedia.watchLinks(specializedDetails($0).fields).contains { ReadingMedia.canonicalURL($0.url) == ReadingMedia.canonicalURL(url.absoluteString) } || ReadingMedia.canonicalURL(specializedDetails($0).fields["Resolved Link"] ?? "") == ReadingMedia.canonicalURL(url.absoluteString))
        }
        var incoming = metadata?.fields ?? [:]
        if let previewFilename { incoming["Local Preview"] = previewFilename }
        incoming["Source Link"] = url.absoluteString
        incoming["Progress"] = "Saved"
        if !streamingService.isEmpty { incoming["Streaming Service"] = streamingService }
        if let service = ReadingMedia.provider(for: url) { incoming["Saved From"] = service }
        if incoming["Format"] == nil { incoming["Format"] = ReadingMedia.format(for: url) }
        if watchHint, incoming["Format"] == "Article" { incoming["Format"] = "Video" }
        var details = existing.map(specializedDetails) ?? SpecializedTaskDetails()
        let previous = details
        if existing == nil { details.fields = incoming }
        else {
            details.fields = ReadingMedia.enrich(details.fields, with: incoming.filter { !["Source Link", "Progress", "Saved From"].contains($0.key) })
            details.fields["Watch Links"] = ReadingMedia.encodeLinks(ReadingMedia.watchLinks(details.fields) + ReadingMedia.watchLinks(incoming))
        }
        if let captureID { details.fields["Share Capture IDs"] = Array(Set(ReadingMedia.captureIDs(details.fields) + [captureID.uuidString])).sorted().joined(separator: ",") }
        var draft = existing.map(TaskDraft.init(task:)) ?? TaskDraft(listID: listID)
        if existing == nil {
            let proposed = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? metadata?.title ?? "" : title
            draft.title = ReadingMedia.cleanTitle(proposed, url: url)
            if draft.title.isEmpty { draft.title = url.host ?? url.absoluteString }
            draft.notes = note
            if metadata == nil {
                details.fields["Preview Status"] = "Pending"
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { details.fields["Captured Title"] = draft.title }
                details.fields["Captured Format"] = details.fields["Format"]
            }
        } else if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !draft.notes.contains(note) {
            draft.notes += (draft.notes.isEmpty ? "" : "\n\n") + note
        }
        draft.tags = mediaTags(draft.tags, previous: previous.fields, fields: details.fields)
        details.fields["Auto Tags"] = ReadingMedia.suggestedTags(details.fields, includeGenres: false).joined(separator: ",")
        do {
            let id = try reminderService.saveTask(draft, metadataStore: metadataStore)
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
            metadataStore.specializedTasks = specializedTasks
            taskRedo = nil
            if let existing {
                offerUndo("Add media link", previous: [existing])
                taskUndo?.specializedPrevious = [existing.id: previous]
            } else { taskUndo = TaskUndo(message: "Save reading link", previous: [], wasDeleted: false, createdTaskIDs: [id]) }
            feedbackSequence += 1
            await refreshTasks()
            await consumeWatchedEpisodeActions()
            resumeReadingPreviews()
            return true
        } catch { errorMessage = FriendlyError.message(for: error); return false }
    }
    /// Preserve both originals for Undo; the incoming entry is archived and hidden after consolidation.
    func mergeMediaItem(_ source: TaskItem, into target: TaskItem) async -> Bool {
        guard !isUndoing, source.id != target.id, source.listID == target.listID, source.parentID == nil, target.parentID == nil else { return false }
        let incoming = specializedDetails(source), previous = specializedDetails(target)
        var merged = previous
        merged.fields = ReadingMedia.enrich(merged.fields, with: incoming.fields.filter { !["Source Link", "Progress", "Preview Status", "Captured Title", "Captured Format", "Merged Into", "Saved From"].contains($0.key) })
        merged.fields["Watch Links"] = ReadingMedia.encodeLinks(ReadingMedia.watchLinks(previous.fields) + ReadingMedia.watchLinks(incoming.fields))
        merged.fields["Share Capture IDs"] = Array(Set(ReadingMedia.captureIDs(previous.fields) + ReadingMedia.captureIDs(incoming.fields))).sorted().joined(separator: ",")
        var draft = TaskDraft(task: target)
        draft.tags = Array(Set(target.tags + source.tags)).sorted()
        if !source.notes.isEmpty, !draft.notes.contains(source.notes) { draft.notes += (draft.notes.isEmpty ? "" : "\n\n") + source.notes }
        do {
            var archivedDraft = TaskDraft(task: source)
            archivedDraft.isCompleted = true
            archivedDraft.status = .done
            try reminderService.saveTasks([draft, archivedDraft], metadataStore: metadataStore)
            var archived = incoming
            archived.fields["Merged Into"] = target.id
            archived.fields["Progress"] = "Finished"
            setSpecializedDetails(merged, for: target)
            setSpecializedDetails(archived, for: source)
            offerUndo("Combine media links", previous: [target, source])
            taskUndo?.specializedPrevious = [target.id: previous, source.id: incoming]
            await refreshTasks()
            openTask(id: target.id)
            return true
        } catch { errorMessage = FriendlyError.message(for: error); return false }
    }
    func saveMediaItem(_ details: SpecializedTaskDetails, title: String, note: String, tags: [String], for task: TaskItem) async -> Bool {
        guard !isUndoing, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let current = currentTask(id: task.id) ?? task, previous = specializedDetails(task)
        var draft = TaskDraft(task: current)
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.notes = note
        draft.tags = tags
        let stage = details.fields["Progress"] ?? ""
        if SpecializedListType.reading.stages.contains(stage), current.isCompleted != (stage == "Finished") {
            draft.isCompleted = stage == "Finished"
            draft.status = stage == "Finished" ? .done : .active
        }
        do {
            _ = try reminderService.saveTask(draft, metadataStore: metadataStore)
            rememberStreamingServices(details.fields)
            var saved = details
            if saved.fields["Thumbnail URL"] != previous.fields["Thumbnail URL"] { saved.fields.removeValue(forKey: "Local Preview") }
            if !(saved.fields["Thumbnail URL"] ?? "").isEmpty { saved.fields.removeValue(forKey: "Suppress Preview") }
            if saved.fields["Source Link"] != previous.fields["Source Link"] {
                saved.fields.removeValue(forKey: "Resolved Link")
                if let raw = saved.fields["Source Link"], let url = URL(string: raw), ReadingMedia.isWebURL(url) { saved.fields["Preview Status"] = "Pending" }
                else { saved.fields.removeValue(forKey: "Preview Status") }
            }
            // An explicit edit owns the title/type, even while a preview is running.
            saved.fields.removeValue(forKey: "Captured Title")
            saved.fields.removeValue(forKey: "Captured Format")
            setSpecializedDetails(saved, for: current)
            offerUndo("Edit media item", previous: [current])
            taskUndo?.specializedPrevious = [current.id: previous]
            await refreshTasks()
            resumeReadingPreviews()
            return true
        } catch { errorMessage = FriendlyError.message(for: error); return false }
    }
    /// Import a reviewed shopping batch with one reload and one undo action.
    /// Open tasks marked Next Action in every Projects list, soonest due first.
    var projectNextActions: [TaskItem] {
        tasks.filter { !$0.isCompleted && listProfile($0.listID).type == .projects && specializedDetails($0).fields["Next Action"] == "Yes" }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
    }
    var preferredReadingListID: String? { preferredMediaListID(watch: false) }
    func preferredMediaListID(watch: Bool) -> String? {
        let reading = lists.filter { listProfile($0.id).type == .reading }
        let configured = ReadingMedia.defaults.string(forKey: ReadingMedia.preferenceKey(watch: watch))
        if let configured, reading.contains(where: { $0.id == configured }) { return configured }
        return reading.first { $0.id == defaultListID }?.id ?? reading.first?.id
    }
    func publishReadingDestinations() {
        let reading = lists.filter { listProfile($0.id).type == .reading }
        let ordered = reading.filter { $0.id == defaultListID } + reading.filter { $0.id != defaultListID }
        let destinations = ordered.map { ["id": $0.id, "title": $0.title] }
        ReadingMedia.defaults.set(destinations, forKey: ReadingMedia.destinationsKey)
    }
    func addSharedReadingLink(_ url: URL) async -> Bool {
        guard let listID = preferredMediaListID(watch: ReadingMedia.action(for: ReadingMedia.format(for: url)) == "Watch") else { return false }
        return await addReadingLink(title: "", url: url, listID: listID)
    }
    func importMediaCapture(_ capture: ReadingMedia.Capture) async -> Bool {
        if specializedTasks.values.contains(where: { ReadingMedia.captureIDs($0.fields).contains(capture.id.uuidString) }) { return true }
        guard let url = URL(string: capture.url), ReadingMedia.isWebURL(url) else { return false }
        let destination = lists.first { $0.id == capture.listID && listProfile($0.id).type == .reading }?.id
            ?? preferredMediaListID(watch: capture.watch)
        guard let destination else { return false }
        return await addReadingLink(title: capture.title, url: url, listID: destination, note: capture.note, captureID: capture.id, watchHint: capture.watch, previewFilename: capture.previewFilename)
    }
    /// Pending markers survive relaunch. Only unchanged capture values or empty fields are enriched.
    func resumeReadingPreviews() {
        for task in tasks where listProfile(task.listID).type == .reading && specializedDetails(task).fields["Merged Into"] == nil {
            guard readingPreviewJobs.count < 4 else { break }
            let initial = specializedDetails(task)
            guard initial.fields["Preview Status"] == "Pending", !readingPreviewJobs.contains(task.id),
                  let raw = initial.fields["Source Link"], let url = URL(string: raw) else { continue }
            readingPreviewJobs.insert(task.id)
            Task {
                defer { readingPreviewJobs.remove(task.id); resumeReadingPreviews() }
                let metadata = await ReadingLinkMetadata.fetch(url)
                guard let current = currentTask(id: task.id) else { return }
                var latest = specializedDetails(current)
                guard latest.fields["Source Link"] == raw, latest.fields["Preview Status"] == "Pending" else { return }
                if let metadata {
                    latest.fields = ReadingMedia.enrich(latest.fields, with: metadata.fields)
                    var draft = TaskDraft(task: current)
                    if current.title == latest.fields["Captured Title"], !metadata.title.isEmpty { draft.title = String(metadata.title.prefix(200)) }
                    draft.tags = mediaTags(current.tags, previous: initial.fields, fields: latest.fields)
                    latest.fields["Auto Tags"] = ReadingMedia.suggestedTags(latest.fields, includeGenres: false).joined(separator: ",")
                    if draft.title != current.title || draft.tags != current.tags {
                        do { _ = try reminderService.saveTask(draft, metadataStore: metadataStore) }
                        catch { errorMessage = FriendlyError.message(for: error) }
                    }
                    latest.fields["Preview Status"] = "Ready"
                } else { latest.fields["Preview Status"] = "Unavailable" }
                latest.fields.removeValue(forKey: "Captured Title")
                latest.fields.removeValue(forKey: "Captured Format")
                specializedTasks[current.metadataID] = latest
                metadataStore.specializedTasks = specializedTasks
                await refreshTasks()
            }
        }
    }
    func matchWatchShow(_ showID: Int, taskID: String, automatic: Bool = false) async -> Bool {
        guard refreshingShows.insert(taskID).inserted else { return false }
        defer { refreshingShows.remove(taskID) }
        do {
            var catalog = try await ReadingMedia.fetchTracking(id: showID)
            try Task.checkCancellation()
            guard let task = currentTask(id: taskID), !isUndoing else { return false }
            var details = specializedDetails(task)
            if automatic, ReadingMedia.tracking(details.fields)?.show.id != showID { return false }
            if let old = ReadingMedia.tracking(details.fields), old.show.id == showID { catalog.watched = old.watched }
            details.fields["Show Tracking"] = ReadingMedia.encodeTracking(catalog)
            details.fields["Format"] = "TV Show"
            details.fields["Genres"] = (catalog.show.genres ?? []).joined(separator: ", ")
            details.fields["Year"] = catalog.show.premiered.map { String($0.prefix(4)) }
            details.fields["Runtime Minutes"] = catalog.show.averageRuntime.map(String.init)
            if details.fields["Artwork Override"] != "true", details.fields["Suppress Preview"] != "true", (!automatic || (details.fields["Thumbnail URL"] ?? "").isEmpty), let image = catalog.show.thumbnail { details.fields["Thumbnail URL"] = image.absoluteString }
            details.fields["Artwork Credit"] = catalog.show.url.absoluteString
            if details.fields["Progress"] != "Dropped" { details.fields["Progress"] = catalog.progress() }
            if automatic {
                // Catalog refresh must not replace the user's Undo or reopen a manually finished item.
                if task.isCompleted { details.fields["Progress"] = "Finished" }
                else if details.fields["Progress"] == "Finished" { details.fields["Progress"] = "Caught Up" }
                setSpecializedDetails(details, for: task)
                scheduleCloudSync()
                await rescheduleNotifications()
                return true
            }
            let result = await saveSpecializedDetails(details, for: task, type: .reading)
            await rescheduleNotifications()
            return result
        } catch { if !automatic { errorMessage = "Show information could not be refreshed. Your saved progress is unchanged. Please try again." }; return false }
    }
    @discardableResult
    func setWatchedEpisodes(_ ids: Set<Int>, watched: Bool, taskID: String) async -> Bool {
        guard let task = currentTask(id: taskID), !isUndoing else { return false }
        var details = specializedDetails(task)
        guard var catalog = ReadingMedia.tracking(details.fields) else { return false }
        let eligible = Set(catalog.episodes.filter { $0.release.map { $0 <= Date() } == true }.map(\.id))
        if watched, !ids.intersection(eligible).subtracting(catalog.watched).isEmpty { details.fields["Last Watched At"] = ISO8601DateFormatter().string(from: Date()) }
        if watched { catalog.watched.formUnion(ids.intersection(eligible)) } else { catalog.watched.subtract(ids) }
        details.fields["Show Tracking"] = ReadingMedia.encodeTracking(catalog)
        details.fields["Progress"] = catalog.progress() == "Finished" ? "Caught Up" : catalog.progress()
        if let next = catalog.next() { details.fields["Season"] = String(next.season); details.fields["Episode"] = next.number.map(String.init) }
        else { details.fields.removeValue(forKey: "Season"); details.fields.removeValue(forKey: "Episode") }
        return await saveSpecializedDetails(details, for: task, type: .reading)
    }
    @discardableResult
    func setEpisodePosition(_ episodeID: Int, catchUp: Bool, taskID: String) async -> Bool {
        guard let task = currentTask(id: taskID), !isUndoing else { return false }
        var details = specializedDetails(task)
        guard var catalog = ReadingMedia.tracking(details.fields), let index = catalog.ordered.firstIndex(where: { $0.id == episodeID }) else { return false }
        let count = index + (catchUp ? 1 : 0)
        let ids = Set(catalog.ordered.prefix(count).filter { $0.release.map { $0 <= Date() } == true }.map(\.id))
        if catchUp { catalog.watched.formUnion(ids) } else { catalog.watched = ids }
        details.fields["Show Tracking"] = ReadingMedia.encodeTracking(catalog)
        details.fields["Progress"] = catalog.progress() == "Finished" ? "Caught Up" : catalog.progress()
        if let next = catalog.next() { details.fields["Season"] = String(next.season); details.fields["Episode"] = next.number.map(String.init) }
        else { details.fields.removeValue(forKey: "Season"); details.fields.removeValue(forKey: "Episode") }
        return await saveSpecializedDetails(details, for: task, type: .reading)
    }
    func consumeWatchedEpisodeActions(directory: URL? = WatchedEpisodeActionStore.directory) async {
        guard accessState == .granted, !isUndoing, !consumingEpisodeActions else { return }
        consumingEpisodeActions = true
        defer { consumingEpisodeActions = false }
        let pending = WatchedEpisodeActionStore.pending(directory: directory)
        var candidates = tasks
        if pending.contains(where: { action in !tasks.contains(where: { $0.id == action.taskID || $0.metadataID == action.metadataID }) }) {
            candidates = await reminderService.loadTasks(metadataStore: metadataStore)
        }
        for action in pending {
            guard !Task.isCancelled else { break }
            guard let task = currentTask(id: action.taskID) ?? candidates.first(where: { $0.id == action.taskID || $0.metadataID == action.metadataID }), !task.isCompleted,
                  let fields = ReadingMedia.markingEpisodeWatched(specializedDetails(task).fields, showID: action.showID, episodeID: action.episodeID) else {
                WatchedEpisodeActionStore.acknowledge(action, directory: directory)
                continue
            }
            if await saveSpecializedDetails(.init(fields: fields), for: task, type: .reading) {
                WatchedEpisodeActionStore.acknowledge(action, directory: directory)
                await EpisodeNotificationActions.retire(taskID: task.id, showID: action.showID, episodeID: action.episodeID)
            }
        }
    }
    func reconcileWatchedEpisodeActions() async {
        accessState = reminderService.authorizationState
        guard accessState == .granted else { return }
        if !hasLoadedInitialData { applyMetadata(); lists = visibleLists() }
        await refreshTasks(force: true)
        await consumeWatchedEpisodeActions()
    }
    func handleEpisodeNotification(taskID: String, showID: Int, episodeID: Int, snooze: Bool, content: UNNotificationContent) async -> Bool {
        await reconcileWatchedEpisodeActions()
        guard accessState == .granted else { return false }
        var target = currentTask(id: taskID)
        if target == nil { target = await reminderService.loadTasks(metadataStore: metadataStore).first(where: { $0.id == taskID }) }
        guard let task = target, !task.isCompleted else { return false }
        let fields = specializedDetails(task).fields
        guard fields["Episode Alerts"] == "true", fields["Progress"] != "Dropped", fields["Merged Into"] == nil,
              let catalog = ReadingMedia.tracking(fields), catalog.show.id == showID, !catalog.watched.contains(episodeID),
              let episode = catalog.episodes.first(where: { $0.id == episodeID }) else { return false }
        if snooze {
            guard let request = EpisodeNotificationActions.snoozeRequest(content: content, canMarkWatched: episode.release.map { $0 <= Date().addingTimeInterval(3600) } == true) else { return false }
            do { try await UNUserNotificationCenter.current().add(request); return true }
            catch { errorMessage = "The episode reminder could not be scheduled. Please try again."; return false }
        }
        guard let updated = ReadingMedia.markingEpisodeWatched(fields, showID: showID, episodeID: episodeID),
              await saveSpecializedDetails(.init(fields: updated), for: task, type: .reading) else { return false }
        await EpisodeNotificationActions.retire(taskID: taskID, showID: showID, episodeID: episodeID)
        return true
    }
    func refreshWatchInBackground() async -> Bool {
        guard reminderService.authorizationState == .granted, !Task.isCancelled else { return false }
        accessState = reminderService.authorizationState
        if !hasLoadedInitialData { applyMetadata(); lists = visibleLists() }
        await refreshTasks(force: true)
        guard !Task.isCancelled else { return false }
        await consumeWatchedEpisodeActions()
        let success = await refreshWatchReleaseSchedules(maximumShows: 3)
        if !Task.isCancelled { await rescheduleNotifications() }
        return success
    }
    func refreshWatchReleaseSchedules(maximumShows: Int = .max) async -> Bool {
        var success = true
        var refreshed = 0
        let candidates = tasks.compactMap { task -> (TaskItem, ReadingMedia.ShowTracking)? in
            guard !task.isCompleted else { return nil }
            let fields = specializedDetails(task).fields
            guard fields["Progress"] != "Dropped", fields["Merged Into"] == nil,
                  let show = ReadingMedia.tracking(fields) else { return nil }
            return (task, show)
        }.sorted { $0.1.refreshedAt < $1.1.refreshedAt }
        for (task, show) in candidates {
            guard !Task.isCancelled, refreshed < maximumShows else { break }
            refreshed += 1
            if !(await matchWatchShow(show.show.id, taskID: task.id, automatic: true)) { success = false }
        }
        return success
    }
    func refreshWatchShowsIfNeeded() async {
        for task in tasks where !task.isCompleted {
            var details = specializedDetails(task)
            guard details.fields["Progress"] != "Dropped", let catalog = ReadingMedia.tracking(details.fields) else { continue }
            let stage = catalog.progress() == "Finished" ? "Caught Up" : catalog.progress()
            if details.fields["Progress"] != stage { details.fields["Progress"] = stage; setSpecializedDetails(details, for: task) }
            if Date().timeIntervalSince(catalog.refreshedAt) >= 12 * 3600 {
                _ = await matchWatchShow(catalog.show.id, taskID: task.id, automatic: true)
            }
        }
    }
    var episodeReleaseAlerts: [NotificationScheduler.DeadlineAlert] {
        var seen: Set<String> = []
        return tasks.sorted { $0.id < $1.id }.flatMap { task -> [NotificationScheduler.DeadlineAlert] in
            let fields = specializedDetails(task).fields
            guard !task.isCompleted, fields["Episode Alerts"] == "true", fields["Progress"] != "Dropped", fields["Merged Into"] == nil, let catalog = ReadingMedia.tracking(fields) else { return [] }
            let ordered = catalog.ordered
            let groups = Dictionary(grouping: ordered.filter { !catalog.watched.contains($0.id) && $0.airdate != nil }, by: { $0.airdate! })
            return groups.sorted { $0.key < $1.key }.compactMap { date, episodes in
                guard let day = SpecializedTaskDetails.dateValue(date), seen.insert("\(catalog.show.id):\(date)").inserted else { return nil }
                let advance = Int(fields["Episode Alert Advance"] ?? "0") ?? 0
                let exact = advance > 0 ? episodes.compactMap { episode in episode.airstamp == nil ? nil : episode.release }.min()?.addingTimeInterval(-Double(advance) * 60) : nil
                return NotificationScheduler.DeadlineAlert(taskID: task.id, listID: task.listID, taskTitle: task.title, label: "Episode Release", date: day, leadDays: 0,
                    customBody: "\(task.title) · \(episodes.count == 1 ? episodes[0].label : "\(episodes.count) episodes") scheduled to release \(exact == nil ? "today" : "at the listed air time"). Check your saved service for availability.",
                    hour: Int(fields["Episode Alert Hour"] ?? "9") ?? 9, minute: Int(fields["Episode Alert Minute"] ?? "0") ?? 0, exactFireDate: exact, playsSound: fields["Episode Alert Sound"] != "false", episodeShowID: catalog.show.id,
                    episodeID: episodes.first?.id,
                    episodeLabel: episodes.first?.label,
                    episodeRelease: episodes.first?.release)
            }
        }
    }
    func retryReadingPreview(_ task: TaskItem) {
        var details = specializedDetails(task)
        guard let raw = details.fields["Source Link"], let url = URL(string: raw), ReadingMedia.isWebURL(url) else {
            errorMessage = "Add a valid source link before retrying the preview."
            return
        }
        details.fields = ReadingMedia.previewRetryFields(details.fields, title: task.title)
        specializedTasks[task.metadataID] = details
        metadataStore.specializedTasks = specializedTasks
        resumeReadingPreviews()
    }
    func addShoppingItems(_ entries: [ShoppingCaptureItem], listID: String, increaseDuplicates: Bool = false) async -> Int {
        let items = entries.map { item in
            var details = SpecializedTaskDetails()
            details.fields = ["Quantity": item.quantity, "Category": item.category]
            return SpecializedListTemplate.Item(title: item.title, notes: "", details: details)
        }
        return await addShoppingSelection(items, listID: listID, store: shoppingCaptureStore(for: listID), increaseDuplicates: increaseDuplicates)
    }
    /// Saves suggestions and custom entries together, preserving their optional item details.
    func addShoppingSelection(_ entries: [SpecializedListTemplate.Item], listID: String, store: String, increaseDuplicates: Bool = false) async -> Int {
        guard !isUndoing, entries.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return 0 }
        var created: [String] = [], previous: [TaskItem] = []
        var snapshots: [String: SpecializedTaskDetails] = [:]
        var targets: [String: (TaskDraft, SpecializedTaskDetails)] = [:]
        var count = 0
        for item in entries {
            var details = item.details
            if !store.isEmpty { details.fields["Store"] = store }
            details = recallingShoppingPrice(title: item.title, details: details)
            let key = ShoppingQuantity.key(title: item.title, fields: details.fields)
            var draft = TaskDraft(listID: listID)
            draft.title = item.title
            draft.notes = item.notes
            do {
                if increaseDuplicates {
                    if targets[key] == nil, let existing = shoppingDuplicate(item, listID: listID, store: store) {
                        targets[key] = (TaskDraft(task: existing), specializedDetails(existing))
                        previous.append(existing)
                        snapshots[existing.id] = specializedDetails(existing)
                    }
                    if let (existingDraft, existingDetails) = targets[key] {
                        guard let left = ShoppingQuantity.value(existingDetails.fields["Quantity"]), let right = ShoppingQuantity.value(details.fields["Quantity"]), (left + right).isFinite else {
                            errorMessage = "This item has a custom quantity. Keep it separate or edit its quantity first."
                            break
                        }
                        draft = existingDraft
                        details = existingDetails
                        details.fields["Quantity"] = ShoppingQuantity.text(left + right)
                    }
                }
                if draft.reminderID == nil {
                    for field in ["Run", "Run ID", "Last Completed", "Purchased By", "Purchased At"] { details.fields[field] = nil }
                    details.fields["Added By"] = shoppingActor
                    details.fields["Added At"] = Date().ISO8601Format()
                }
                let id = try reminderService.saveTask(draft, metadataStore: metadataStore, shoppingDetails: details)
                if draft.reminderID == nil { created.append(id) }
                draft.reminderID = id
                targets[key] = (draft, details)
                rememberShoppingEstimate(title: draft.title, fields: details.fields)
                specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
                count += 1
            } catch { errorMessage = FriendlyError.message(for: error); break }
        }
        if count > 0 {
            metadataStore.specializedTasks = specializedTasks
            rememberShoppingStore(store, for: listID)
            var profile = listProfile(listID)
            profile.settings["Last Store"] = store
            setListProfile(profile, for: listID)
            taskRedo = nil
            taskUndo = TaskUndo(message: "Add shopping items", previous: previous, wasDeleted: false, createdTaskIDs: created)
            taskUndo?.specializedPrevious = snapshots
            feedbackSequence += 1
            await refreshTasks()
            await rescheduleNotifications()
        }
        return count
    }
    func saveShoppingItem(_ draft: TaskDraft, details: SpecializedTaskDetails) async -> Bool {
        guard !isUndoing, !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            let previous = draft.reminderID.flatMap { currentTask(id: $0) }
            let previousDetails = previous.map { specializedDetails($0) }
            var details = previous == nil ? recallingShoppingPrice(title: draft.title, details: details) : details
            if previous == nil {
                details.fields["Added By"] = shoppingActor
                details.fields["Added At"] = Date().ISO8601Format()
            }
            let id = try reminderService.saveTask(draft, metadataStore: metadataStore, shoppingDetails: details)
            rememberShoppingEstimate(title: draft.title, fields: details.fields)
            specializedTasks[reminderService.metadataIdentifier(forReminderID: id)] = details
            metadataStore.specializedTasks = specializedTasks
            rememberShoppingStore(details.fields["Store"] ?? "", for: draft.listID)
            var profile = listProfile(draft.listID)
            profile.settings["Last Store"] = details.fields["Store"] ?? ""
            setListProfile(profile, for: draft.listID)
            if let previous {
                offerUndo("Shopping item updated", previous: [previous])
                if let previousDetails { taskUndo?.specializedPrevious[previous.id] = previousDetails }
            }
            else { feedbackSequence += 1 }
            await refreshTasks()
            await rescheduleNotifications()
            return true
        } catch { errorMessage = FriendlyError.message(for: error); return false }
    }
    func completedShoppingItemIDs(in listID: String) -> Set<String> {
        guard listProfile(listID).type == .shopping else { return [] }
        return Set(tasks.filter { $0.listID == listID && $0.isCompleted }.map(\.id))
    }
    func clearCompletedShoppingItems(in listID: String, confirmedIDs: Set<String>) async {
        let ids = completedShoppingItemIDs(in: listID).intersection(confirmedIDs)
        guard !ids.isEmpty else { return }
        await clearCompletedTasks(tasks.filter { ids.contains($0.id) })
    }
    /// Open bills' renewal, notice, and cancellation dates, for lists that keep deadline reminders on.
    var billDeadlineAlerts: [NotificationScheduler.DeadlineAlert] {
        tasks.compactMap { task -> [NotificationScheduler.DeadlineAlert]? in
            let profile = listProfile(task.listID)
            guard profile.type == .bills, profile.settings["Deadline Reminders"] != "false", !task.isCompleted else { return nil }
            let fields = specializedDetails(task).fields
            guard !["Paid", "Canceled"].contains(fields["Stage"] ?? "") else { return nil }
            let lead = Int(profile.settings["Deadline Lead Days"] ?? "") ?? 3
            return SpecializedListType.billDeadlineFields.compactMap { key in
                guard profile.settings["Hidden Field " + key] != "true",
                      let date = SpecializedTaskDetails.dateValue(fields[key] ?? "") else { return nil }
                return NotificationScheduler.DeadlineAlert(taskID: task.id, listID: task.listID, taskTitle: task.title, label: key, date: date, leadDays: lead)
            }
        }.flatMap { $0 }
    }
    /// Re-applies reminders after list options that affect them change.
    func refreshDeadlineReminders() async { await rescheduleNotifications() }
}
