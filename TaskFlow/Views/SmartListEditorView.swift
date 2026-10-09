import SwiftUI

struct SmartListEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    @State private var smartList: SmartListDefinition
    @State private var showsDeleteConfirmation = false

    init(repository: TaskRepository, smartList: SmartListDefinition) {
        self.repository = repository
        _smartList = State(initialValue: smartList)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Smart List") {
                    TextField("Name", text: $smartList.title)
                    Toggle("Flagged only", isOn: $smartList.flaggedOnly)
                    Toggle("Blocked by dependencies", isOn: $smartList.blockedOnly)
                    Toggle("Include completed", isOn: $smartList.includeCompleted)
                }

                Section("Icon") {
                    SmartListIconPicker(selection: $smartList.icon)
                }

                Section("Rules") {
                    Picker("Match", selection: $smartList.matchMode) {
                        ForEach(SmartListMatchMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    ForEach($smartList.rules) { $rule in
                        HStack {
                            Picker("Field", selection: $rule.field) {
                                ForEach(SmartTaskFilterRule.Field.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .onChange(of: rule.field) { _, field in
                                if let first = values(for: field).first { rule.value = first }
                            }
                            Picker("Value", selection: $rule.value) {
                                ForEach(values(for: rule.field), id: \.self) { value in
                                    Text(displayValue(value, field: rule.field)).tag(value)
                                }
                            }
                        }
                    }
                    .onDelete { smartList.rules.remove(atOffsets: $0) }
                    Button("Add Rule", systemImage: "plus") {
                        smartList.rules.append(SmartTaskFilterRule())
                    }
                    Text("Combine rules with AND or OR. Relative due dates update automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Filters") {
                    Picker("Status", selection: optionalStatusBinding) {
                        Text("Any").tag(TaskStatus?.none)
                        ForEach(TaskStatus.allCases) { status in
                            Text(status.rawValue).tag(TaskStatus?.some(status))
                        }
                    }

                    Picker("Priority", selection: optionalPriorityBinding) {
                        Text("Any").tag(TaskPriority?.none)
                        ForEach(TaskPriority.allCases) { priority in
                            Text(priority.rawValue).tag(TaskPriority?.some(priority))
                        }
                    }

                    Picker("Date Range", selection: optionalDateRangeBinding) {
                        Text("Any").tag(SmartDateRange?.none)
                        ForEach(SmartDateRange.allCases) { range in
                            Text(range.rawValue).tag(SmartDateRange?.some(range))
                        }
                    }

                    Picker("List", selection: optionalListBinding) {
                        Text("Any").tag(String?.none)
                        ForEach(repository.lists) { list in
                            Text(list.title).tag(String?.some(list.id))
                        }
                    }

                    Picker("Tag", selection: optionalTagBinding) {
                        Text("Any").tag(String?.none)
                        ForEach(repository.allTags, id: \.self) { tag in
                            Text(tag).tag(String?.some(tag))
                        }
                    }
                }
                if repository.smartLists.contains(where: { $0.id == smartList.id }) {
                    Section {
                        Button("Delete Smart List", role: .destructive) { showsDeleteConfirmation = true }
                    }
                }
            }
            .confirmationDialog("Delete this smart list?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Smart List", role: .destructive) {
                    repository.deleteSmartList(smartList)
                    dismiss()
                }
            } message: {
                Text("This removes the saved view. Your tasks and reminder lists will remain.")
            }
            .taskFlowThemedBackground()
            .navigationTitle("Smart List")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        repository.saveSmartList(smartList)
                        dismiss()
                    }
                    .disabled(smartList.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func values(for field: SmartTaskFilterRule.Field) -> [String] {
        switch field {
        case .status: TaskStatus.editableCases.map(\.rawValue)
        case .priority: TaskPriority.allCases.map(\.rawValue)
        case .due: ["Overdue", "Today", "Tomorrow", "Next 7 days", "Next 14 days", "Next 30 days", "No date"]
        case .tag: repository.allTags.isEmpty ? ["Untagged"] : repository.allTags
        case .list: repository.lists.map(\.id)
        }
    }

    private func displayValue(_ value: String, field: SmartTaskFilterRule.Field) -> String {
        if field == .list { return repository.lists.first(where: { $0.id == value })?.title ?? value }
        return value
    }

    private var optionalStatusBinding: Binding<TaskStatus?> {
        Binding(get: { smartList.status }, set: { smartList.status = $0 })
    }

    private var optionalPriorityBinding: Binding<TaskPriority?> {
        Binding(get: { smartList.priority }, set: { smartList.priority = $0 })
    }

    private var optionalDateRangeBinding: Binding<SmartDateRange?> {
        Binding(get: { smartList.dateRange }, set: { smartList.dateRange = $0 })
    }

    private var optionalListBinding: Binding<String?> {
        Binding(get: { smartList.listID }, set: { smartList.listID = $0 })
    }

    private var optionalTagBinding: Binding<String?> {
        Binding(get: { smartList.requiredTag }, set: { smartList.requiredTag = $0 })
    }
}

private struct SmartListIconPicker: View {
    @Binding var selection: String

    private let columns = [
        GridItem(.adaptive(minimum: 44), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Self.icons, id: \.self) { icon in
                Button {
                    selection = icon
                } label: {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(selection == icon ? Color.white : Color.purple)
                        .frame(width: 44, height: 44)
                        .background(iconBackground(for: icon), in: RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon.accessibilityTitle)
                .accessibilityAddTraits(selection == icon ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func iconBackground(for icon: String) -> some ShapeStyle {
        selection == icon ? AnyShapeStyle(Color.purple) : AnyShapeStyle(Color.purple.opacity(0.14))
    }

    private static let icons = [
        SmartListDefinition.defaultIcon,
        "sparkles",
        "star.fill",
        "flag.fill",
        "exclamationmark.triangle.fill",
        "bolt.fill",
        "flame.fill",
        "calendar",
        "clock.fill",
        "timer",
        "checkmark.circle.fill",
        "circle.grid.2x2.fill",
        "tray.full.fill",
        "tag.fill",
        "folder.fill",
        "pin.fill",
        "scope",
        "target",
        "brain.head.profile",
        "lightbulb.fill",
        "person.2.fill",
        "house.fill",
        "briefcase.fill",
        "heart.fill"
    ]
}

private extension String {
    var accessibilityTitle: String {
        split(separator: ".")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
