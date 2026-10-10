import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

extension SpecializedListType {
    var shortDescription: String {
        switch self {
        case .standard: "A flexible checklist for everyday tasks."
        case .shopping: "Shop by category or store, track quantities, and estimate your budget."
        case .projects: "Organize work into sections and milestones, and choose your next actions."
        case .household: "Group chores by room and repeat them after completion."
        case .packing: "Prepare for a trip and track what is ready or packed."
        case .bills: "Track payments, renewals, and cancellation deadlines."
        case .reading: "Save articles, videos, and audio with previews and progress."
        case .errands: "Group stops by destination and prepare before leaving."
        case .appointments: "Keep preparation, questions, outcomes, and follow-ups together."
        case .routines: "Work through ordered steps with timers and reusable checklists."
        }
    }
    var detailsTitle: String {
        switch self {
        case .standard: "Task Details"
        case .shopping: "Shopping Item"
        case .projects: "Project Details"
        case .household: "Chore Details"
        case .packing: "Packing Details"
        case .bills: "Bill Details"
        case .reading: "Reading & Media Details"
        case .errands: "Errand Details"
        case .appointments: "Appointment Details"
        case .routines: "Routine Step Details"
        }
    }
    var syncExplanation: String {
        if self == .shopping {
            return "Shopping item details travel with shared reminders through their account. Categories, aisle layouts, budgets, and other list preferences sync through your TaskFlow iCloud metadata. Changing List Type keeps saved details."
        }
        return "Reminder titles, dates, and completion sync through their Reminders account. These extra fields, templates, and list preferences sync through your TaskFlow iCloud metadata; sharing a list in Reminders does not share them with another account. Changing List Type keeps saved details."
    }
    var example: (title: String, detail: String) {
        switch self {
        case .standard: ("Plan the weekend", "Tomorrow · Priority: Medium")
        case .shopping: ("Apples", "3 items · Produce · Grocery store")
        case .projects: ("Review first draft", "In Review · Launch milestone · Next Action")
        case .household: ("Vacuum the living room", "Living Room · Every 7 days")
        case .packing: ("Phone charger", "Electronics · Essential · Prepared")
        case .bills: ("Internet bill", "$65.00 · Due tomorrow · Unpaid")
        case .reading: ("An article to revisit", "Article · 5 min · Saved")
        case .errands: ("Return a package", "Post office · Bring the receipt")
        case .appointments: ("Annual appointment", "Preparation · Questions · Follow-up")
        case .routines: ("Review today's plan", "Step 1 · Required · 5 min timer")
        }
    }
    var starterSets: [(String, [String])] {
        switch self {
        case .standard: []
        case .shopping: [("Grocery Staples", ["Milk", "Eggs", "Bread", "Apples", "Rice", "Coffee"])]
        case .projects: [("Project Kickoff", ["Define outcome", "Break into milestones", "Choose next action", "Review progress"])]
        case .household: [("Weekly Home Reset", ["Kitchen: Clean counters", "Bathroom: Clean sink", "Laundry: Wash towels", "Living Room: Vacuum"]), ("Seasonal Home Care", ["Replace air filters", "Check smoke detectors", "Clean gutters"])]
        case .packing: [("Weekend Trip", ["Travel documents", "Medication", "Phone charger", "Clothes", "Toiletries"]), ("Business Trip", ["Travel documents", "Laptop", "Laptop charger", "Work clothes", "Medication"])]
        case .bills: [("Monthly Bills", ["Review housing payment", "Review utility bills", "Review subscriptions"])]
        case .reading: [("Reading Review", ["Choose something to read", "Review saved articles", "Record a takeaway"])]
        case .errands: [("Before You Leave", ["Check opening hours", "Bring returns and receipts", "Check shopping list"])]
        case .appointments: [("Appointment Preparation", ["Confirm time and location", "Prepare questions", "Bring documents", "Record outcome", "Schedule follow-up"])]
        case .routines: [("Morning Routine", ["Review today's plan", "Prepare essentials", "Start priority task"]), ("Evening Reset", ["Review completed tasks", "Prepare for tomorrow", "Tidy workspace"])]
        }
    }
    func starterTemplate(index: Int, listID: String) -> SpecializedListTemplate? {
        guard starterSets.indices.contains(index) else { return nil }
        let (title, names) = starterSets[index]
        let items = names.enumerated().map { order, name in
            var details = SpecializedTaskDetails()
            if self == .shopping { details.fields["Category"] = ShoppingCatalog.category(for: name) }
            if self == .routines { details.fields["Step Order"] = String(order + 1) }
            if self == .packing { details.fields["Essential"] = ["Travel documents", "Medication"].contains(name) ? "Yes" : "No" }
            if self == .household {
                details.fields["Season"] = title.contains("Seasonal") ? "Seasonal" : "Weekly"
                if let room = name.split(separator: ":").first, name.contains(":") { details.fields["Room"] = String(room) }
            }
            return SpecializedListTemplate.Item(title: name, notes: "", details: details)
        }
        return SpecializedListTemplate(title: title, listID: listID, items: items)
    }
    var stageField: String { self == .reading ? "Progress" : "Stage" }
    var workflowLabel: String {
        switch self {
        case .shopping: "purchased"
        case .packing: "packed"
        case .bills: "paid"
        case .reading: "finished"
        default: "completed"
        }
    }
    func workflowDone(completed: Bool, fields: [String: String]) -> Bool {
        switch self {
        case .bills: return fields["Stage"] == "Paid" || (completed && fields["Stage"] != "Canceled")
        case .packing: return completed || fields["Stage"] == "Packed"
        case .reading: return completed || fields["Progress"] == "Finished"
        default: return completed
        }
    }
    func fieldsForCompletion(_ completed: Bool, fields: [String: String]) -> [String: String] {
        guard !stages.isEmpty else { return fields }
        var result = fields
        if completed {
            result[stageField] = self == .bills ? (fields[stageField] == "Canceled" ? "Canceled" : "Paid") : stages.last
        } else if ["Paid", "Canceled", "Packed", "Finished"].contains(fields[stageField] ?? "") {
            result[stageField] = stages.first
        }
        return result
    }
    func displayedStage(completed: Bool, fields: [String: String]) -> String {
        fieldsForCompletion(completed, fields: fields)[stageField] ?? stages.first ?? ""
    }
    var bulkFields: [String] {
        Array(Set(fields.filter { ["Room", "Category", "Milestone", "Section", "Provider", "Destination", "Contact"].contains($0) } + (stages.isEmpty ? [] : [stageField]))).sorted()
    }
}

struct ListTypeChooser: View {
    @Binding var selection: SpecializedListType
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(SpecializedListType.allCases) { type in
                Section {
                    Button {
                        selection = type
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(type.rawValue, systemImage: type.icon).font(.headline)
                                Spacer()
                                if selection == type { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }
                            Text(type.shortDescription).font(.subheadline).foregroundStyle(.secondary)
                            if !type.fields.isEmpty { Text("Fields: " + type.fields.prefix(4).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                            ListTypeSample(type: type)
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityHint("Select this list type")
                }
            }
        }.navigationTitle("List Type").taskFlowThemedBackground()
    }
}

struct ListTypeSample: View {
    let type: SpecializedListType
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(type.example.title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(type.example.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius))
    }
}

