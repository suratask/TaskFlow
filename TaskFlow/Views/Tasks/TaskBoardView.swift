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

struct TaskBoardView: View {
    @Bindable var repository: TaskRepository
    let listColor: (String) -> Color
    @State private var targetedStatus: TaskStatus?
    private let columns = TaskStatus.allCases

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns, id: \.rawValue) { status in
                        let tasks = repository.rootTasks.filter { $0.status == status }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(status.rawValue).font(.headline)
                                Spacer()
                                Text(tasks.count, format: .number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ScrollView {
                                LazyVStack(spacing: 10) {
                                    ForEach(tasks) { task in
                                        TaskBoardCard(task: task, accent: listColor(task.listID),
                                                      listTitle: repository.lists.first { $0.id == task.listID }?.title ?? "Tasks",
                                                      listIcon: repository.listIcon(for: task.listID)) {
                                            repository.selectedTaskID = task.id
                                        }
                                        .draggable(task.id)
                                        .contextMenu {
                                            Menu("Move to", systemImage: "rectangle.split.3x1") {
                                                ForEach(TaskStatus.editableCases, id: \.rawValue) { destination in
                                                    Button(destination.rawValue) { Task { await repository.setStatus(destination, for: task) } }
                                                        .disabled(destination == status)
                                                }
                                            }
                                        }
                                    }
                                    if tasks.isEmpty {
                                        Text(status == .overdue ? "No overdue tasks" : "Drop a task here").font(.subheadline).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, minHeight: 80)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(width: min(320, max(260, geometry.size.width - 48)))
                        .frame(height: max(200, geometry.size.height - 24))
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius))
                        .overlay { RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius).stroke(targetedStatus == status ? repository.appTheme.primary : .clear, lineWidth: 2) }
                        .dropDestination(for: String.self) { ids, _ in
                            guard status != .overdue else { return false }
                            let matches = repository.tasks.filter { ids.contains($0.id) }
                            guard !matches.isEmpty else { return false }
                            Task { for task in matches { await repository.setStatus(status, for: task) } }
                            return true
                        } isTargeted: { targeted in
                            if targeted { targetedStatus = status } else if targetedStatus == status { targetedStatus = nil }
                        }
                    }
                }
                .padding(12)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .background(TaskFlowBackground(accent: repository.appTheme.primary))
    }
}

struct TaskBoardCard: View {
    let task: TaskItem
    let accent: Color
    let listTitle: String
    let listIcon: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                Label(listTitle, systemImage: listIcon)
                    .font(.caption.weight(.medium)).foregroundStyle(accent).lineLimit(1)
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let due = task.dueDate {
                    Text(due.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted))
                        .font(.caption)
                        .foregroundStyle(TaskFlowTheme.dueColor(isOverdue: task.isOverdue()))
                }
                if !task.tags.isEmpty {
                    Text(task.tags.prefix(2).map { "#" + $0 }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
    }
}
