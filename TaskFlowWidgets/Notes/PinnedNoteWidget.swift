import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct PinnedNoteWidgetEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pinned Note")
    static var defaultQuery = PinnedNoteWidgetQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title.isEmpty ? "Untitled note" : title)", image: .init(systemName: "note.text")) }
}

struct PinnedNoteWidgetQuery: EntityStringQuery {
    private var notes: [PinnedNoteWidgetEntity] {
        TaskFlowSharedNotes.load().filter(\.isPinned).map { PinnedNoteWidgetEntity(id: $0.id.uuidString, title: $0.title) }
    }
    func entities(for identifiers: [String]) async throws -> [PinnedNoteWidgetEntity] {
        let available = notes
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [PinnedNoteWidgetEntity] { notes }
    func entities(matching string: String) async throws -> [PinnedNoteWidgetEntity] {
        notes.filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
    }
}

struct PinnedNoteWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pinned Note"
    static var description = IntentDescription("Choose a note pinned in TaskFlow. Leave blank to use your first pinned note.")
    @Parameter(title: "Note") var note: PinnedNoteWidgetEntity?
    @Parameter(title: "Hide Completed", default: false) var hideCompleted: Bool
    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$note)") { \.$hideCompleted } }
}

struct PinnedNoteWidgetEntry: TimelineEntry {
    let date: Date
    let note: TaskFlowSharedNote?
    let missingSelection: Bool
    let hideCompleted: Bool
    let theme: TaskFlowSharedTheme
}

struct PinnedNoteWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PinnedNoteWidgetEntry {
        PinnedNoteWidgetEntry(date: Date(), note: TaskFlowSharedNote(id: UUID(), title: "Weekend plans", text: "- [x] Book a table\n- [ ] Pack a picnic\n- [ ] Pick up groceries\n- [ ] Charge the camera", folder: "Personal", tags: [], isPinned: true, format: "checklist", updatedAt: Date()), missingSelection: false, hideCompleted: false, theme: TaskFlowSharedSettings.theme)
    }
    func snapshot(for configuration: PinnedNoteWidgetConfigurationIntent, in context: Context) async -> PinnedNoteWidgetEntry {
        context.isPreview ? placeholder(in: context) : entry(configuration)
    }
    func timeline(for configuration: PinnedNoteWidgetConfigurationIntent, in context: Context) async -> Timeline<PinnedNoteWidgetEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func entry(_ configuration: PinnedNoteWidgetConfigurationIntent) -> PinnedNoteWidgetEntry {
        let notes = TaskFlowSharedNotes.load().filter(\.isPinned)
        let chosen = configuration.note.flatMap { selected in notes.first { $0.id.uuidString == selected.id } } ?? (configuration.note == nil ? notes.first : nil)
        return PinnedNoteWidgetEntry(date: Date(), note: chosen, missingSelection: configuration.note != nil && chosen == nil, hideCompleted: configuration.hideCompleted, theme: TaskFlowSharedSettings.theme)
    }
}

struct TaskFlowPinnedNoteWidget: Widget {
    private var families: [WidgetFamily] {
        var result: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { result.append(.systemExtraLargePortrait) }
        return result
    }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskFlowPinnedNoteWidget", intent: PinnedNoteWidgetConfigurationIntent.self, provider: PinnedNoteWidgetProvider()) { entry in
            PinnedNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Pinned Note & Checklist")
        .description("Keep a pinned note nearby and check or uncheck its items.")
        .supportedFamilies(families)
    }
}

struct PinnedNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PinnedNoteWidgetEntry
    private var rowLimit: Int {
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return 10 }
        switch family { case .systemSmall: return 1; case .systemMedium: return 2; default: return 4 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").foregroundStyle(entry.theme.primary)
                Text(entry.note?.title.isEmpty == false ? entry.note!.title : "Pinned Note").font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let note = entry.note {
                let items = note.checklistItems.filter { !entry.hideCompleted || !$0.isChecked }
                if note.format == "checklist" || note.format == "markdown" && !note.checklistItems.isEmpty {
                    if items.isEmpty {
                        Text("All items complete").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(items.prefix(rowLimit))) { item in
                        HStack(spacing: 6) {
                            Button(intent: ToggleNoteChecklistWidgetIntent(noteID: note.id, itemID: item.id, expectedSource: note.text.components(separatedBy: "\n")[item.id], checked: !item.isChecked)) {
                                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(item.isChecked ? entry.theme.primary : .secondary)
                                    .frame(width: 32, height: family == .systemMedium ? 32 : 40)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(item.isChecked ? "Uncheck \(item.title)" : "Check \(item.title)")
                            Text(item.title).font(.subheadline).strikethrough(item.isChecked).foregroundStyle(item.isChecked ? .secondary : .primary).lineLimit(1)
                        }
                    }
                    if items.count > rowLimit { Text("+\(items.count - rowLimit) more").font(.caption2).foregroundStyle(.secondary) }
                } else {
                    Text(.init(note.text)).font(.subheadline).lineLimit(family == .systemSmall ? 4 : 8)
                }
                Spacer(minLength: 0)
                Link("Open Note", destination: TaskFlowDeepLink.noteURL(note.id)).font(.caption.weight(.semibold))
            } else {
                Text(entry.missingSelection ? "This note was deleted or unpinned. Edit the widget to choose another." : "Pin a note in TaskFlow, then select it in Edit Widget.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.note.map { TaskFlowDeepLink.noteURL($0.id) } ?? TaskFlowDeepLink.newNoteURL)
    }
}