struct ListFieldPicker: View {
    let title: String
    @Binding var value: String
    let choices: [String]
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var normalized: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var options: [String] {
        Array(Set(choices + (value.isEmpty ? [] : [value]))).filter { !$0.isEmpty && (normalized.isEmpty || $0.localizedCaseInsensitiveContains(normalized)) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        List {
            Button("None") { value = ""; dismiss() }
            if !normalized.isEmpty, !choices.contains(where: { $0.localizedCaseInsensitiveCompare(normalized) == .orderedSame }) {
                Button("Use “" + normalized + "”", systemImage: "plus") { value = normalized; dismiss() }
            }
            ForEach(options, id: \.self) { option in
                Button { value = option; dismiss() } label: {
                    HStack { Text(option); Spacer(); if value == option { Image(systemName: "checkmark") } }
                }
            }
        }.searchable(text: $search, prompt: "Search or add " + title.lowercased())
            .navigationTitle(title).taskFlowThemedBackground()
    }
}

struct ListNumberField: View {
    let title: String
    @Binding var value: String
    var integer = false
    var minimum: Double = 0
    private var number: Double? {
        Double(value.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
    }
    var valid: Bool {
        value.isEmpty || (number.map { $0.isFinite && $0 >= minimum && (!integer || $0.rounded() == $0) } ?? false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title)
                    TextField("Not Set", text: $value).multilineTextAlignment(.trailing).keyboardType(integer ? .numberPad : .decimalPad)
                    controls
                }
                VStack(alignment: .leading) {
                    Text(title)
                    TextField("Not Set", text: $value).keyboardType(integer ? .numberPad : .decimalPad)
                    controls
                }
            }
            if !valid { Text(integer ? "Enter a whole number of at least \(Int(minimum))." : "Enter a number of at least \(minimum.formatted()).").font(.caption).foregroundStyle(.red) }
        }
    }
    private var controls: some View {
        HStack(spacing: 8) {
            Button { adjust(-1) } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                .disabled(!valid || (number ?? minimum) <= minimum).accessibilityLabel("Decrease " + title)
            Button { adjust(1) } label: { Image(systemName: "plus.circle").frame(minWidth: 44, minHeight: 44) }
                .disabled(!valid).accessibilityLabel("Increase " + title)
        }.buttonStyle(.borderless)
    }
    private func adjust(_ delta: Double) {
        let next = max(minimum, (number ?? minimum) + delta)
        value = ShoppingQuantity.text(next)
    }
}

extension TaskRepository {
    func listFieldChoices(_ key: String, listID: String) -> [String] {
        var values = tasks.filter { $0.listID == listID }.compactMap { specializedDetails($0).fields[key] }
        if key == "Section" { values += (listProfile(listID).settings["Sections"] ?? "").components(separatedBy: "\n") }
        if key == "Room" { values += ["Kitchen", "Bathroom", "Bedroom", "Living Room", "Laundry", "Garage", "Outdoors"] }
        if key == "Category", listProfile(listID).type == .shopping { values += shoppingCategories(listID: listID) }
        return Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct ListBulkEditor: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Binding var selectedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var field = ""
    @State private var value = ""
    @State private var applying = false
    @State private var error: String?
    private var type: SpecializedListType { repository.listProfile(listID).type }
    private var fields: [String] { type.bulkFields.filter { repository.listProfile(listID).settings["Hidden Field " + $0] != "true" } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Update \(selectedIDs.count) selected items").font(.headline)
                    Picker("Field", selection: $field) {
                        ForEach(fields, id: \.self) { Text($0 == "Progress" ? "Reading Progress" : $0).tag($0) }
                    }
                    if field == type.stageField, !type.stages.isEmpty {
                        Picker("New Value", selection: $value) {
                            Text("Choose…").tag("")
                            ForEach(type.stages, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        NavigationLink {
                            ListFieldPicker(title: field, value: $value, choices: repository.listFieldChoices(field, listID: listID))
                        } label: { LabeledContent("New Value", value: value.isEmpty ? "None (clear field)" : value) }
                    }
                } footer: {
                    Text("Only this field changes. One Undo restores all changed items." + (field == type.stageField ? " Final stages also complete the reminders; earlier stages reopen them." : ""))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.taskFlowThemedBackground().navigationTitle("Edit Selected Items")
                .interactiveDismissDisabled(applying)
                .onAppear { field = fields.first ?? "" }
                .onChange(of: field) { value = ""; error = nil }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(applying) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(applying ? "Applying…" : "Apply") {
                            applying = true
                            Task {
                                let applied = await repository.bulkUpdateListDetails(ids: selectedIDs, listID: listID, field: field, value: value)
                                selectedIDs.subtract(applied)
                                applying = false
                                if selectedIDs.isEmpty { dismiss() }
                                else { error = repository.errorMessage ?? "Some selected items are no longer available. Review your selection and retry." }
                            }
                        }.disabled(applying || selectedIDs.isEmpty || field.isEmpty || (field == type.stageField && !type.stages.contains(value)) || repository.isUndoing)
                    }
                }
        }
    }
}

enum ListEmptyState: Equatable {
    case empty, finished, filtered
    static func resolve(total: Int, open: Int) -> ListEmptyState {
        if total == 0 { return .empty }
        return open == 0 ? .finished : .filtered
    }
    func title(type: SpecializedListType) -> String {
        switch self {
        case .empty: return "Start Your " + (type == .shopping ? "Shopping List" : "List")
        case .finished: return type == .bills ? "No Open Bills" : (type == .shopping ? "Everything Purchased" : "All Done")
        case .filtered: return "No Matching Items"
        }
    }
    func message(type: SpecializedListType) -> String {
        switch self {
        case .empty: return "Add an item or start a template to get going."
        case .finished: return "Review completed items below, add something new, or start another checklist."
        case .filtered: return "Your filters hide the available items. Change or reset filters to see them."
        }
    }
}

struct ListURLField: View {
    let title: String
    @Binding var value: String
    private var url: URL? { ReadingMedia.webURL(in: value).flatMap { $0.absoluteString == value.trimmingCharacters(in: .whitespacesAndNewlines) ? $0 : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            HStack {
                TextField("https://…", text: $value).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                PasteButton(payloadType: URL.self) { links in if let first = links.first { value = first.absoluteString } }.labelStyle(.iconOnly)
            }
            if let url { Link("Open Link", destination: url).font(.caption) }
            else if !value.isEmpty { Text("Enter a complete http or https link.").font(.caption).foregroundStyle(.red) }
        }
    }
}

enum ListFieldNumber {
    static let keys = ["Quantity", "Estimated Minutes", "Timer Minutes", "Step Order", "Amount", "Price", "Year", "Season", "Episode", "Runtime Minutes"]
    static func integer(_ key: String) -> Bool { ["Estimated Minutes", "Timer Minutes", "Step Order", "Year", "Season", "Episode", "Runtime Minutes"].contains(key) }
    static func minimum(_ key: String) -> Double {
        if key == "Quantity" { return 0.01 }
        return ["Step Order", "Timer Minutes", "Year", "Season", "Episode", "Runtime Minutes"].contains(key) ? 1 : 0
    }
    static func parse(_ raw: String, key: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> Double? {
        let canonical = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: decimalSeparator, with: ".")
        guard let number = Double(canonical), number.isFinite, number >= minimum(key), !integer(key) || number.rounded() == number else { return nil }
        return number
    }
}

struct ListOrderEditor: View {
    @Bindable var repository: TaskRepository
    var body: some View {
        List {
            Section {
                ForEach(repository.lists) { list in
                    Label(list.title, systemImage: repository.listIcon(for: list.id)).foregroundStyle(list.color)
                }.onMove { repository.moveLists(fromOffsets: $0, toOffset: $1) }
            } footer: { Text("Drag lists into your preferred order. This order is used throughout TaskFlow and syncs when TaskFlow cloud sync is enabled.") }
        }
        .navigationTitle("Reorder Lists")
        .environment(\.editMode, .constant(.active))
        .taskFlowThemedBackground()
    }
}

