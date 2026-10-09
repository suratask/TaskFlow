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

struct TaskRowView: View {
    let task: TaskItem
    let subtasks: [TaskItem]
    let isSelected: Bool
    var isBulkTagging = false
    let listColor: Color
    let tagColor: (String) -> Color
    let density: TaskRepository.TaskDensity
    var usesGroupedListStyle = false
    @Bindable var repository: TaskRepository
    var onOpen: (() -> Void)?
    @State private var isCompleting = false
    @State private var choosingDependencies = false
    @State private var rescheduling = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                if isBulkTagging { onOpen?(); return }
                isCompleting = true
                Task {
                    defer { isCompleting = false }
                    await repository.toggleCompletion(for: task)
                }
            } label: {
                checkmarkImage
                    .font(.title2)
                    .frame(width: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isCompleting)
            .accessibilityLabel(isBulkTagging ? "Select \(task.title)" : "Mark \(task.title) \(task.isCompleted ? "incomplete" : "complete")")

            Button {
                if let onOpen { onOpen() } else { repository.selectedTaskID = task.id }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if task.priority == .high {
                            Text("!!!").foregroundStyle(listColor).accessibilityLabel("High priority")
                        }
                        Text(task.title)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if task.isFlagged {
                            Image(systemName: "flag.fill").font(.footnote).foregroundStyle(.orange).accessibilityLabel("Flagged")
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { dueLabel; listLabel }
                        VStack(alignment: .leading, spacing: 2) { dueLabel; listLabel }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    if let waiting = repository.waitingOnDescription(task) {
                        Label(waiting, systemImage: "hourglass")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if (density == .detailed || repository.quickTagFilter != nil) && !task.tags.isEmpty {
                        FlowLayout(spacing: 5) {
                            ForEach(Array(task.tags.prefix(3)), id: \.self) { tag in TaskTagChip(name: tag, color: tagColor(tag)) }
                            if task.tags.count > 3 { Text("+\(task.tags.count - 3)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.vertical, density == .compact ? 4 : 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityAction(named: task.isCompleted ? "Reopen task" : "Complete task") {
            Task { await repository.toggleCompletion(for: task) }
        }
        .accessibilityAction(named: task.isFlagged ? "Unflag task" : "Flag task") {
            Task { await repository.setFlagged(!task.isFlagged, for: task) }
        }
        .accessibilityAction(named: "Reschedule task") { rescheduling = true }
        .sheet(isPresented: $rescheduling) {
            BulkRescheduleTasksSheet(selectedCount: 1, initialTask: task) { date, hasTime in
                Task { await repository.setDueDate(date, hasDueTime: hasTime, forTaskIDs: [task.id]) }
            }
        }
        .sheet(isPresented: $choosingDependencies) {
            NavigationStack {
                DependencyTaskPicker(repository: repository, taskID: task.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingDependencies = false } } }
            }
        }
        .contextMenu {
            Button {
                Task { await repository.toggleCompletion(for: task) }
            } label: {
                Label(task.isCompleted ? "Mark Incomplete" : "Mark Complete", systemImage: task.isCompleted ? "circle" : "checkmark.circle")
            }
            Button {
                Task { await repository.setFlagged(!task.isFlagged, for: task) }
            } label: {
                Label(task.isFlagged ? "Unflag" : "Flag", systemImage: task.isFlagged ? "flag.slash" : "flag")
            }
            Button(repository.isTodayPriority(task) ? "Remove Today Priority" : "Add to Today Priorities", systemImage: "star") { repository.toggleTodayPriority(task) }
                .disabled(!repository.isTodayPriority(task) && repository.todayPriorityIDs.count >= 3)
            // Quick edits right in the menu; only "Custom Date…" needs a sheet.
            Menu("Due Date", systemImage: "calendar") {
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                Button("Today") { Task { await repository.setDueDate(today, for: task) } }
                Button("Tomorrow") { Task { await repository.setDueDate(calendar.date(byAdding: .day, value: 1, to: today), for: task) } }
                Button("Next Week") { Task { await repository.setDueDate(calendar.date(byAdding: .day, value: 7, to: today), for: task) } }
                if task.dueDate != nil { Button("No Date") { Task { await repository.setDueDate(nil, for: task) } } }
                Button("Custom Date…") { rescheduling = true }
            }
            Picker(selection: Binding(get: { task.priority }, set: { value in Task { await repository.setPriority(value, for: task) } })) {
                ForEach(TaskPriority.allCases) { Text($0.rawValue).tag($0) }
            } label: { Label("Priority", systemImage: "exclamationmark") }
            .pickerStyle(.menu)
            if !repository.allTags.isEmpty {
                Menu("Tags", systemImage: "number") {
                    ForEach(repository.allTags, id: \.self) { tag in
                        let hasTag = task.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
                        Button {
                            Task {
                                if hasTag { await repository.removeTags([tag], from: task) }
                                else { await repository.addTags([tag], to: task) }
                            }
                        } label: {
                            if hasTag { Label("#" + tag, systemImage: "checkmark") } else { Text("#" + tag) }
                        }
                    }
                }
            }
            if repository.lists.count > 1 {
                Menu("Move to List", systemImage: "folder") {
                    ForEach(repository.lists.filter { $0.id != task.listID }) { list in
                        Button(list.title) { Task { await repository.moveTasks(toListID: list.id, taskIDs: [task.id]) } }
                    }
                }
            }
            Button("Dependencies", systemImage: "arrow.triangle.branch") { choosingDependencies = true }
            Divider()
            Button(role: .destructive) {
                Task { await repository.deleteTask(task) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder private var checkmarkImage: some View {
        if isBulkTagging {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        } else {
            Image(systemName: task.isCompleted ? "largecircle.fill.circle" : "circle").contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: task.isCompleted)
                .foregroundStyle(task.isCompleted ? listColor : Color.secondary)
        }
    }

    @ViewBuilder private var dueLabel: some View {
        if let dueDate = task.dueDate {
            Text(dueDate.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted))
                .foregroundStyle(TaskFlowTheme.dueColor(isOverdue: task.isOverdue()))
        }
    }
    private var listLabel: some View {
        Label(repository.lists.first { $0.id == task.listID }?.title ?? "Tasks", systemImage: repository.listIcon(for: task.listID))
            .foregroundStyle(listColor).lineLimit(1)
    }
}
