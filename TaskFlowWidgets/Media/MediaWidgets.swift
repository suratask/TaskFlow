import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct MediaWidgetListEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Read/Watch Later List")
    static var defaultQuery = MediaWidgetListQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct MediaWidgetListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MediaWidgetListEntity] {
        availableLists().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [MediaWidgetListEntity] { availableLists() }
    func entities(matching string: String) async throws -> [MediaWidgetListEntity] {
        availableLists().filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
    }
    func availableLists() -> [MediaWidgetListEntity] {
        guard hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder)) else { return [] }
        let types = TaskFlowSharedSettings.defaults.dictionary(forKey: "TaskFlow.specializedListTypes") as? [String: String] ?? [:]
        return EKEventStore().calendars(for: .reminder)
            .filter { types[$0.calendarIdentifier] == "Reading & Watch Later" }
            .map { MediaWidgetListEntity(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct MediaWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Read/Watch Later"
    static var description = IntentDescription("Choose a media list, or leave blank to use your Share Extension destination.")
    @Parameter(title: "List") var list: MediaWidgetListEntity?
}

struct MediaWidgetEntry: TimelineEntry {
    let date: Date
    var watch: Bool
    var episodeMode: ReadingMedia.EpisodeFeedMode? = nil
    var listID: String?
    var listTitle: String
    var tasks: [WidgetTask]
    var previews: [String: Data] = [:]
    var accessNeeded = false
    var unavailable = false
    var theme = TaskFlowSharedSettings.theme
}

struct MediaWidgetProvider: AppIntentTimelineProvider {
    let watch: Bool
    var episodeMode: ReadingMedia.EpisodeFeedMode? = nil
    func placeholder(in context: Context) -> MediaWidgetEntry {
        let titles = watch ? ["Slow Horses", "A new documentary", "Your next movie"] : ["Ideas worth saving", "A story for the weekend", "Your next podcast"]
        let tasks = titles.enumerated().map { index, title in
            var task = WidgetTask(id: "media-preview-\(index)", externalID: nil, title: title, listID: "preview", listTitle: "Saved media", dueDate: nil, priority: 0, isCompleted: false, status: "Not Started", isFlagged: false, parentID: nil, durationMinutes: nil, tags: [], blockedByTaskIDs: [], specializedFields: ["Format": watch ? "Video" : (index == 2 ? "Audio" : "Article"), "Progress": index == 0 ? "In Progress" : "Saved"])
            if episodeMode != nil {
                task.specializedFields["Format"] = "TV Show"
                task.specializedFields["Widget Episode"] = "S2 E3"
                task.specializedFields["Widget Episode Runtime"] = "45 min"
                task.specializedFields["Widget Episode Date"] = Date().addingTimeInterval(episodeMode == .newEpisodes ? 0 : 86400).formatted(date: .abbreviated, time: .omitted)
            }
            return task
        }
        return MediaWidgetEntry(date: Date(), watch: watch, episodeMode: episodeMode, listID: "preview", listTitle: watch ? "Watch Later" : "Read Later", tasks: tasks)
    }
    func snapshot(for configuration: MediaWidgetConfiguration, in context: Context) async -> MediaWidgetEntry {
        context.isPreview ? placeholder(in: context) : await entry(configuration, family: context.family)
    }
    func timeline(for configuration: MediaWidgetConfiguration, in context: Context) async -> Timeline<MediaWidgetEntry> {
        let current = await entry(configuration, family: context.family)
        let upcoming = current.tasks.compactMap { ReadingMedia.tracking($0.specializedFields)?.upcoming(now: current.date)?.release }.min()
        let refresh = min(current.date.addingTimeInterval(900), upcoming ?? .distantFuture)
        return Timeline(entries: [current], policy: .after(max(current.date.addingTimeInterval(60), refresh)))
    }
    private func entry(_ configuration: MediaWidgetConfiguration, family: WidgetFamily) async -> MediaWidgetEntry {
        let lists = MediaWidgetListQuery().availableLists()
        let preferred = ReadingMedia.defaults.string(forKey: ReadingMedia.preferenceKey(watch: watch))
        let selected: MediaWidgetListEntity?
        if let chosen = configuration.list { selected = lists.first { $0.id == chosen.id } }
        else { selected = lists.first { $0.id == preferred } ?? lists.first }
        guard let selected else {
            return MediaWidgetEntry(date: Date(), watch: watch, episodeMode: episodeMode, listID: nil, listTitle: "", tasks: [], accessNeeded: !hasEventKitAccess(EKEventStore.authorizationStatus(for: .reminder)), unavailable: configuration.list != nil)
        }
        let loaded = await ReminderWidgetStore().loadMediaItems(listID: selected.id, watch: watch)
        var displayed = loaded.tasks
        if let episodeMode {
            let sources = loaded.tasks.map { ReadingMedia.EpisodeFeedSource(taskID: $0.id, title: $0.title, fields: $0.specializedFields) }
            let episodes = ReadingMedia.episodeFeed(sources, mode: episodeMode, onePerShow: true)
            displayed = episodes.compactMap { item in
                guard var task = loaded.tasks.first(where: { $0.id == item.taskID }) else { return nil }
                task.specializedFields["Widget Episode"] = item.episode.label
                task.specializedFields["Widget Episode ID"] = String(item.episode.id)
                task.specializedFields["Widget Episode Date"] = item.release.formatted(date: .abbreviated, time: .omitted)
                task.specializedFields["Widget Episode Runtime"] = item.episode.runtime.map { "\($0) min" }
                return task
            }
        }
        var result = MediaWidgetEntry(date: Date(), watch: watch, episodeMode: episodeMode, listID: selected.id, listTitle: selected.title, tasks: displayed, accessNeeded: loaded.accessNeeded)
        let limit = family == .systemSmall ? 1 : family == .systemMedium ? 2 : 5
        for task in displayed.prefix(limit) {
            if let local = ReadingMedia.capturePreviewData(task.specializedFields["Local Preview"]) { result.previews[task.id] = local }
            else if let raw = task.specializedFields["Thumbnail URL"], let data = await MediaWidgetPreviewCache.shared.preview(raw) {
                result.previews[task.id] = data
            }
        }
        return result
    }
}

/// Small, persistent widget images; timelines never depend on a preview succeeding.
actor MediaWidgetPreviewCache {
    static let shared = MediaWidgetPreviewCache()
    private let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.surratt.TaskFlow")?.appendingPathComponent("WidgetMediaPreviews", isDirectory: true)
    func preview(_ raw: String) async -> Data? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", let directory else { return nil }
        let key = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file) { return data }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              response.url?.scheme == "https", let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 2_000_000 { return nil }
            }
        } catch { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let thumbnail = UIImage(cgImage: image).jpegData(compressionQuality: 0.75) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? thumbnail.write(to: file, options: .atomic)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 60 {
            let sorted = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in sorted.prefix(files.count - 60) { try? FileManager.default.removeItem(at: old) }
        }
        return thumbnail
    }
}