struct EventLinkPicker: View {
    @Bindable var repository: TaskRepository
    @Binding var selection: String
    @State private var query = ""
    @State private var calendarID = ""
    @State private var period = "Upcoming"
    @Environment(\.dismiss) private var dismiss
    private var events: [CalendarEvent] {
        repository.calendarEvents.filter { event in
            (calendarID.isEmpty || event.calendarID == calendarID)
            && (period == "Loaded" || event.endDate >= Calendar.current.startOfDay(for: Date()))
            && (query.isEmpty || [event.title, event.location ?? "", repository.eventCalendars.first { $0.id == event.calendarID }?.title ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.startDate < $1.startDate }
    }
    var body: some View {
        List {
            Section {
                Picker("When", selection: $period) { Text("Upcoming").tag("Upcoming"); Text("All Loaded").tag("Loaded") }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendar").font(.headline)
                    Picker("Calendar", selection: $calendarID) {
                        Text("All Calendars").tag("")
                        ForEach(repository.eventCalendars) { Text($0.title).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                Button("Remove Event Link", role: .destructive) { selection = ""; dismiss() }.disabled(selection.isEmpty)
            }
            Section {
                ForEach(events, id: \.occurrenceKey) { event in
                    Button { selection = event.id; dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).foregroundStyle(.primary)
                                Text(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)).font(.subheadline)
                                Text([repository.eventCalendars.first { $0.id == event.calendarID }?.title, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption)
                            }
                            Spacer()
                            if selection == event.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                }
                if events.isEmpty { ContentUnavailableView("No Matching Events", systemImage: "calendar", description: Text("Try a different title, calendar, or time filter.")) }
            } footer: { Text("Search covers calendar events currently loaded in TaskFlow. Open Calendar to load another date range.") }
        }
        .searchable(text: $query, prompt: "Title, location, or calendar")
        .navigationTitle("Link Event")
        .navigationBarTitleDisplayMode(.inline)
        .taskFlowThemedBackground()
    }
}

struct DependencyTaskPicker: View {
    @Bindable var repository: TaskRepository
    let taskID: String
    @State private var query = ""
    @State private var listID = ""
    @State private var saving = false
    private var task: TaskItem? { repository.tasks.first { $0.id == taskID } }
    var body: some View {
        List {
            Section {
                Picker("List", selection: $listID) {
                    Text("All Lists").tag("")
                    ForEach(repository.lists) { Text($0.title).tag($0.id) }
                }
            } footer: { Text("Choose tasks that must finish first. Completed tasks and tasks that would create a dependency cycle are excluded.") }
            if let task {
                Section("Waiting On") {
                    ForEach(repository.tasks.filter { candidate in
                        (task.blockedByTaskIDs.contains(candidate.id) || repository.canAddDependency(candidate, to: task))
                        && (listID.isEmpty || candidate.listID == listID)
                        && (query.isEmpty || candidate.title.localizedCaseInsensitiveContains(query))
                    }) { candidate in
                        Button {
                            saving = true
                            Task { _ = await repository.setDependency(candidate, for: task, enabled: !task.blockedByTaskIDs.contains(candidate.id)); saving = false }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(candidate.title).foregroundStyle(.primary)
                                    Text(repository.lists.first { $0.id == candidate.listID }?.title ?? "Task").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: task.blockedByTaskIDs.contains(candidate.id) ? "checkmark.circle.fill" : "plus.circle")
                            }
                        }.disabled(saving || repository.isUndoing)
                    }
                }
                if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
        .searchable(text: $query, prompt: "Search tasks")
        .navigationTitle("Choose Dependencies")
        .navigationBarTitleDisplayMode(.inline)
        .taskFlowThemedBackground()
    }
}

struct NoteFormattingCommand: Equatable {
    let id = UUID()
    var opening: String
    var closing = ""
    var placeholder = "text"
    var wholeLine = false
}

enum NoteMarkupEditing {
    static func apply(_ command: NoteFormattingCommand, to text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let source = text as NSString
        let start = min(max(0, selection.location), source.length)
        var range = NSRange(location: start, length: min(max(0, selection.length), source.length - start))
        if command.wholeLine { range = source.lineRange(for: range) }
        let selected = source.substring(with: range)
        let content = selected.isEmpty ? command.placeholder : selected
        let replacement: String
        if command.wholeLine {
            let lines = content.components(separatedBy: "\n")
            replacement = lines.enumerated().map { index, line in
                if line.isEmpty, index == lines.count - 1, content.hasSuffix("\n") { return "" }
                let prefix = command.opening == "1. " ? "\(index + 1). " : command.opening
                return prefix + line
            }.joined(separator: "\n")
        } else { replacement = command.opening + content + command.closing }
        return (source.replacingCharacters(in: range, with: replacement), NSRange(location: range.location + (command.opening as NSString).length, length: (content as NSString).length))
    }
}

extension NSAttributedString.Key {
    static let notePrefix = NSAttributedString.Key("TaskFlow.notePrefix")
}

enum NoteRichText {
    static var base: [NSAttributedString.Key: Any] { [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label] }
    static func font(bold: Bool, italic: Bool, heading: Bool = false) -> UIFont {
        let original = UIFont.preferredFont(forTextStyle: heading ? .title2 : .body)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold || heading { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return UIFont(descriptor: original.fontDescriptor.withSymbolicTraits(traits) ?? original.fontDescriptor, size: original.pointSize)
    }
    static func block(_ line: String) -> (prefix: String, body: String) {
        for prefix in ["- [ ] ", "- [x] ", "- [X] ", "###### ", "##### ", "#### ", "### ", "## ", "# ", "- ", "* ", "> "] where line.hasPrefix(prefix) {
            return (prefix, String(line.dropFirst(prefix.count)))
        }
        if let range = line.range(of: #"^\d+\. "#, options: .regularExpression) { return (String(line[range]), String(line[range.upperBound...])) }
        return ("", line)
    }
    static func marker(_ prefix: String) -> String {
        if prefix.hasPrefix("- [") { return prefix.lowercased().contains("x") ? "☑ " : "☐ " }
        if prefix == "- " || prefix == "* " { return "• " }
        if prefix == "> " { return "❯ " }
        if prefix.hasPrefix("#") { return "" }
        return prefix
    }
    static func decode(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
            let (prefix, body) = block(line)
            var attributes = base
            attributes[.notePrefix] = prefix
            attributes[.font] = font(bold: false, italic: prefix == "> ", heading: prefix.hasPrefix("#"))
            result.append(NSAttributedString(string: marker(prefix), attributes: attributes))
            if let parsed = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    var style = attributes
                    let intent = run.inlinePresentationIntent ?? []
                    style[.font] = font(bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized) || prefix == "> ", heading: prefix.hasPrefix("#"))
                    if let link = run.link { style[.link] = link }
                    result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: style))
                }
            } else { result.append(NSAttributedString(string: body, attributes: attributes)) }
        }
        return result
    }
    static func escaped(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        for symbol in ["*", "_", "[", "]", "#", "`", ">", "-"] { result = result.replacingOccurrences(of: symbol, with: "\\" + symbol) }
        if let range = result.range(of: #"^\d+\. "#, options: .regularExpression) {
            let number = String(result[range]).replacingOccurrences(of: ".", with: "\\.")
            result.replaceSubrange(range, with: number)
        }
        return result
    }
    static func encode(_ text: NSAttributedString) -> String {
        let source = text.string as NSString
        var lines: [String] = []
        var offset = 0
        for line in text.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let prefix = offset < text.length ? text.attribute(.notePrefix, at: offset, effectiveRange: nil) as? String ?? "" : ""
            let visible = marker(prefix)
            let skip = line.hasPrefix(visible) ? (visible as NSString).length : 0
            let range = NSRange(location: offset + skip, length: max(0, length - skip))
            var content = ""
            // Coalesce equivalent inline styles, ignoring UIKit-only attributes such as colors.
            // Otherwise adjacent bold runs can become ambiguous adjacent Markdown delimiters.
            var segments: [(text: String, bold: Bool, italic: Bool, link: URL?)] = []
            text.enumerateAttributes(in: range) { attrs, run, _ in
                let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                let bold = traits.contains(.traitBold) && !prefix.hasPrefix("#")
                let italic = traits.contains(.traitItalic) && prefix != "> "
                let link = attrs[.link] as? URL
                let raw = source.substring(with: run)
                if let last = segments.last, last.bold == bold, last.italic == italic, last.link == link {
                    segments[segments.count - 1].text += raw
                } else { segments.append((raw, bold, italic, link)) }
            }
            for segment in segments {
                let raw = segment.text
                let leading = String(raw.prefix { $0.isWhitespace })
                let trailing = String(raw.dropFirst(leading.count).reversed().prefix { $0.isWhitespace }.reversed())
                let core = String(raw.dropFirst(leading.count).dropLast(trailing.count))
                var value = escaped(core)
                if !core.isEmpty, segment.italic { value = "*" + value + "*" }
                if !core.isEmpty, segment.bold { value = "**" + value + "**" }
                if let link = segment.link { value = "[" + value + "](" + link.absoluteString + ")" }
                content += escaped(leading) + value + escaped(trailing)
            }
            lines.append(prefix + content)
            offset += length + 1
        }
        return lines.joined(separator: "\n")
    }
    static func legacyText(_ text: String, format: QuickNoteFormat) -> String {
        if format == .markdown { return text }
        return text.components(separatedBy: "\n").map { line in
            let parsed = block(line)
            let body = escaped(parsed.prefix.isEmpty ? line : parsed.body)
            switch format {
            case .bullets: return "- " + body
            case .checklist: return (parsed.prefix.lowercased().contains("[x]") ? "- [x] " : "- [ ] ") + body
            case .quote: return "> " + body
            default: return escaped(line)
            }
        }.joined(separator: "\n")
    }
    static func formatted(_ input: NSAttributedString, selection: NSRange, command: NoteFormattingCommand) -> (NSAttributedString, NSRange) {
        let result = NSMutableAttributedString(attributedString: input)
        let range = NSRange(location: min(selection.location, input.length), length: min(selection.length, max(0, input.length - selection.location)))
        if command.wholeLine {
            let paragraph = (input.string as NSString).lineRange(for: range)
            let original = input.attributedSubstring(from: paragraph)
            let source = original.string as NSString
            let rebuilt = NSMutableAttributedString(string: "")
            var offset = 0
            for (index, line) in original.string.components(separatedBy: "\n").enumerated() {
                if index > 0 { rebuilt.append(NSAttributedString(string: "\n", attributes: base)) }
                let length = (line as NSString).length
                if length == 0, index > 0, offset >= source.length { break }
                let old = offset < original.length ? original.attribute(.notePrefix, at: offset, effectiveRange: nil) as? String ?? "" : ""
                let oldMarker = marker(old)
                let skip = line.hasPrefix(oldMarker) ? (oldMarker as NSString).length : 0
                let body = NSMutableAttributedString(attributedString: original.attributedSubstring(from: NSRange(location: offset + skip, length: max(0, length - skip))))
                let prefix = command.opening == "1. " ? "\(index + 1). " : command.opening
                var attrs = base; attrs[.notePrefix] = prefix
                attrs[.font] = font(bold: false, italic: prefix == "> ", heading: prefix.hasPrefix("#"))
                if body.length > 0 {
                    body.addAttribute(.notePrefix, value: prefix, range: NSRange(location: 0, length: body.length))
                    if prefix.isEmpty { body.addAttribute(.font, value: attrs[.font]!, range: NSRange(location: 0, length: body.length)) }
                    else if prefix.hasPrefix("#") || prefix == "> " {
                        body.enumerateAttribute(.font, in: NSRange(location: 0, length: body.length)) { value, run, _ in
                            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                            body.addAttribute(.font, value: font(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic) || prefix == "> ", heading: prefix.hasPrefix("#")), range: run)
                        }
                    }
                }
                rebuilt.append(NSAttributedString(string: marker(prefix), attributes: attrs)); rebuilt.append(body)
                offset += length + 1
            }
            result.replaceCharacters(in: paragraph, with: rebuilt)
            return (result, NSRange(location: paragraph.location + rebuilt.length - (rebuilt.string.hasSuffix("\n") ? 1 : 0), length: 0))
        }
        guard range.length > 0 else { return (result, range) }
        if command.opening == "[", let url = URL(string: String(command.closing.dropFirst(2).dropLast())) {
            result.addAttribute(.link, value: url, range: range)
        } else {
            let trait: UIFontDescriptor.SymbolicTraits = command.opening == "**" ? .traitBold : .traitItalic
            var allEnabled = true
            input.enumerateAttribute(.font, in: range) { value, _, _ in
                if !((value as? UIFont)?.fontDescriptor.symbolicTraits.contains(trait) ?? false) { allEnabled = false }
            }
            input.enumerateAttributes(in: range) { attrs, run, _ in
                var traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                if allEnabled { traits.remove(trait) } else { traits.insert(trait) }
                let prefix = attrs[.notePrefix] as? String ?? ""
                result.addAttribute(.font, value: font(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic), heading: prefix.hasPrefix("#")), range: run)
            }
        }
        return (result, range)
    }
}

