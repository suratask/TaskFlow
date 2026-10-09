import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

/// Reminders-style "New Task" row: type a title, press Return, and keep going.
/// Shows what quick add understood: the typed text with recognized parts colored, plus a chip for each.
struct QuickAddHighlights: View {
    let text: String
    let parse: QuickAddParse

    var body: some View {
        if !parse.tokens.isEmpty {
            VStack(alignment: .leading, spacing: TaskFlowTheme.Spacing.xSmall) {
                Text(highlighted).font(.subheadline).lineLimit(2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaskFlowTheme.Spacing.xSmall) {
                        ForEach(Array(parse.tokens.enumerated()), id: \.offset) { _, token in
                            Label(token.display, systemImage: Self.icon(token.kind))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, TaskFlowTheme.Spacing.small).padding(.vertical, TaskFlowTheme.Spacing.xSmall)
                                .foregroundStyle(Self.color(token.kind))
                                .background(Self.color(token.kind).opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recognized " + parse.tokens.map(\.display).joined(separator: ", "))
        }
    }

    private var highlighted: AttributedString {
        var result = AttributedString(text)
        for token in parse.tokens {
            guard let lower = AttributedString.Index(token.range.lowerBound, within: result),
                  let upper = AttributedString.Index(token.range.upperBound, within: result), lower < upper else { continue }
            result[lower..<upper].foregroundColor = Self.color(token.kind)
            result[lower..<upper].font = .subheadline.weight(.semibold)
        }
        return result
    }

    static func icon(_ kind: QuickAddParse.Kind) -> String {
        switch kind {
        case .date: "calendar"
        case .tag: "number"
        case .priority: "exclamationmark"
        case .list: "list.bullet"
        case .alert: "bell"
        case .flag: "flag.fill"
        }
    }

    static func color(_ kind: QuickAddParse.Kind) -> Color {
        switch kind {
        case .date: .blue
        case .tag: .purple
        case .priority: .red
        case .list: .teal
        case .alert: .indigo
        case .flag: TaskFlowTheme.flagged
        }
    }
}

struct InlineNewTaskRow: View {
    enum DueChoice: String, CaseIterable, Identifiable {
        case none = "No Date"
        case today = "Today"
        case tomorrow = "Tomorrow"
        case nextWeek = "Next Week"
        var id: String { rawValue }
    }

    @Bindable var repository: TaskRepository
    var defaultDue: DueChoice = .none
    var defaultFlagged = false
    var onShowDetails: (TaskDraft) -> Void
    var onAdded: () -> Void = {}
    @State private var title = ""
    @State private var due: DueChoice?
    @State private var isFlagged = false
    @FocusState private var isFocused: Bool

    private var parsed: QuickAddParse {
        QuickAddParser.parse(title, lists: repository.lists.map { (id: $0.id, title: $0.title) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TaskFlowTheme.Spacing.xSmall) {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(width: 30)
                .accessibilityHidden(true)
            TextField("New Task  ·  try “tomorrow 9am #home !high”", text: $title)
                .accessibilityIdentifier("inline-new-task-field")
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(add)
            if isFocused {
                Menu {
                    Picker("Date", selection: Binding(get: { effectiveDue }, set: { due = $0 })) {
                        ForEach(DueChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: effectiveDue == .none ? "calendar" : "calendar.badge.checkmark")
                }
                .accessibilityLabel("Due date: \(effectiveDue.rawValue)")
                Button {
                    isFlagged.toggle()
                } label: {
                    Image(systemName: isFlagged ? "flag.fill" : "flag")
                        .foregroundStyle(isFlagged ? Color.orange : Color.accentColor)
                }
                .accessibilityLabel(isFlagged ? "Unflag" : "Flag")
                Button {
                    onShowDetails(makeDraft())
                    reset()
                    isFocused = false
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("More details")
            } else if isFlagged {
                Image(systemName: "flag.fill").foregroundStyle(.orange).accessibilityLabel("Flagged")
            }
        }
        if isFocused { QuickAddHighlights(text: title, parse: parsed).padding(.leading, 38) }
        }
        .buttonStyle(.borderless)
        .id(InlineNewTaskRow.scrollID)
    }

    static let scrollID = "inline-new-task-row"

    private var effectiveDue: DueChoice { due ?? defaultDue }

    private func makeDraft() -> TaskDraft {
        let parsed = self.parsed
        var draft = repository.makeDraft()
        draft.title = parsed.title.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : parsed.title
        draft.isFlagged = isFlagged || defaultFlagged || parsed.isFlagged
        if let listID = parsed.listID { draft.listID = listID }
        if let priority = parsed.priority { draft.priority = priority }
        draft.tags = parsed.tags
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let date = parsed.dueDate, due == nil {
            // Words in the title ("tomorrow 9am") win over the row's default date.
            draft.dueDate = date
            draft.hasDueTime = parsed.hasDueTime
            draft.alarmOffsetMinutes = parsed.alarmMinutes
        } else {
            switch effectiveDue {
            case .none: draft.dueDate = nil
            case .today: draft.dueDate = today
            case .tomorrow: draft.dueDate = calendar.date(byAdding: .day, value: 1, to: today)
            case .nextWeek: draft.dueDate = calendar.date(byAdding: .day, value: 7, to: today)
            }
            draft.hasDueTime = false
        }
        return draft
    }

    private func add() {
        let draft = makeDraft()
        guard !draft.title.isEmpty, !draft.listID.isEmpty else {
            isFocused = false
            return
        }
        reset()
        isFocused = true
        Task {
            if await repository.saveTask(draft) {
                onAdded()
            }
        }
    }

    private func reset() {
        title = ""
        due = nil
        isFlagged = false
    }
}