struct TaskFlowReadLaterWidget: Widget {
    var body: some WidgetConfiguration { mediaWidgetConfiguration(watch: false) }
}

struct TaskFlowContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration { mediaWidgetConfiguration(watch: true, mode: .continuing) }
}

struct TaskFlowNewEpisodesWidget: Widget {
    var body: some WidgetConfiguration { mediaWidgetConfiguration(watch: true, mode: .newEpisodes) }
}

struct TaskFlowComingSoonWidget: Widget {
    var body: some WidgetConfiguration { mediaWidgetConfiguration(watch: true, mode: .comingSoon) }
}

struct TaskFlowWatchLaterWidget: Widget {
    var body: some WidgetConfiguration { mediaWidgetConfiguration(watch: true) }
}

@MainActor
func mediaWidgetConfiguration(watch: Bool, mode: ReadingMedia.EpisodeFeedMode? = nil) -> some WidgetConfiguration {
    AppIntentConfiguration(kind: mode.map { "TaskFlowEpisodeWidget-" + $0.rawValue } ?? (watch ? "TaskFlowWatchLaterWidget" : "TaskFlowReadLaterWidget"), intent: MediaWidgetConfiguration.self, provider: MediaWidgetProvider(watch: watch, episodeMode: mode)) { entry in
        MediaWidgetView(entry: entry)
    }
    .configurationDisplayName(mode?.title ?? (watch ? "Watch Later" : "Read Later"))
    .description(mode == nil ? (watch ? "Open saved videos, shows, and movies in your TaskFlow list." : "Open saved articles, books, and podcasts in your TaskFlow list.") : "See next episodes and catalog release dates for matched shows. Tap to open the saved show in TaskFlow.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}

struct MediaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: MediaWidgetEntry
    private var limit: Int { family == .systemSmall ? 1 : family == .systemMedium ? (dynamicTypeSize.isAccessibilitySize ? 1 : 2) : (dynamicTypeSize.isAccessibilitySize ? 3 : 5) }
    private var listURL: URL { entry.listID.map(TaskFlowDeepLink.listURL) ?? TaskFlowDeepLink.captureURL }
    private func destination(_ task: WidgetTask) -> URL { TaskFlowDeepLink.taskURL(task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(entry.episodeMode?.title ?? (entry.watch ? "Watch Later" : "Read Later"), systemImage: entry.watch ? "play.rectangle.fill" : "book.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(entry.theme.primary).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(entry.tasks.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if entry.accessNeeded {
                Text("Open TaskFlow to allow Reminders access.").font(.caption).foregroundStyle(.secondary)
            } else if entry.listID == nil {
                Text(entry.unavailable ? "List unavailable" : "Choose a media list").font(.headline)
                Text(entry.unavailable ? "Edit Widget to select another list." : "Create a Read/Watch Later list in TaskFlow.").font(.caption).foregroundStyle(.secondary)
            } else if entry.tasks.isEmpty {
                Label(entry.episodeMode == nil ? (entry.watch ? "Nothing to watch yet" : "Nothing to read yet") : "No episodes to show", systemImage: "bookmark").font(.subheadline)
                Text(entry.episodeMode?.emptyMessage ?? "Share a link to this list to get started.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.tasks.prefix(limit))) { task in
                    if family == .systemSmall {
                        let hasAction = entry.watch && entry.episodeMode != .comingSoon && ReadingMedia.widgetEpisode(task.specializedFields, now: entry.date) != nil
                        VStack(alignment: .leading, spacing: 5) {
                            preview(task, width: nil, height: hasAction ? 24 : (dynamicTypeSize.isAccessibilitySize ? 28 : 45))
                            Text(task.title).font(.subheadline.weight(.semibold)).lineLimit(hasAction ? 1 : 2)
                            Text(episodeLabel(task) ?? "Open item").font(.caption.weight(.semibold)).foregroundStyle(entry.theme.primary).lineLimit(hasAction ? 1 : 2)
                            watchedButton(task)
                        }
                    } else {
                        HStack(spacing: 8) {
                        Link(destination: destination(task)) {
                            HStack(spacing: 10) {
                                preview(task, width: artworkWidth(task), height: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(task.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    let source = task.specializedFields["Saved From"] ?? ReadingMedia.watchLinks(task.specializedFields).first?.provider ?? task.specializedFields["Creator"] ?? ""
                                    let action = ReadingMedia.displayFormat(task.specializedFields)
                                    let label = task.specializedFields["Progress"] == "In Progress" ? "In Progress · " + action : action
                                    Text(episodeLabel(task) ?? (source.isEmpty ? label : label + " · " + source)).font(.caption2).foregroundStyle(entry.theme.primary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }.accessibilityLabel("Open saved item: " + task.title)
                        watchedButton(task)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if family != .systemSmall {
                Link(destination: listURL) {
                    HStack {
                        Text(entry.listTitle.isEmpty ? "Open TaskFlow" : entry.listTitle).lineLimit(1)
                        Spacer(minLength: 0)
                        if entry.tasks.count > limit { Text("+\(entry.tasks.count - limit)") }
                        Image(systemName: "arrow.up.forward")
                    }.font(.caption).foregroundStyle(entry.theme.primary)
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(family == .systemSmall ? entry.tasks.first.map(destination) ?? listURL : listURL)
    }
    @ViewBuilder private func watchedButton(_ task: WidgetTask) -> some View {
        if entry.watch, entry.episodeMode != .comingSoon, let episode = ReadingMedia.widgetEpisode(task.specializedFields, now: entry.date), let catalog = ReadingMedia.tracking(task.specializedFields) {
            Button(intent: MarkWidgetEpisodeWatchedIntent(taskID: task.id, metadataID: task.externalID.flatMap { $0.isEmpty ? nil : $0 } ?? task.id, showID: catalog.show.id, episodeID: episode.id)) {
                if family == .systemSmall { Label("Watched", systemImage: "checkmark.circle").font(.caption) }
                else { Image(systemName: "checkmark.circle").font(.title3).frame(minWidth: 32, minHeight: 36) }
            }
            .buttonStyle(.plain).foregroundStyle(entry.theme.primary)
            .accessibilityLabel("Mark " + episode.label + " of " + task.title + " watched")
        }
    }
    private func episodeLabel(_ task: WidgetTask) -> String? {
        if let episode = task.specializedFields["Widget Episode"] {
            return episode + " · " + (entry.episodeMode == .continuing ? (task.specializedFields["Widget Episode Runtime"] ?? "Next unwatched") : task.specializedFields["Widget Episode Date"] ?? "")
        }
        if entry.watch, let next = ReadingMedia.tracking(task.specializedFields)?.next(now: entry.date) { return "Next: " + next.label }
        return nil
    }
    private func artworkWidth(_ task: WidgetTask) -> CGFloat {
        let image = entry.previews[task.id].flatMap { UIImage(data: $0) }
        return 44 * ReadingMedia.artworkAspect(width: Double(image?.size.width ?? 0), height: Double(image?.size.height ?? 0), format: ReadingMedia.displayFormat(task.specializedFields))
    }
    private func preview(_ task: WidgetTask, width: CGFloat?, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(entry.theme.primary.opacity(0.12))
            if let data = entry.previews[task.id], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: ReadingMedia.symbol(for: ReadingMedia.displayFormat(task.specializedFields))).foregroundStyle(entry.theme.primary)
            }
        }.frame(width: width, height: height).frame(maxWidth: width == nil ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}