struct NoteFormattingTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var command: NoteFormattingCommand?
    @Binding var focused: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.accessibilityLabel = "Note text"
        view.attributedText = NoteRichText.decode(text)
        view.typingAttributes = NoteRichText.base
        context.coordinator.serialized = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.serialized != text {
            let selection = view.selectedRange
            view.attributedText = NoteRichText.decode(text)
            coordinator.serialized = text
            view.selectedRange = NSRange(location: min(selection.location, view.attributedText.length), length: 0)
        }
        if let command, coordinator.applied != command.id {
            coordinator.applied = command.id
            let selection = view.selectedRange
            if selection.length == 0 && !command.wholeLine && command.opening != "[" {
                var attrs = view.typingAttributes
                let trait: UIFontDescriptor.SymbolicTraits = command.opening == "**" ? .traitBold : .traitItalic
                var traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                attrs[.font] = NoteRichText.font(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                view.typingAttributes = attrs
            } else {
                var source = view.attributedText ?? NSAttributedString(string: "")
                var range = selection
                if command.opening == "[", range.length == 0 {
                    let value = NSMutableAttributedString(attributedString: source)
                    value.insert(NSAttributedString(string: command.placeholder, attributes: view.typingAttributes), at: range.location)
                    range.length = (command.placeholder as NSString).length; source = value
                }
                let result = NoteRichText.formatted(source, selection: range, command: command)
                coordinator.replace(view, text: result.0, selection: result.1, deferred: true)
                if command.wholeLine {
                    var attrs = NoteRichText.base
                    attrs[.notePrefix] = command.opening
                    attrs[.font] = NoteRichText.font(bold: false, italic: command.opening == "> ", heading: command.opening.hasPrefix("#"))
                    view.typingAttributes = attrs
                }
            }
            view.becomeFirstResponder()
            DispatchQueue.main.async { self.focused = true; self.command = nil }
        } else if focused && !view.isFirstResponder { view.becomeFirstResponder() }
        else if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteFormattingTextEditor
        var applied: UUID?
        var serialized = ""
        init(_ parent: NoteFormattingTextEditor) { self.parent = parent }
        func publish(_ view: UITextView, deferred: Bool = false) {
            serialized = NoteRichText.encode(view.attributedText)
            let value = serialized
            if deferred { DispatchQueue.main.async { self.parent.text = value } }
            else { parent.text = value }
        }
        func replace(_ view: UITextView, text: NSAttributedString, selection: NSRange, deferred: Bool = false) {
            let old = view.attributedText ?? NSAttributedString(string: "")
            let oldSelection = view.selectedRange
            view.undoManager?.registerUndo(withTarget: self) { target in target.replace(view, text: old, selection: oldSelection) }
            view.attributedText = text; view.selectedRange = selection
            publish(view, deferred: deferred)
        }
        func textViewDidChange(_ view: UITextView) {
            let source = view.textStorage.string as NSString
            var offset = 0
            while offset < source.length {
                let range = source.lineRange(for: NSRange(location: offset, length: 0))
                let prefix = view.textStorage.attribute(.notePrefix, at: offset, effectiveRange: nil) as? String ?? ""
                let marker = NoteRichText.marker(prefix)
                if !marker.isEmpty && !source.substring(with: range).hasPrefix(marker) {
                    view.textStorage.removeAttribute(.notePrefix, range: range)
                }
                offset = NSMaxRange(range)
            }
            publish(view)
        }
        func textViewDidBeginEditing(_ view: UITextView) { DispatchQueue.main.async { self.parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { DispatchQueue.main.async { self.parent.focused = false } }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText value: String) -> Bool {
            guard value == "\n" else { return true }
            let source = view.attributedText ?? NSAttributedString(string: "")
            let lineRange = (source.string as NSString).lineRange(for: NSRange(location: range.location, length: 0))
            let prefix = lineRange.location < source.length ? source.attribute(.notePrefix, at: lineRange.location, effectiveRange: nil) as? String ?? "" : view.typingAttributes[.notePrefix] as? String ?? ""
            guard !prefix.isEmpty else { view.typingAttributes = NoteRichText.base; return true }
            let line = (source.string as NSString).substring(with: lineRange).trimmingCharacters(in: .newlines)
            if line == NoteRichText.marker(prefix) {
                let result = NoteRichText.formatted(source, selection: range, command: .init(opening: "", wholeLine: true))
                replace(view, text: result.0, selection: result.1); view.typingAttributes = NoteRichText.base
                return false
            }
            let nextPrefix: String
            if prefix.hasPrefix("- [") { nextPrefix = "- [ ] " }
            else if let number = Int(prefix.replacingOccurrences(of: ". ", with: "")) { nextPrefix = "\(number + 1). " }
            else if prefix.hasPrefix("#") || prefix == "> " { nextPrefix = "" }
            else { nextPrefix = prefix }
            var attrs = NoteRichText.base; attrs[.notePrefix] = nextPrefix
            let insertion = NSAttributedString(string: "\n" + NoteRichText.marker(nextPrefix), attributes: attrs)
            let updated = NSMutableAttributedString(attributedString: source)
            updated.replaceCharacters(in: range, with: insertion)
            replace(view, text: updated, selection: NSRange(location: range.location + insertion.length, length: 0))
            view.typingAttributes = attrs
            return false
        }
    }
}

