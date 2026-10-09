import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

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

struct ShoppingStoreEntry: View {
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

/// Your shopper name, shown on items you add or purchase in shared shopping lists.
/// It applies to every shopping list; it lives here, beside the list it affects, rather than in Settings.
struct ShopperNameSection: View {
    @Bindable var repository: TaskRepository
    @State private var addingShopper = false
    @State private var newShopperName = ""

    var body: some View {
        Section {
            Picker("Your Shopper Name", selection: Binding(get: { repository.shoppingShopperName }, set: { repository.selectShoppingShopper($0) })) {
                Text("Not Set").tag("")
                ForEach(repository.shoppingShopperChoices, id: \.self) { Text($0).tag($0) }
            }
            Button("Add Shopper Name", systemImage: "person.badge.plus") { newShopperName = ""; addingShopper = true }
        } header: { Text("Shopper") } footer: {
            Text("Shown when you add or purchase items in shared shopping lists. Used by all your shopping lists.")
        }
        .alert("Add Shopper Name", isPresented: $addingShopper) {
            TextField("Name", text: $newShopperName).textContentType(.name)
            Button("Cancel", role: .cancel) { newShopperName = "" }
            Button("Add") { repository.selectShoppingShopper(newShopperName); newShopperName = "" }
                .disabled(newShopperName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

struct ShoppingPriceEditor: View {
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

struct ShoppingPriceEntryMode: View {
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
