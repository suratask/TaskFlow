import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

struct AttachmentPreviewDocument: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        if priority != .none {
            Text(priority.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(color)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
        }
    }

    private var color: Color {
        switch priority {
        case .none: .secondary
        case .low: .secondary
        case .medium: .secondary
        case .high: .accentColor
        }
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Label(status.rawValue, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
    }

    private var icon: String {
        switch status {
        case .notStarted: "circle"
        case .active: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .blocked, .overdue: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .notStarted: .secondary
        case .active: .accentColor
        case .waiting: .secondary
        case .blocked: .secondary
        case .overdue: .red
        case .done: .secondary
        }
    }
}

struct TagCloud: View {
    let tags: [String]
    var colorForTag: (String) -> Color = { _ in .indigo }
    var onRemove: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                let color = colorForTag(tag)
                HStack(spacing: 4) {
                    Text("#\(tag)")
                    if let onRemove {
                        Button {
                            onRemove(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                        }
                        .foregroundStyle(color.opacity(0.8))
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: TaskFlowTheme.badgeRadius, style: .continuous)
                        .strokeBorder(color.opacity(0.14), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(CGFloat.zero) { partial, subview in
            partial + subview.sizeThatFits(.unspecified).width + spacing
        }
        let maxWidth = max(1, proposal.width ?? max(1, naturalWidth - spacing))
        var size = CGSize.zero
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let subviewSize = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if lineWidth + subviewSize.width > maxWidth, lineWidth > 0 {
                size.width = max(size.width, lineWidth - spacing)
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }

        size.width = max(size.width, lineWidth - spacing)
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if point.x + size.width > bounds.maxX, point.x > bounds.minX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct TagSelectionEditor: View {
    let savedTags: [SavedTag]
    @Binding var selectedTags: [String]
    let colorForTag: (String) -> Color
    let onCreate: (String) -> Void
    @State private var newTag = ""

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(allTagNames, id: \.self) { name in
                Button { toggle(name) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: contains(name) ? "checkmark.circle.fill" : "number")
                        Text(name).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline.weight(contains(name) ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .foregroundStyle(colorForTag(name))
                    .background(colorForTag(name).opacity(contains(name) ? 0.18 : 0.07), in: Capsule())
                    .overlay(Capsule().stroke(colorForTag(name).opacity(contains(name) ? 0.6 : 0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tag " + name)
                .accessibilityAddTraits(contains(name) ? .isSelected : [])
            }
        }
        TextField("New Tag", text: $newTag)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.done).onSubmit(addTag)
    }

    /// Saved tags plus any already on this item, in alphabetical order.
    private var allTagNames: [String] {
        var names = savedTags.map(\.name)
        for tag in selectedTags where !names.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            names.append(tag)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func addTag() {
        let name = MetadataStore.normalizedTag(newTag)
        guard !name.isEmpty else { return }
        if !contains(name) { selectedTags.append(name) }
        onCreate(name)
        newTag = ""
    }

    private func toggle(_ name: String) {
        if contains(name) { selectedTags.removeAll { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        else { selectedTags.append(name) }
    }

    private func contains(_ name: String) -> Bool {
        selectedTags.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}

// Shared by the calendar location search and its selected-place presentation.
struct LocationLookupResult: Identifiable {
    let location: TaskLocation
    var id: String { location.id }

    init(mapItem: MKMapItem) {
        location = TaskLocation(
            title: mapItem.name ?? "",
            address: mapItem.placemark.title ?? "",
            latitude: mapItem.placemark.coordinate.latitude,
            longitude: mapItem.placemark.coordinate.longitude
        )
    }
}

struct LocationLookupRow: View {
    let result: LocationLookupResult

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.location.displayTitle).foregroundStyle(.primary)
                Text(result.location.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "mappin.circle").foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct PinnedLocationCard: View {
    let location: TaskLocation
    let onOpen: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                Label(location.displayTitle, systemImage: "map")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Clear Location", systemImage: "xmark.circle.fill", action: onClear)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
    }
}

/// One-time hint that the + button has more options on touch-and-hold.
struct AddMenuTip: Tip {
    var title: Text { Text("More Ways to Add") }
    var message: Text? { Text("Tap + for a new task. Touch and hold for a new event or Quick Capture.") }
    var image: Image? { Image(systemName: "plus.circle") }
}

/// One-time hint for planning swipes in Today's Suggested section.
/// First-run tips, shown one at a time in the task list (TipKit shows each until it's dismissed or learned).
struct TaskGesturesTip: Tip {
    var title: Text { Text("Quick Actions") }
    var message: Text? { Text("Swipe right to complete. Touch and hold a task to change its date, priority, tags, or list without opening it.") }
    var image: Image? { Image(systemName: "hand.tap") }
}

struct QuickAddTip: Tip {
    var title: Text { Text("Add Tasks Fast") }
    var message: Text? { Text("Type a task at the bottom of any list. Long-press + for Quick Capture, a new event, or a note.") }
    var image: Image? { Image(systemName: "plus.circle") }
}

struct PlanTodayTip: Tip {
    var title: Text { Text("Plan Your Day") }
    var message: Text? { Text("Swipe right on a suggested task to add it to Today. Swipe left on an overdue task to move it to tomorrow.") }
    var image: Image? { Image(systemName: "sun.max") }
}

struct EditableMediaLink: Identifiable {
    var id = UUID()
    var provider = ""
    var url = ""
    var region = ""
    var note = ""
    var link: ReadingMedia.WatchLink {
        .init(provider: provider.trimmingCharacters(in: .whitespacesAndNewlines), url: url.trimmingCharacters(in: .whitespacesAndNewlines), region: region.isEmpty ? nil : region, note: note.isEmpty ? nil : note)
    }
}

/// Disk-backed previews keep a fixed footprint while loading and work offline.
actor ReadingThumbnailCache {
    static let shared = ReadingThumbnailCache()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingPreviews", isDirectory: true)

    nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    func data(for url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        if let cached = try? Data(contentsOf: file), let thumbnail = Self.thumbnail(cached) { return thumbnail }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request),
              response.url?.scheme?.lowercased() == "https",
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true else { return nil }
        var raw = Data()
        do {
            for try await byte in stream {
                guard !Task.isCancelled, raw.count < 8_000_000 else { return nil }
                raw.append(byte)
            }
        } catch { return nil }
        guard let data = Self.thumbnail(raw) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let ordered = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var count = files.count
            for old in ordered {
                guard count > 120 || bytes > 64_000_000 else { break }
                bytes -= (try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                count -= 1
                try? FileManager.default.removeItem(at: old)
            }
        }
        return data
    }
}

struct CachedMediaPreview: View {
    let rawURL: String?
    let format: String
    var expanded = false
    var localPreview: String? = nil
    var poster = false
    @State private var image: UIImage?
    private var isAudio: Bool { ReadingMedia.action(for: format) == "Listen" }
    private var aspect: Double { ReadingMedia.artworkAspect(width: Double(image?.size.width ?? 0), height: Double(image?.size.height ?? 0), format: format) }
    private var previewHeight: CGFloat { poster && !expanded ? 108 : expanded ? (aspect < 0.9 ? 200 : 144) : (aspect < 0.9 ? 80 : 64) }
    private var previewWidth: CGFloat { poster && !expanded ? 72 : previewHeight * aspect }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius).fill(Color.secondary.opacity(0.12))
            if let image {
                if poster && !expanded {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: previewWidth, height: previewHeight).clipped()
                } else { Image(uiImage: image).resizable().scaledToFit() }
            }
            else { Image(systemName: ReadingMedia.symbol(for: format)).foregroundStyle(.secondary) }
        }
        .frame(width: previewWidth, height: previewHeight)
        .clipped().clipShape(RoundedRectangle(cornerRadius: TaskFlowTheme.controlRadius))
        .accessibilityHidden(true)
        .task(id: (rawURL ?? "") + (localPreview ?? "")) {
            image = nil
            if let data = ReadingMedia.capturePreviewData(localPreview), let preview = UIImage(data: data) { image = preview; return }
            guard let rawURL, let url = URL(string: rawURL), let data = await ReadingThumbnailCache.shared.data(for: url), !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}

struct ListCleanupView: View {
    @Bindable var repository: TaskRepository
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var pending: Set<String> = []
    @State private var deleting = false
    private var items: [TaskItem] { repository.tasks.filter { $0.listID == listID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private var completed: Set<String> { Set(items.filter(\.isCompleted).map(\.id)) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose individual items or remove completed items in one step. This includes items hidden by your list filters.").font(.footnote).foregroundStyle(.secondary)
                    Button("Delete Completed (\(completed.count))", systemImage: "trash", role: .destructive) { prepare(completed) }.disabled(completed.isEmpty)
                    Button("Delete Selected (\(selected.count))", systemImage: "trash", role: .destructive) { prepare(selected) }.disabled(selected.isEmpty)
                    Button("Delete All Items (\(items.count))", systemImage: "trash", role: .destructive) { prepare(Set(items.map(\.id))) }.disabled(items.isEmpty)
                    if let action = repository.taskUndo {
                        Button("Undo " + action.message, systemImage: "arrow.uturn.backward") {
                            deleting = true
                            Task { await repository.undoLastTaskAction(); deleting = false }
                        }
                    }
                    if let error = repository.errorMessage { Text(error).foregroundStyle(.red) }
                }
                Section("Select Items") {
                    ForEach(items) { item in
                        Button {
                            if !selected.insert(item.id).inserted { selected.remove(item.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.isCompleted ? "Completed" : "Open").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.accessibilityLabel(item.title + (selected.contains(item.id) ? ", selected" : ", not selected"))
                    }
                }
            }
            .disabled(deleting || repository.isUndoing)
            .navigationTitle("Clean Up Items")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(deleting) } }
            .interactiveDismissDisabled(deleting)
            .confirmationDialog("Delete \(pending.count) items?", isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }), titleVisibility: .visible) {
                Button("Delete \(pending.count) Items", role: .destructive) {
                    let ids = pending.intersection(Set(items.map(\.id)))
                    pending = []
                    deleting = true
                    Task {
                        await repository.deleteTasks(ids)
                        selected.subtract(ids)
                        deleting = false
                    }
                }
                Button("Cancel", role: .cancel) { pending = [] }
            } message: { Text("Items are deleted from Apple Reminders and synced devices. Selected parent items include their subtasks. The list itself stays. Undo is available after deletion.") }
        }
    }
    private func prepare(_ ids: Set<String>) {
        var expanded = ids.intersection(Set(items.map(\.id)))
        while true {
            let children = Set(items.filter { $0.parentID.map { expanded.contains($0) } == true }.map(\.id))
            let next = expanded.union(children)
            if next == expanded { break }
            expanded = next
        }
        pending = expanded
    }
}
