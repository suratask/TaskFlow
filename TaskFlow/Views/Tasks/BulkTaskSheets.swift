import ActivityKit
import Combine
import EventKit
import EventKitUI
import MapKit
import SwiftUI
import TipKit
#if canImport(UIKit)
import UIKit
#endif

enum BulkTagOperation: String, CaseIterable, Identifiable {
    case add = "Add"
    case remove = "Remove"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .add: "tag.fill"
        case .remove: "tag.slash.fill"
        }
    }
}

struct BulkRescheduleTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selectedCount: Int
    let onApply: (Date?, Bool?) -> Void
    @State private var dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var includeTime = false

    init(selectedCount: Int, initialTask: TaskItem? = nil, onApply: @escaping (Date?, Bool?) -> Void) {
        self.selectedCount = selectedCount
        self.onApply = onApply
        _dueDate = State(initialValue: initialTask?.dueDate ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
        _includeTime = State(initialValue: initialTask?.hasDueTime ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Due", selection: $dueDate, displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                    Toggle("Include time", isOn: $includeTime)
                } header: {
                    Text("Reschedule \(selectedCount) task\(selectedCount == 1 ? "" : "s")")
                }
                Section {
                    Button("Remove Due Date", role: .destructive) {
                        onApply(nil, nil)
                        dismiss()
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Set Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(dueDate, includeTime)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct BulkMoveTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let selectedCount: Int
    let onApply: (String) -> Void
    @State private var destinationID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Destination", selection: $destinationID) {
                        ForEach(repository.lists) { list in Text(list.title).tag(list.id) }
                    }
                } header: {
                    Text("Move \(selectedCount) task\(selectedCount == 1 ? "" : "s")")
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Move to List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onApply(destinationID)
                        dismiss()
                    }
                    .disabled(destinationID.isEmpty)
                }
            }
            .onAppear { destinationID = repository.lists.first?.id ?? "" }
        }
    }
}

struct BulkTaskTaggingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let selectedCount: Int
    let initialOperation: BulkTagOperation
    let onApply: (BulkTagOperation, [String]) -> Void
    @State private var operation: BulkTagOperation = .add
    @State private var selectedTags = Set<String>()
    @State private var newTagText = ""

    init(
        repository: TaskRepository,
        selectedCount: Int,
        initialOperation: BulkTagOperation,
        onApply: @escaping (BulkTagOperation, [String]) -> Void
    ) {
        self.repository = repository
        self.selectedCount = selectedCount
        self.initialOperation = initialOperation
        self.onApply = onApply
        _operation = State(initialValue: initialOperation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("\(selectedCount) task\(selectedCount == 1 ? "" : "s") selected", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.indigo)
                }

                Section("Operation") {
                    Picker("Operation", selection: $operation) {
                        ForEach(BulkTagOperation.allCases) { operation in
                            Label(operation.rawValue, systemImage: operation.icon).tag(operation)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if operation == .add {
                    Section("Add Tag") {
                        HStack {
                            TextField("New tag", text: $newTagText)
                                .textInputAutocapitalization(.words)

                            Button {
                                addTypedTag()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if !repository.allTags.isEmpty {
                    Section("Saved Tags") {
                        ForEach(repository.allTags, id: \.self) { tag in
                            Button {
                                toggle(tag)
                            } label: {
                                HStack {
                                    Label(tag, systemImage: selectedTags.contains(tag) ? "checkmark.circle.fill" : "tag")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Circle()
                                        .fill(repository.color(forTag: tag))
                                        .frame(width: 12, height: 12)
                                }
                            }
                        }
                    }
                }

                if !selectedTags.isEmpty {
                    Section(operation == .add ? "Will Apply" : "Will Remove") {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(selectedTags).sorted(), id: \.self) { tag in
                                HStack(spacing: 6) {
                                    Text("#\(tag)")
                                    Image(systemName: "xmark.circle.fill")
                                        .imageScale(.small)
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(repository.color(forTag: tag))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(repository.color(forTag: tag).opacity(0.16), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
                                .onTapGesture {
                                    selectedTags.remove(tag)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .taskFlowThemedBackground()
            .navigationTitle("Bulk Tag Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(operation == .add ? "Apply" : "Remove") {
                        onApply(operation, tagsToApply)
                        dismiss()
                    }
                    .disabled(tagsToApply.isEmpty)
                }
            }
        }
    }

    private func toggle(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func addTypedTag() {
        let normalized = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        selectedTags.insert(normalized)
        newTagText = ""
    }

    private var tagsToApply: [String] {
        var tags = Array(selectedTags)
        let typed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation == .add && !typed.isEmpty {
            tags.append(typed)
        }
        return tags
    }
}
