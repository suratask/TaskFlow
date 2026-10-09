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

/// Standard toolbar filter menu, in the style of Mail and Files.
struct TaskFilterMenu: View {
    @Bindable var repository: TaskRepository

    var body: some View {
        Menu {
            Picker("Status", selection: $repository.quickStatusFilter) {
                Text("Any Status").tag(Optional<TaskStatus>.none)
                ForEach(TaskStatus.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Picker("Priority", selection: $repository.quickPriorityFilter) {
                Text("Any Priority").tag(Optional<TaskPriority>.none)
                ForEach(TaskPriority.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Picker("Due", selection: $repository.quickDueFilter) {
                ForEach(TaskRepository.DueFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Tag", selection: $repository.quickTagFilter) {
                Text("Any Tag").tag(Optional<TaskRepository.TagFilter>.none)
                Text("No Tags").tag(Optional(TaskRepository.TagFilter.noTags))
                ForEach(repository.allTags, id: \.self) { Text("#\($0)").tag(Optional(TaskRepository.TagFilter.tag($0))) }
            }
            .pickerStyle(.menu)

            Section {
                Picker("Group By", selection: $repository.taskGroupOption) {
                    ForEach(TaskRepository.TaskGroupOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Sort By", selection: $repository.taskSortOption) {
                    ForEach(TaskRepository.TaskSortOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }

            if hasFilters {
                Section {
                    Button("Clear Filters", systemImage: "xmark.circle") { clearFilters() }
                }
            }
        } label: {
            Label("Filter", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(hasFilters ? "Filters, active" : "Filters")
    }

    private var hasFilters: Bool { repository.hasActiveFilters }

    private func clearFilters() { repository.clearQuickFilters() }
}

/// The active filters as removable chips with a single Clear.
struct TaskFilterChipBar: View {
    @Bindable var repository: TaskRepository

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).accessibilityHidden(true)
                ForEach(repository.activeFilters) { filter in
                    Button {
                        withAnimation { repository.clearFilter(filter.kind) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.title)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.tint.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove filter " + filter.title)
                }
                Button("Clear") { withAnimation { repository.clearQuickFilters() } }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("Clear all filters")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.bar)
    }
}

struct EmptyTaskStateView: View {
    @Bindable var repository: TaskRepository
    @Binding var editorDraft: TaskDraft?

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                repository.accessState == .granted ? emptyTitle : "Reminders Access Needed",
                systemImage: repository.accessState == .granted ? emptyIcon : "lock.open",
                description: Text(repository.accessState == .granted ? emptyDescription : repository.accessState.message)
            )
            VStack(spacing: 10) {
                if repository.accessState == .unknown {
                    Button {
                        Task { await repository.requestAccess() }
                    } label: {
                        Label("Continue", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                } else if repository.accessState == .denied {
                    #if canImport(UIKit)
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    #endif
                } else if hasFilters {
                    // One clear action: when filters or search hide everything, the fix is to clear them.
                    Button {
                        withAnimation { repository.clearTaskFilters() }
                    } label: {
                        Label(searchText.isEmpty ? "Clear Filters" : "Clear Search", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                } else if repository.accessState == .granted, repository.selectedScope != .completed {
                    Button {
                        editorDraft = repository.makeDraft()
                    } label: {
                        Label("New Task", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var hasFilters: Bool {
        !repository.searchQuery.isEmpty || repository.hasActiveFilters
    }

    private var searchText: String { repository.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Specific to where the user is, so an empty screen explains itself.
    private var emptyTitle: String {
        if !searchText.isEmpty { return "No Results for “\(searchText)”" }
        if repository.hasActiveFilters { return "No Matching Tasks" }
        switch repository.selectedScope {
        case .today: return "Nothing Due Today"
        case .next7Days, .upNext: return "Nothing Scheduled"
        case .flagged: return "No Flagged Tasks"
        case .completed: return "Nothing Completed Yet"
        case .inbox: return "Inbox Zero"
        case .list: return "This List Is Empty"
        default: return "No Tasks"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Check the spelling, or search for a #tag." }
        if repository.hasActiveFilters { return "Clear filters to see everything in this view." }
        switch repository.selectedScope {
        case .today: return "Enjoy the open time, or add something you want to get done today."
        case .next7Days, .upNext: return "Tasks with a due date appear here, grouped by day."
        case .flagged: return "Flag a task to keep it close at hand."
        case .completed: return "Tasks you complete appear here."
        case .inbox: return "Everything is handled. New tasks land here first."
        default: return "Add a task to get started."
        }
    }

    private var emptyIcon: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        if repository.hasActiveFilters { return "line.3.horizontal.decrease.circle" }
        switch repository.selectedScope {
        case .today: return "sun.max"
        case .next7Days, .upNext: return "calendar"
        case .flagged: return "flag"
        case .completed: return "checkmark.circle"
        case .inbox: return "tray"
        default: return "checklist"
        }
    }
}