struct ListIconPicker: View {
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                ForEach(TaskRepository.listIconChoices.filter { query.isEmpty || $0.replacingOccurrences(of: ".", with: " ").localizedCaseInsensitiveContains(query) }, id: \.self) { symbol in
                    Button { selection = symbol; dismiss() } label: {
                        VStack(spacing: 8) {
                            Image(systemName: symbol).font(.title2).frame(height: 32)
                            Text(symbol.replacingOccurrences(of: ".", with: " ").capitalized).font(.caption).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 85)
                        .padding(6)
                        .background(Color.accentColor.opacity(selection == symbol ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius).stroke(selection == symbol ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == symbol ? .isSelected : [])
                }
            }.padding()
        }
        .searchable(text: $query, prompt: "Search icons")
        .navigationTitle("List Icon")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TaskTagChip: View {
    let name: String
    let color: Color
    var body: some View {
        Text("#" + name).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Tag " + name)
    }
}

enum TodayPlanning {
    enum Spotlight {
        case now(CalendarEvent), next(CalendarEvent), allDay(CalendarEvent), finished, empty
    }
    struct TimelineEntry: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let task: TaskItem?
        let event: CalendarEvent?
        let estimated: Bool
    }
    static func timeline(tasks: [TaskItem], events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [TimelineEntry] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let taskEntries = tasks.compactMap { task -> TimelineEntry? in
            guard !task.isCompleted, task.hasDueTime, let due = task.dueDate, due >= start, due < end else { return nil }
            return TimelineEntry(id: "task:" + task.id, title: task.title, start: due,
                end: due.addingTimeInterval(Double(max(1, task.durationMinutes ?? 30)) * 60), task: task, event: nil, estimated: task.durationMinutes == nil)
        }
        let eventEntries = events.filter { !$0.isAllDay && $0.startDate < end && $0.endDate > start }.map {
            TimelineEntry(id: "event:" + $0.occurrenceKey, title: $0.title, start: $0.startDate, end: $0.endDate, task: nil, event: $0, estimated: false)
        }
        return (taskEntries + eventEntries).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    static func conflicts(_ entry: TimelineEntry, entries: [TimelineEntry]) -> Bool {
        entries.contains { $0.id != entry.id && $0.start < entry.end && $0.end > entry.start }
    }
    static func gaps(_ entries: [TimelineEntry], now: Date, calendar: Calendar = .current) -> [DayTimeGap] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var cursor = now
        var result: [DayTimeGap] = []
        for entry in entries.sorted(by: { $0.start < $1.start }) where entry.end > now {
            let start = min(end, max(now, entry.start))
            if start > cursor { result.append(DayTimeGap(start: cursor, end: start, nextTitle: entry.title)) }
            cursor = max(cursor, min(end, entry.end))
        }
        if cursor < end { result.append(DayTimeGap(start: cursor, end: end, nextTitle: nil)) }
        return result
    }
    static func availableSeconds(_ entries: [TimelineEntry], now: Date, calendar: Calendar = .current) -> Int {
        max(0, Int(gaps(entries, now: now, calendar: calendar).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }))
    }
    static func countdownText(seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02dh %02dm %02ds", value / 3600, (value % 3600) / 60, value % 60)
    }
    static func focusScore(_ task: TaskItem, pinned: Bool, availableMinutes: Int?, now: Date) -> Int {
        var score = pinned ? 1000 : 0
        if let due = task.dueDate {
            score += due <= now ? 500 : 200
            if task.hasDueTime {
                let minutes = due.timeIntervalSince(now) / 60
                if minutes.isFinite { score += Int(max(0, min(120, 120 - minutes))) }
            }
        }
        if task.priority == .high { score += 150 }
        if task.isFlagged { score += 80 }
        if let duration = task.durationMinutes, let availableMinutes, duration > 0, duration <= availableMinutes { score += 100 }
        return score
    }
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    static func emptyTaskMessage(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> String {
        let scheduled = tasks.filter { task in task.dueDate.map { calendar.isDate($0, inSameDayAs: now) } == true }
        if scheduled.contains(where: { !$0.isCompleted }) { return "Today’s remaining tasks are in Overdue" }
        return scheduled.isEmpty ? "No tasks due today" : "Today’s scheduled tasks are finished"
    }
    static func spotlight(_ events: [CalendarEvent], now: Date) -> Spotlight {
        let timed = events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        if let event = timed.last(where: { $0.startDate <= now && $0.endDate > now }) { return .now(event) }
        if let event = timed.first(where: { $0.startDate > now }) { return .next(event) }
        if let event = events.first(where: { $0.isAllDay && $0.startDate <= now && $0.endDate > now }) { return .allDay(event) }
        return timed.isEmpty ? .empty : .finished
    }
}

struct TodayPriorityPicker: View {
    @Bindable var repository: TaskRepository
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(repository.todayPriorityTasks) { task in
                        HStack {
                            Button { repository.toggleTodayPriority(task) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.borderless).accessibilityLabel("Remove priority " + task.title)
                            Text(task.title).strikethrough(task.isCompleted)
                        }
                    }.onMove { repository.moveTodayPriorities(fromOffsets: $0, toOffset: $1) }
                } header: { Text("Top 3 · \(repository.todayPriorityTasks.count)/3") } footer: { Text("Drag to reorder. Priorities are saved for today without changing task due dates. Start fresh each day.") }
                Section("Choose Tasks") {
                    ForEach(repository.tasks.filter { !$0.isCompleted && !repository.isTodayPriority($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { task in
                        Button { repository.toggleTodayPriority(task) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(task.title).foregroundStyle(.primary)
                                    Text(repository.lists.first { $0.id == task.listID }?.title ?? "Task").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                            }
                        }.disabled(repository.todayPriorityIDs.count >= 3)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query, prompt: "Search tasks")
            .navigationTitle("Today’s Priorities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct TodayOverduePlanner: View {
    @Bindable var repository: TaskRepository
    @State private var selected: Set<String> = []
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(selected.count == repository.overdueTasks.count ? "Clear Selection" : "Select All") { selected = selected.count == repository.overdueTasks.count ? [] : Set(repository.overdueTasks.map(\.id)) }
                    ForEach(repository.overdueTasks) { task in
                        Button { if selected.contains(task.id) { selected.remove(task.id) } else { selected.insert(task.id) } } label: {
                            HStack {
                                Image(systemName: selected.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(task.title).foregroundStyle(.primary)
                                    if let due = task.dueDate { Text(due.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.accessibilityAddTraits(selected.contains(task.id) ? .isSelected : [])
                    }
                }
                Section {
                    Button("Do Today", systemImage: "sun.max") { schedule(Calendar.current.startOfDay(for: Date())) }
                    Button("Tomorrow", systemImage: "arrow.turn.up.right") { schedule(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()) }
                    DatePicker("Pick Date", selection: $date, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    Button("Move to Selected Date", systemImage: "calendar") { schedule(date) }
                } header: { Text("Move Selected Tasks") } footer: { Text("Sets a due date without a specific time. Undo restores the original schedule.") }
                .disabled(selected.isEmpty || saving || repository.isUndoing)
                if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(saving)
            .navigationTitle("Plan Overdue Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func schedule(_ date: Date) {
        saving = true
        Task {
            await repository.setDueDate(date, hasDueTime: false, forTaskIDs: selected.intersection(Set(repository.overdueTasks.map(\.id))))
            saving = false
            if selected.isDisjoint(with: Set(repository.overdueTasks.map(\.id))) { dismiss() }
        }
    }
}

enum TodayDashboardSection: String, CaseIterable, Identifiable {
    case summary, focus, priorities, overdue, tasks, timeline, calendar, tomorrow, suggested, capture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: "Your Day"
        case .focus: "Focus Next"
        case .timeline: "Combined Timeline"
        case .priorities: "Top 3 Today"
        case .overdue: "Overdue"
        case .tasks: "Today’s Tasks"
        case .calendar: "Calendar"
        case .tomorrow: "Tomorrow"
        case .suggested: "Suggested"
        case .capture: "Inline Task Capture"
        }
    }
    static func normalized(_ raw: [String]) -> [Self] {
        var result: [Self] = []
        for value in raw {
            if let section = Self(rawValue: value), !result.contains(section) { result.append(section) }
        }
        result.append(contentsOf: allCases.filter { !result.contains($0) })
        return result
    }
}

struct TodaySectionsEditor: View {
    @Bindable var repository: TaskRepository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(repository.availableTodaySectionOrder) { section in
                        let visibility = Binding(get: { repository.visibleTodaySections.contains(section) }, set: { repository.setTodaySectionVisible(section, $0) })
                        let title = repository.todaySectionTitle(section)
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(title).fixedSize(horizontal: false, vertical: true)
                                Toggle(title, isOn: visibility).labelsHidden()
                            }
                        } else {
                            Toggle(title, isOn: visibility)
                        }
                    }.onMove { repository.moveTodaySections(fromOffsets: $0, toOffset: $1) }
                } footer: { Text("Choose sections to show and drag to reorder. Quick Capture, Undo, and permission messages remain available.") }
                if !repository.lists.isEmpty {
                    Section {
                        ForEach(repository.lists) { list in
                            Toggle(isOn: Binding(get: { repository.isFocusNextList(list.id) }, set: { repository.setFocusNextList(list.id, included: $0) })) {
                                Label(list.title, systemImage: repository.listIcon(for: list.id)).foregroundStyle(list.color)
                            }
                        }
                    } header: { Text("Focus Next Lists") } footer: {
                        Text("Focus Next suggests tasks only from these lists. Shopping and Reading & Watch Later lists start turned off.")
                    }
                }
                Section { Button("Restore Default Layout", systemImage: "arrow.counterclockwise") { repository.resetTodaySections() } }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct WatchShowTracker: View {
    @Bindable var repository: TaskRepository
    let taskID: String
    @State private var results: [ReadingMedia.ShowArtwork] = []
    @State private var query = ""
    @State private var loading = false
    @State private var message: String?
    @State private var seasonVisibility: [Int: Bool] = [:]
    @State private var replacement: ReadingMedia.ShowArtwork?
    @Environment(\.dismiss) private var dismiss
    private var task: TaskItem? { repository.tasks.first { $0.id == taskID } }
    private var catalog: ReadingMedia.ShowTracking? { task.flatMap { ReadingMedia.tracking(repository.specializedDetails($0).fields) } }
    var body: some View {
        NavigationStack {
            List {
                if let task, let catalog {
                    Section {
                        Text(catalog.show.name).font(.title2.bold())
                        let progress = task.isCompleted ? "Finished" : repository.specializedDetails(task).fields["Progress"] == "Dropped" ? "Dropped" : catalog.progress()
                        LabeledContent("Progress", value: progress == "In Progress" ? "Watching" : progress)
                        LabeledContent("Known Seasons", value: String(Set(catalog.episodes.map(\.season)).count))
                        Text("\(catalog.watched.intersection(Set(catalog.episodes.map(\.id))).count) of \(catalog.episodes.count) known episodes watched").font(.caption)
                        if let next = catalog.next() {
                            LabeledContent("Next Episode", value: next.label)
                            EpisodeProgressActions(repository: repository, taskID: taskID)
                        } else if let next = catalog.upcoming(), let date = next.release {
                            Text("Next release: " + next.label + " · " + date.formatted(date: .abbreviated, time: .omitted))
                        } else { Text("Next release date unknown").foregroundStyle(.secondary) }
                        if catalog.next() == nil { EpisodeProgressActions(repository: repository, taskID: taskID) }
                        Button("Refresh Show Information", systemImage: "arrow.clockwise") { match(catalog.show) }.disabled(loading)
                    }
                    ForEach(Array(Set(catalog.episodes.map(\.season))).sorted { left, right in
                        let current = (catalog.next() ?? catalog.upcoming())?.season ?? catalog.ordered.last?.season
                        if left == current { return right != current }
                        if right == current { return false }
                        return left < right
                    }, id: \.self) { season in
                        Section {
                            DisclosureGroup("Season \(season)", isExpanded: Binding(get: {
                                seasonVisibility[season] ?? (season == ((catalog.next() ?? catalog.upcoming())?.season ?? catalog.ordered.last?.season))
                            }, set: { seasonVisibility[season] = $0 })) {
                            Button("Mark Released Season \(season) Episodes Watched", systemImage: "checkmark.circle.fill") { mark(Set(catalog.episodes.filter { $0.season == season }.map(\.id)), watched: true) }
                            ForEach(catalog.ordered.filter { $0.season == season }) { episode in
                                let watched = catalog.watched.contains(episode.id)
                                let released = episode.release.map { $0 <= Date() } == true
                                HStack(alignment: .top) {
                                    Button { mark([episode.id], watched: !watched) } label: { Image(systemName: watched ? "checkmark.circle.fill" : "circle").frame(minWidth: 44, minHeight: 44) }
                                        .buttonStyle(.borderless).disabled(!watched && !released).accessibilityLabel((watched ? "Unwatch " : "Mark watched ") + episode.label)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(episode.label).fontWeight(.semibold)
                                        Text([episode.runtime.map { "\($0) min" }, episode.airdate].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        if episode.release == nil { Text("Release date unknown").font(.caption).foregroundStyle(.secondary) }
                                        DisclosureGroup("Episode details · spoilers") { Text(episode.name); Text(ReadingMedia.plainSummary(episode.summary)) }
                                    }
                                }
                            }
                            }
                        }
                    }
                    Section {
                        DisclosureGroup("About the Show") {
                        Text([catalog.show.premiered.map { String($0.prefix(4)) }, catalog.show.status, catalog.show.averageRuntime.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                        if let genres = catalog.show.genres { Text(genres.joined(separator: ", ")).font(.subheadline) }
                        Text(ReadingMedia.plainSummary(catalog.show.summary)).font(.subheadline)
                        if !catalog.cast.isEmpty { LabeledContent("Cast", value: catalog.cast.joined(separator: ", ")) }
                        }
                    }
                    Section {
                        Toggle("Release-day Notifications", isOn: Binding(get: { repository.specializedDetails(task).fields["Episode Alerts"] == "true" }, set: { enabled in
                            Task {
                                if enabled { await repository.requestNotificationAccess() }
                                guard let latest = repository.tasks.first(where: { $0.id == taskID }) else { return }
                                var details = repository.specializedDetails(latest)
                                details.fields["Episode Alerts"] = enabled && repository.notificationStatus == .granted ? "true" : "false"
                                _ = await repository.saveSpecializedDetails(details, for: latest, type: .reading)
                            }
                        }))
                        if repository.specializedDetails(task).fields["Episode Alerts"] == "true" {
                            DatePicker("Release-day Time", selection: Binding(get: {
                                let fields = repository.specializedDetails(task).fields
                                return Calendar.current.date(bySettingHour: Int(fields["Episode Alert Hour"] ?? "9") ?? 9, minute: Int(fields["Episode Alert Minute"] ?? "0") ?? 0, second: 0, of: Date()) ?? Date()
                            }, set: { date in
                                updateAlert("Episode Alert Hour", String(Calendar.current.component(.hour, from: date)))
                                updateAlert("Episode Alert Minute", String(Calendar.current.component(.minute, from: date)))
                            }), displayedComponents: .hourAndMinute)
                            Picker("Advance Reminder", selection: alertBinding("Episode Alert Advance", fallback: "0")) {
                                Text("Release day only").tag("0")
                                Text("15 minutes before airing").tag("15")
                                Text("30 minutes before airing").tag("30")
                                Text("1 hour before airing").tag("60")
                            }
                            Toggle("Play Sound", isOn: Binding(get: { repository.specializedDetails(task).fields["Episode Alert Sound"] != "false" }, set: { updateAlert("Episode Alert Sound", $0 ? "true" : "false") }))
                        }
                        if repository.notificationStatus == .denied { Text("Notifications are disabled. Enable them in system Settings.").foregroundStyle(.secondary) }
                    } footer: { Text("Alerts use your chosen time, once per show per day. Advance reminders require an exact air time; otherwise your release-day time is used. A full-season release uses one alert. Dates come from TVmaze and do not confirm availability on your streaming service. iOS may refresh schedules in the background; unknown dates cannot generate alerts.") }
                }
                Section {
                    TextField("Show title", text: $query).onSubmit { search() }
                    Button(catalog == nil ? "Find & Match Show" : "Find a Different Show", systemImage: "magnifyingglass") { search() }.disabled(loading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(results) { show in
                        Button {
                            if let current = catalog, current.show.id != show.id { replacement = show } else { match(show) }
                        } label: {
                            HStack {
                                CachedMediaPreview(rawURL: show.thumbnail?.absoluteString, format: "TV Show")
                                VStack(alignment: .leading) {
                                    Text(show.name).foregroundStyle(.primary)
                                    Text([show.premiered.map { String($0.prefix(4)) }, show.webChannel?.name ?? show.network?.name].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(loading)
                    }
                } footer: { Text("Search sends this title to TVmaze. Select the correct release to confirm the match and download its show and episode information. Replacing the show resets episode progress; Undo restores it.") }
                if loading { ProgressView("Loading show information…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                if let undo = repository.taskUndo { Button("Undo " + undo.message, systemImage: "arrow.uturn.backward") { Task { await repository.undoLastTaskAction() } }.disabled(repository.isUndoing) }
                if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
                Section { Link("Show data: TVmaze · CC BY-SA", destination: URL(string: "https://www.tvmaze.com/api#licensing")!) }
            }
            .disabled(repository.isUndoing)
            .navigationTitle("Show & Episodes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { query = task?.title ?? "" }
            .alert("Replace matched show?", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
                Button("Replace") { if let show = replacement { match(show) }; replacement = nil }
                Button("Cancel", role: .cancel) { replacement = nil }
            } message: { Text("Episode checkmarks belong to the matched show. Your saved links and personal notes will be retained.") }
        }
    }
    private func search() {
        loading = true; message = nil
        Task { defer { loading = false }; do { results = try await ReadingMedia.catalogSearch(title: query); if results.isEmpty { message = "No shows found. Try a different title." } } catch { message = "Unable to search. Please try again." } }
    }
    private func match(_ show: ReadingMedia.ShowArtwork) {
        loading = true
        Task { defer { loading = false }; if await repository.matchWatchShow(show.id, taskID: taskID) { results = [] } }
    }
    private func alertBinding(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: { repository.tasks.first(where: { $0.id == taskID }).map { repository.specializedDetails($0).fields[key] ?? fallback } ?? fallback }, set: { updateAlert(key, $0) })
    }
    private func updateAlert(_ key: String, _ value: String) {
        Task {
            guard let latest = repository.tasks.first(where: { $0.id == taskID }) else { return }
            var details = repository.specializedDetails(latest)
            details.fields[key] = value
            _ = await repository.saveSpecializedDetails(details, for: latest, type: .reading)
        }
    }
    private func mark(_ ids: Set<Int>, watched: Bool) { Task { await repository.setWatchedEpisodes(ids, watched: watched, taskID: taskID) } }
}

struct UpcomingWatchReleases: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @State private var days = 30
    @State private var allLists = false
    @State private var now = Date()
    @State private var showID: String?
    @State private var eventDraft: EventDraft?
    @State private var refreshMessage: String?
    private var sources: [ReadingMedia.EpisodeFeedSource] {
        repository.tasks.filter { !$0.isCompleted && $0.parentID == nil && (allLists || $0.listID == listID) && repository.listProfile($0.listID).type == .reading }.map {
            .init(taskID: $0.id, title: $0.title, fields: repository.specializedDetails($0).fields)
        }
    }
    private var releases: [ReadingMedia.EpisodeFeedItem] {
        ReadingMedia.episodeFeed(sources, mode: .comingSoon, now: now).filter {
            days == 0 || $0.release < Calendar.current.date(byAdding: .day, value: days, to: now)!
        }
    }
    private var unknown: [ReadingMedia.EpisodeFeedSource] {
        var seen = Set<Int>()
        return sources.filter {
            guard !["Dropped", "Finished"].contains($0.fields["Progress"] ?? ""), $0.fields["Merged Into"] == nil, let show = ReadingMedia.tracking($0.fields), show.show.status != "Ended", show.upcoming(now: now) == nil else { return false }
            return seen.insert(show.show.id).inserted
        }
    }
    var body: some View {
            List {
                Section {
                    Picker("Show Releases", selection: $days) { Text("7 Days").tag(7); Text("30 Days").tag(30); Text("All Dates").tag(0) }
                    Toggle("Include All Read/Watch Lists", isOn: $allLists)
                } footer: { Text("Scheduled release dates from your matched shows. Availability on your saved streaming service may differ. Pull to refresh your saved schedules.") }
                if let refreshMessage { Text(refreshMessage).font(.caption).foregroundStyle(.secondary) }
                let groups = Dictionary(grouping: releases, by: { Calendar.current.startOfDay(for: $0.release) })
                ForEach(groups.keys.sorted(), id: \.self) { day in
                    Section {
                        ForEach(groups[day] ?? []) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { showID = item.taskID } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        CachedMediaPreview(rawURL: item.fields["Thumbnail URL"], format: "TV Show", localPreview: item.fields["Local Preview"])
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                            Text(item.episode.label + (item.episode.runtime.map { " · \($0) min" } ?? "")).font(.subheadline)
                                            if item.episode.airstamp != nil {
                                                Text(item.release, style: .time).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if let provider = item.fields["Saved From"] { Text("Saved from " + provider).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }.buttonStyle(.plain)
                                if !repository.canCreateEvents {
                                    EmptyView()
                                } else if repository.calendarEvents.contains(where: { ReadingMedia.hasEpisodeCalendarLink(notes: $0.notes, episodeID: item.episode.id) }) {
                                    Label("Linked to Calendar", systemImage: "calendar.badge.checkmark").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("Add Release to Calendar", systemImage: "calendar.badge.plus") { addToCalendar(item) }.font(.subheadline).buttonStyle(.borderless)
                                }
                            }
                        }
                    } header: { Text(day.formatted(date: .complete, time: .omitted)) }
                }
                if releases.isEmpty {
                    Section {
                        ContentUnavailableView("No Upcoming Episodes", systemImage: "calendar", description: Text("No known dates match this view. Try All Dates or match a show from its Watch Later card."))
                    }
                }
                if !unknown.isEmpty {
                    Section {
                        ForEach(unknown, id: \.taskID) { item in
                            Button { showID = item.taskID } label: { VStack(alignment: .leading) { Text(item.title); Text("Next release date unknown").font(.caption).foregroundStyle(.secondary) } }
                        }
                    } header: { Text("Dates Unannounced") }
                }
                Section { Link("Schedule data: TVmaze · CC BY-SA", destination: URL(string: "https://www.tvmaze.com/api#licensing")!) }
            }
            .navigationTitle("Upcoming Episodes").navigationBarTitleDisplayMode(.inline)
            .refreshable { let success = await repository.refreshWatchReleaseSchedules(); refreshMessage = success ? "Schedules refreshed" : "Some schedules could not be refreshed. Showing saved information."; now = Date() }
            .sheet(isPresented: Binding(get: { showID != nil }, set: { if !$0 { showID = nil } })) { if let showID { WatchShowTracker(repository: repository, taskID: showID) } }
            .sheet(item: $eventDraft) { draft in CalendarEventEditorView(repository: repository, draft: draft) }
            .task { while !Task.isCancelled { now = Date(); do { try await Task.sleep(for: .seconds(60)) } catch { return } } }
    }
    private func addToCalendar(_ item: ReadingMedia.EpisodeFeedItem) {
        var draft = repository.makeEventDraft()
        draft.title = item.title + " · " + item.episode.label + " Release"
        draft.startDate = item.release
        draft.isAllDay = item.episode.airstamp == nil
        // EventDraft stores the inclusive final day; EventKit adds the exclusive day.
        draft.endDate = draft.isAllDay ? draft.startDate : draft.startDate.addingTimeInterval(30 * 60)
        draft.notes = "Scheduled release from TVmaze. Check your streaming service for availability.\nTaskFlow episode: \(item.episode.id)"
        draft.notes += "\n" + TaskFlowDeepLink.taskURL(item.taskID).absoluteString
        eventDraft = draft
    }
}



struct EpisodeProgressActions: View {
    @Bindable var repository: TaskRepository
    let taskID: String
    var compact = false
    @State private var busy = false
    @State private var seasonEnded = false
    @State private var choosingPosition = false
    @State private var catchUp = false
    @State private var undoID: UUID?
    @State private var lastWatched: String?
    private var task: TaskItem? { repository.tasks.first { $0.id == taskID } }
    private var catalog: ReadingMedia.ShowTracking? { task.flatMap { ReadingMedia.tracking(repository.specializedDetails($0).fields) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let next = catalog?.next() {
                Button {
                    guard !busy else { return }
                    busy = true
                    Task {
                        let success = await repository.setWatchedEpisodes([next.id], watched: true, taskID: taskID)
                        if success {
                            undoID = repository.taskUndo?.id
                            lastWatched = next.label
                            seasonEnded = !(catalog?.ordered.contains { $0.season == next.season && !(catalog?.watched.contains($0.id) ?? false) } ?? true)
                        }
                        busy = false
                    }
                } label: {
                    Label("Mark " + next.label + " Watched", systemImage: "checkmark.circle")
                        .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }.buttonStyle(.borderedProminent).controlSize(.regular)
                .accessibilityLabel("Mark season \(next.season), episode \(next.number.map(String.init) ?? "Special") watched")
            }
            if let lastWatched, repository.taskUndo?.id == undoID {
                HStack {
                    Text(lastWatched + " marked watched").font(.caption).foregroundStyle(.secondary)
                    Button("Undo") {
                        busy = true
                        Task { await repository.undoLastTaskAction(); undoID = nil; self.lastWatched = nil; busy = false }
                    }.frame(minHeight: 44)
                }
            }
            if !compact {
            Menu {
                Button("Change Season / Episode") { catchUp = false; choosingPosition = true }
                Button("Watched Through…") { catchUp = true; choosingPosition = true }
                if undoID != nil, repository.taskUndo?.id == undoID {
                    Button("Undo Episode Change", systemImage: "arrow.uturn.backward") {
                        busy = true
                        Task { await repository.undoLastTaskAction(); undoID = nil; busy = false }
                    }
                }
            } label: {
                Label(compact ? "Adjust Progress" : "Episode Progress", systemImage: "slider.horizontal.3")
                    .font(compact ? .caption : .body)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(busy || repository.isUndoing)
        .confirmationDialog("Season complete. What next?", isPresented: $seasonEnded, titleVisibility: .visible) {
            if let catalog, let next = catalog.ordered.first(where: { !catalog.watched.contains($0.id) }) {
                Button("Start Season \(next.season)") { setStatus("In Progress") }
            }
            Button("Wait for More Episodes") { setStatus("Caught Up") }
            Button("Mark Series Finished") { setStatus("Finished") }
            Button("Decide Later", role: .cancel) {}
        }
        .sheet(isPresented: $choosingPosition) {
            NavigationStack {
                List {
                    Text(catchUp ? "Mark released episodes through your selection as watched." : "Choose your next episode. Progress after that point will be cleared.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let catalog {
                        ForEach(Array(Set(catalog.episodes.map(\.season))).sorted(), id: \.self) { season in
                            Section("Season \(season)") {
                                ForEach(catalog.ordered.filter { $0.season == season }) { episode in
                                    Button(episode.label) {
                                        guard !busy else { return }
                                        busy = true
                                        Task {
                                            if await repository.setEpisodePosition(episode.id, catchUp: catchUp, taskID: taskID) {
                                                undoID = repository.taskUndo?.id
                                                choosingPosition = false
                                            }
                                            busy = false
                                        }
                                    }.disabled(busy || (catchUp && episode.release.map { $0 <= Date() } != true))
                                }
                            }
                        }
                    }
                }
                .navigationTitle(catchUp ? "Watched Through" : "Next Episode")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingPosition = false } } }
            }
        }
    }
    private func setStatus(_ status: String) {
        guard !busy else { return }
        busy = true
        Task {
            if let task {
                var details = repository.specializedDetails(task)
                details.fields["Progress"] = status
                if await repository.saveSpecializedDetails(details, for: task, type: .reading) { undoID = repository.taskUndo?.id }
            }
            busy = false
        }
    }
}


// MARK: - Receipt scanning

/// Reads a store receipt (camera or photo), matches its lines to this list's items, and saves
/// the per-unit prices after the user reviews them. Text recognition runs on the device.
struct ReceiptScanSheet: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.choose
    @State private var showingCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var lines: [ReceiptLine] = []
    @State private var matches: [String: ReceiptLine] = [:]
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var message: String?

    private enum Phase { case choose, reading, review }

    private var items: [TaskItem] {
        repository.tasks.filter { $0.listID == listID && $0.parentID == nil }
    }

    /// Receipt lines are usually the line total; divide by a numeric quantity for the per-unit price.
    private func unitPrice(_ task: TaskItem, _ line: ReceiptLine) -> Double {
        let quantity = ShoppingQuantity.value(repository.specializedDetails(task).fields["Quantity"]) ?? 1
        return quantity > 0 ? line.price / quantity : line.price
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .choose:
                    Section {
                        Button("Scan Receipt", systemImage: "doc.viewfinder") { showingCamera = true }
                            .disabled(!VNDocumentCameraViewController.isSupported)
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Choose Receipt Photo", systemImage: "photo")
                        }
                    } footer: {
                        Text("TaskFlow reads the receipt on this device, matches lines to items in this list, and lets you review prices before saving. Prices are remembered for next time.")
                    }
                    if let message { Section { Text(message).foregroundStyle(.secondary) } }
                case .reading:
                    Section { ProgressView("Reading receipt…").frame(maxWidth: .infinity) }
                case .review:
                    if matches.isEmpty {
                        ContentUnavailableView("No Matching Items", systemImage: "doc.text.magnifyingglass",
                                               description: Text("None of this receipt’s lines matched items in this list. Try a clearer photo."))
                        Button("Try Another Receipt") { reset() }
                    } else {
                        Section {
                            ForEach(items.filter { matches[$0.id] != nil }) { task in
                                if let line = matches[task.id] {
                                    Toggle(isOn: Binding(get: { selected.contains(task.id) }, set: { on in
                                        if on { selected.insert(task.id) } else { selected.remove(task.id) }
                                    })) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(task.title)
                                            Text(line.name).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .badge(Text(unitPrice(task, line), format: .currency(code: Locale.current.currency?.identifier ?? "USD")))
                                }
                            }
                        } header: { Text("Matched Items") } footer: { Text("Prices are per unit; a line for several items is divided by the item’s quantity.") }
                        let used = Set(matches.values)
                        let leftovers = lines.filter { !used.contains($0) }
                        if !leftovers.isEmpty {
                            Section("Other Receipt Lines") {
                                ForEach(Array(leftovers.enumerated()), id: \.offset) { _, line in
                                    LabeledContent(line.name, value: line.price, format: .number.precision(.fractionLength(2)))
                                }
                            }
                        }
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                if phase == .review, !matches.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save Prices") { save() }.disabled(saving || selected.isEmpty)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                DocumentCameraView { images in
                    showingCamera = false
                    read(images.compactMap(\.cgImage).map { ($0, CGImagePropertyOrientation.up) })
                } onCancel: { showingCamera = false }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let cgImage = image.cgImage else {
                        message = "That photo couldn’t be opened. Try another."
                        return
                    }
                    read([(cgImage, CGImagePropertyOrientation(image.imageOrientation))])
                }
            }
        }
    }

    private func reset() {
        phase = .choose
        lines = []; matches = [:]; selected = []; photoItem = nil
    }

    private func read(_ images: [(CGImage, CGImagePropertyOrientation)]) {
        guard !images.isEmpty else { return }
        phase = .reading
        Task {
            let rows = await Self.recognizeRows(images)
            let parsed = ReceiptParser.lines(from: rows)
            lines = parsed
            matches = ReceiptParser.match(items: items.map { (id: $0.id, title: $0.title) }, lines: parsed)
            selected = Set(matches.keys)
            phase = .review
        }
    }

    private func save() {
        saving = true
        var prices: [String: Double] = [:]
        for task in items where selected.contains(task.id) {
            if let line = matches[task.id] { prices[task.id] = unitPrice(task, line) }
        }
        Task {
            _ = await repository.applyReceiptPrices(prices)
            saving = false
            dismiss()
        }
    }

    /// Recognized text grouped into printed rows (item names and prices are separate text blocks
    /// at the same height), top to bottom, left to right.
    nonisolated static func recognizeRows(_ images: [(CGImage, CGImagePropertyOrientation)]) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var rows: [String] = []
                for (image, orientation) in images {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
                    let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    var current: [VNRecognizedTextObservation] = []
                    var rowY: CGFloat = -1
                    func flush() {
                        let text = current.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        if !text.isEmpty { rows.append(text) }
                        current = []
                    }
                    for observation in observations {
                        let tolerance = max(0.006, observation.boundingBox.height * 0.5)
                        if rowY >= 0, abs(observation.boundingBox.midY - rowY) > tolerance { flush() }
                        if current.isEmpty { rowY = observation.boundingBox.midY }
                        current.append(observation)
                    }
                    flush()
                }
                continuation.resume(returning: rows)
            }
        }
    }
}

/// Apple's document scanner, which crops and straightens receipts automatically.
struct DocumentCameraView: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void
        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) { self.onScan = onScan; self.onCancel = onCancel }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onCancel() }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
