import Foundation
import UserNotifications

/// Shared capture contract used by the app and its share extension.
enum ReadingMedia {
    static let formats = ["Movie", "TV Show", "Episode", "Video", "Article", "Podcast", "Audio", "Book", "Other"]
    static let providers = ["Netflix", "Prime Video", "HBO Max", "Apple TV", "Disney+", "Hulu", "Peacock", "Paramount+", "YouTube", "Vimeo", "Spotify", "Apple Podcasts", "Apple Music"]

    static func provider(for url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let services: [(String, [String])] = [
            ("Netflix", ["netflix.com"]), ("Prime Video", ["primevideo.com", "amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.com.au"]),
            ("HBO Max", ["max.com", "hbomax.com", "hbo.com"]), ("Apple TV", ["tv.apple.com"]),
            ("Disney+", ["disneyplus.com"]), ("Hulu", ["hulu.com"]), ("Peacock", ["peacocktv.com"]), ("Paramount+", ["paramountplus.com"]),
            ("YouTube", ["youtube.com", "youtu.be"]), ("Vimeo", ["vimeo.com"]), ("Spotify", ["open.spotify.com"]),
            ("Apple Podcasts", ["podcasts.apple.com"]), ("Apple Music", ["music.apple.com"])
        ]
        return services.first { name, domains in
            // Amazon also shares products. Only its video routes identify a provider.
            if name == "Prime Video", !host.hasSuffix("primevideo.com"), !url.path.lowercased().contains("video") { return false }
            return domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }?.0
    }

    struct WatchLink: Codable, Hashable, Identifiable {
        var provider: String
        var url: String
        var region: String? = nil
        var note: String? = nil
        var id: String { canonicalURL(url) }
    }

    static func watchLinks(_ fields: [String: String]) -> [WatchLink] {
        var links = fields["Watch Links"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([WatchLink].self, from: $0) } ?? []
        if let raw = fields["Source Link"], let url = URL(string: raw), isWebURL(url), !links.contains(where: { canonicalURL($0.url) == canonicalURL(raw) }) {
            links.insert(WatchLink(provider: provider(for: url) ?? fields["Saved From"] ?? url.host ?? "Source", url: raw), at: 0)
        }
        var seen = Set<String>()
        return links.filter { link in
            guard let url = URL(string: link.url), isWebURL(url) else { return false }
            return seen.insert(canonicalURL(link.url)).inserted
        }
    }
    static func encodeLinks(_ links: [WatchLink]) -> String {
        (try? JSONEncoder().encode(links)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    static func canonicalURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.host = components.host?.lowercased()
        if let fragment = components.fragment, !fragment.contains("/"), !fragment.contains("="), !fragment.hasPrefix("!") { components.fragment = nil }
        let tracking = ["fbclid", "gclid"] + (URL(string: raw).flatMap { provider(for: $0) } == nil ? [] : ["ref", "ref_", "tag", "source", "si"])
        components.queryItems = components.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !tracking.contains($0.name.lowercased()) }.sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        // Normalize equivalent Netflix title/watch links without ignoring episode IDs.
        if let host = components.host, host == "netflix.com" || host.hasSuffix(".netflix.com") {
            let parts = components.path.split(separator: "/")
            if let marker = parts.firstIndex(where: { $0 == "title" || $0 == "watch" }), marker + 1 < parts.count {
                return "netflix:" + parts[marker + 1]
            }
        }
        return components.string ?? raw
    }
    static func identifiesItem(_ url: URL) -> Bool {
        guard let normalized = URLComponents(string: canonicalURL(url.absoluteString)) else { return false }
        return (!normalized.path.isEmpty && normalized.path != "/") || !(normalized.queryItems ?? []).isEmpty || normalized.fragment != nil
    }
    static func cleanTitle(_ raw: String, url: URL) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider(for: url) != nil else { return title }
        title = title.replacingOccurrences(of: url.absoluteString, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = #"\s*(?:[|–—-]\s*|\s+on\s+)(?:Netflix(?:\s+Official\s+Site)?|Prime Video|Amazon Prime Video|HBO Max|HBO|Max|Apple TV\+?|Disney\+|Hulu|Peacock|Paramount\+)\s*$"#
        let cleaned = title.replacingOccurrences(of: suffix, with: "", options: [.regularExpression, .caseInsensitive])
        if cleaned != title {
            title = cleaned.replacingOccurrences(of: #"^(?:Watch|Stream)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        title = title.replacingOccurrences(of: #"^(?:Check out|I recommend watching)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func tagValues(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "-").lowercased()
            return value.isEmpty || !seen.insert(value).inserted ? nil : value
        }
    }
    static func tagNames(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return value.isEmpty || !seen.insert(value.lowercased()).inserted ? nil : value
        }
    }
    static func suggestedTags(_ fields: [String: String], includeGenres: Bool = true) -> [String] {
        let services = watchLinks(fields).map(\.provider)
        return tagValues(([displayFormat(fields)] + services + (includeGenres ? [fields["Genres"] ?? ""] : [])).joined(separator: ","))
    }
    static func captureIDs(_ fields: [String: String]) -> [String] {
        let ids = (fields["Share Capture IDs"] ?? "").split(separator: ",").map(String.init) + [fields["Share Capture ID"]].compactMap { $0 }
        return Array(Set(ids)).sorted()
    }
    static func isPortrait(_ format: String) -> Bool { ["book", "movie", "tv show", "tv"].contains(format.lowercased()) }
    static func sameTitle(_ lhs: String, fields left: [String: String], _ rhs: String, fields right: [String: String]) -> Bool {
        let a = lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, a == b, action(for: displayFormat(left)) == "Watch", action(for: displayFormat(right)) == "Watch" else { return false }
        for key in ["Year", "Season", "Episode", "Series Title"] {
            if let first = left[key], !first.isEmpty, let second = right[key], !second.isEmpty, first.localizedCaseInsensitiveCompare(second) != .orderedSame { return false }
        }
        let concrete = ["Movie", "TV Show", "Episode"]
        let first = displayFormat(left), second = displayFormat(right)
        return !concrete.contains(first) || !concrete.contains(second) || first == second
    }
    static let defaults = UserDefaults(suiteName: "group.com.surratt.TaskFlow") ?? .standard
    static let destinationsKey = "TaskFlow.readingDestinations"
    static func preferenceKey(watch: Bool) -> String { watch ? "TaskFlow.watchLaterListID" : "TaskFlow.readLaterListID" }

    /// Share providers can supply text as attributed strings or UTF-8 data.
    static func sharedText(from value: Any?) -> String? {
        switch value {
        case let url as URL: return url.absoluteString
        case let text as String: return text
        case let text as NSAttributedString: return text.string
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    static func preferredShareText(_ values: [String]) -> String {
        values.first { webURL(in: $0).flatMap { provider(for: $0) } != nil }
            ?? values.first { webURL(in: $0) != nil }
            ?? values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    static func artworkAspect(width: Double, height: Double, format: String) -> Double {
        guard width > 0, height > 0, width.isFinite, height.isFinite else {
            return isPortrait(format) ? 0.75 : action(for: format) == "Listen" ? 1 : 1.6
        }
        return min(2, max(0.6, width / height))
    }

    static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), isWebURL(url), !trimmed.contains(where: { $0.isWhitespace }) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let urls = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).filter(isWebURL)
        return urls.first { provider(for: $0) != nil } ?? urls.first
    }
    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
    static func format(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        if let service = provider(for: url), ["Netflix", "Prime Video", "HBO Max", "Apple TV", "Disney+", "Hulu", "Peacock", "Paramount+"].contains(service) {
            if path.contains("/episode/") || path.contains("/episodes/") { return "Episode" }
            if path.contains("/movie/") || path.contains("/movies/") { return "Movie" }
            if path.contains("/show/") || path.contains("/series/") { return "TV Show" }
            return "Video"
        }
        if ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "tiktok.com", "twitch.tv", "tv.apple.com", "netflix.com", "disneyplus.com", "hulu.com", "max.com", "primevideo.com", "peacocktv.com", "paramountplus.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "Video" }
        if ["podcasts.apple.com", "soundcloud.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) || (["open.spotify.com", "music.apple.com"].contains(host) && !url.path.hasPrefix("/user/")) || ["mp3", "m4a", "wav", "aac", "ogg"].contains(url.pathExtension.lowercased()) { return "Audio" }
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) { return "Video" }
        return "Article"
    }
    /// Correct older generic captures while preserving explicit non-article formats.
    static func displayFormat(_ fields: [String: String]) -> String {
        let stored = (fields["Format"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty || stored == "Article" || stored == "Video" {
            if let raw = fields["Source Link"], let url = URL(string: raw), isWebURL(url) {
                let inferred = format(for: url)
                if inferred != "Article" { return inferred }
            }
        }
        return stored.isEmpty ? "Article" : stored
    }
    static func isPending(_ fields: [String: String], watch: Bool) -> Bool {
        fields["Merged Into"] == nil && fields["Progress"] != "Finished" && fields["Progress"] != "Dropped" && (action(for: displayFormat(fields)) == "Watch") == watch
    }
    static func action(for format: String) -> String {
        switch format.lowercased() {
        case "video", "movie", "tv", "tv show", "episode": return "Watch"
        case "audio", "podcast", "music": return "Listen"
        default: return "Read"
        }
    }
    static func symbol(for format: String) -> String {
        switch action(for: format) {
        case "Watch": return "play.rectangle"
        case "Listen": return "headphones"
        default: return "doc.text"
        }
    }
    static func previewRetryFields(_ fields: [String: String], title: String) -> [String: String] {
        var result = fields
        guard let raw = fields["Source Link"], let url = URL(string: raw), isWebURL(url) else { return result }
        result["Preview Status"] = "Pending"
        // A retry can refine an unresolved generic type, while retaining a chosen movie/book/etc.
        if ["Article", "Video"].contains(fields["Format"] ?? ""), fields["Format"] == format(for: url) {
            result["Captured Format"] = fields["Format"]
        }
        if title == url.host || (provider(for: url) == "Netflix" && title.lowercased().hasSuffix("| netflix official site")) {
            result["Captured Title"] = title
        }
        return result
    }

    static func enrich(_ fields: [String: String], with fetched: [String: String]) -> [String: String] {
        var result = fields
        for (key, value) in fetched where (fields[key] ?? "").isEmpty || (key == "Format" && fields[key] == fields["Captured Format"]) {
            if ["Thumbnail URL", "Local Preview"].contains(key), fields["Suppress Preview"] == "true" { continue }
            if key == "Local Preview", !(fields["Thumbnail URL"] ?? "").isEmpty { continue }
            result[key] = value
        }
        return result
    }
    struct ShowArtwork: Codable, Identifiable {
        let id: Int
        let name: String
        let url: URL
        let premiered: String?
        let image: Artwork?
        struct Artwork: Codable { let medium: URL?; let original: URL? }
        var genres: [String]? = nil
        var status: String? = nil
        var summary: String? = nil
        var averageRuntime: Int? = nil
        var network: Channel? = nil
        var webChannel: Channel? = nil
        struct Channel: Codable { let name: String }
        var thumbnail: URL? { image?.medium ?? image?.original }
    }
    private struct ShowSearchResult: Decodable { let show: ShowArtwork }
    static func showArtworkResults(from data: Data) throws -> [ShowArtwork] {
        try JSONDecoder().decode([ShowSearchResult].self, from: data).map(\.show).filter {
            $0.thumbnail?.scheme == "https" && $0.url.scheme == "https" && $0.url.host == "www.tvmaze.com"
        }
    }
    static func searchShowArtwork(title: String) async throws -> [ShowArtwork] {
        var url = URLComponents(string: "https://api.tvmaze.com/search/shows")!
        url.queryItems = [URLQueryItem(name: "q", value: String(title.prefix(200)))]
        var request = URLRequest(url: url.url!, timeoutInterval: 12)
        request.setValue("TaskFlow/1.10", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 1_000_000 else { throw URLError(.badServerResponse) }
        return try showArtworkResults(from: data)
    }

    struct ShowEpisode: Codable, Identifiable, Equatable {
        let id: Int
        let name: String
        let season: Int
        let number: Int?
        let airdate: String?
        let airstamp: String?
        let runtime: Int?
        let summary: String?
        var label: String { "S\(season) E\(number.map(String.init) ?? "Special")" }
        var release: Date? {
            if let airstamp, let date = ISO8601DateFormatter().date(from: airstamp) { return date }
            guard let airdate else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            return formatter.date(from: airdate)
        }
    }
    struct ShowTracking: Codable {
        var show: ShowArtwork
        var episodes: [ShowEpisode]
        var cast: [String]
        var watched: Set<Int> = []
        var refreshedAt = Date()
        var ordered: [ShowEpisode] { episodes.sorted { $0.season == $1.season ? ($0.number ?? Int.max, $0.id) < ($1.number ?? Int.max, $1.id) : $0.season < $1.season } }
        func next(now: Date = Date()) -> ShowEpisode? { ordered.first { !watched.contains($0.id) && $0.release.map { $0 <= now } == true } }
        func upcoming(now: Date = Date()) -> ShowEpisode? { episodes.filter { $0.release.map { $0 > now } == true }.sorted { $0.release! < $1.release! }.first }
        func progress(now: Date = Date()) -> String {
            if next(now: now) != nil { return watched.isEmpty ? "Saved" : "In Progress" }
            guard episodes.contains(where: { $0.release.map { $0 <= now } == true }) else { return "Saved" }
            return show.status == "Ended" && episodes.allSatisfy { watched.contains($0.id) } ? "Finished" : "Caught Up"
        }
    }
    static let watchGroupOrder = ["Continue Watching", "Ready for Next Season", "Up to Date", "Not Started", "Saved for Later", "Finished Series", "Finished", "Dropped"]

    static func watchGroup(_ fields: [String: String], completed: Bool, now: Date = Date()) -> String {
        let catalog = tracking(fields)
        if completed || fields["Progress"] == "Finished" { return catalog == nil ? "Finished" : "Finished Series" }
        if fields["Progress"] == "Dropped" { return "Dropped" }
        guard let catalog else { return "Saved for Later" }
        let knownWatched = catalog.watched.intersection(Set(catalog.episodes.map(\.id)))
        if catalog.show.status == "Ended", !catalog.episodes.isEmpty, catalog.episodes.allSatisfy({ knownWatched.contains($0.id) }) { return "Finished Series" }
        if knownWatched.isEmpty { return "Not Started" }
        guard let next = catalog.next(now: now) else { return "Up to Date" }
        let previous = catalog.episodes.filter { $0.season > 0 && $0.season < next.season }
        if let season = previous.map(\.season).max(),
           previous.filter({ $0.season == season }).allSatisfy({ knownWatched.contains($0.id) }),
           !catalog.episodes.contains(where: { $0.season == next.season && knownWatched.contains($0.id) }) {
            return "Ready for Next Season"
        }
        return "Continue Watching"
    }

    static func watchProgressSummary(_ fields: [String: String], completed: Bool, now: Date = Date()) -> String? {
        guard let catalog = tracking(fields) else { return nil }
        let group = watchGroup(fields, completed: completed, now: now)
        switch group {
        case "Finished Series": return "Series finished"
        case "Dropped": return "Stopped watching"
        case "Ready for Next Season":
            guard let next = catalog.next(now: now), let previous = catalog.episodes.filter({ $0.season > 0 && $0.season < next.season }).map(\.season).max() else { return nil }
            return "Season \(previous) complete · Season \(next.season) ready · " + next.label
        case "Continue Watching":
            guard let next = catalog.next(now: now) else { return nil }
            let remaining = catalog.episodes.filter { $0.season == next.season && !catalog.watched.contains($0.id) && $0.release.map { $0 <= now } == true }.count
            return "Continue: " + next.label + " · \(remaining) released episode\(remaining == 1 ? "" : "s") remaining"
        case "Not Started":
            let released = catalog.episodes.filter { !catalog.watched.contains($0.id) && $0.release.map { $0 <= now } == true }.count
            return "Not started · \(released) released episode\(released == 1 ? "" : "s") available"
        default:
            if let next = catalog.upcoming(now: now), let date = next.release {
                return "Up to date · Next episode " + date.formatted(date: .abbreviated, time: .omitted)
            }
            return "Up to date · Next release unknown"
        }
    }

    static func remainingWatchTime(_ fields: [String: String], now: Date = Date()) -> String? {
        guard let catalog = tracking(fields), let next = catalog.next(now: now) else { return nil }
        let remaining = catalog.ordered.filter { $0.season == next.season && !catalog.watched.contains($0.id) && $0.release.map { $0 <= now } == true }
        guard !remaining.isEmpty, remaining.allSatisfy({ ($0.runtime ?? 0) > 0 }) else { return nil }
        let minutes = remaining.reduce(0) { $0 + ($1.runtime ?? 0) }
        return "\(remaining.count) episode\(remaining.count == 1 ? "" : "s") · about \(minutes) min left in season"
    }

    static func newestUnwatchedRelease(_ fields: [String: String], now: Date = Date()) -> Date? {
        guard let catalog = tracking(fields) else { return nil }
        return catalog.episodes.filter { !catalog.watched.contains($0.id) }
            .compactMap(\.release).filter { $0 <= now }.max()
    }

    static func hasNewEpisode(_ fields: [String: String], now: Date = Date()) -> Bool {
        guard let catalog = tracking(fields), !catalog.watched.isEmpty,
              let release = newestUnwatchedRelease(fields, now: now) else { return false }
        return now.timeIntervalSince(release) <= 14 * 24 * 60 * 60
    }

    enum EpisodeFeedMode: String {
        case continuing, newEpisodes, comingSoon
        var title: String { switch self { case .continuing: "Continue Watching"; case .newEpisodes: "New Episodes"; case .comingSoon: "Coming Soon" } }
        var emptyMessage: String { switch self {
        case .continuing: "No episodes to continue. Match a show and start tracking in TaskFlow."
        case .newEpisodes: "No unwatched episodes released in the last 14 days."
        case .comingSoon: "No upcoming release dates are known for your matched shows."
        } }
    }
    static func hasEpisodeCalendarLink(notes: String?, episodeID: Int) -> Bool {
        notes?.components(separatedBy: .newlines).contains("TaskFlow episode: \(episodeID)") == true
    }
    struct EpisodeFeedSource {
        let taskID: String
        let title: String
        let fields: [String: String]
    }
    struct EpisodeFeedItem: Identifiable {
        var id: String { "\(taskID):\(episode.id)" }
        let taskID: String
        let title: String
        let fields: [String: String]
        let episode: ShowEpisode
        let showID: Int
        let release: Date
    }
    /// Shared by the app and widgets so watched, dropped and undated episodes agree.
    static func episodeFeed(_ sources: [EpisodeFeedSource], mode: EpisodeFeedMode, now: Date = Date(), onePerShow: Bool = false) -> [EpisodeFeedItem] {
        var items: [EpisodeFeedItem] = []
        var seen = Set<String>()
        for source in sources.sorted(by: { $0.taskID < $1.taskID }) {
            guard source.fields["Merged Into"] == nil, !["Dropped", "Finished"].contains(source.fields["Progress"] ?? ""), let catalog = tracking(source.fields) else { continue }
            let candidates: [(ShowEpisode, Date)]
            switch mode {
            case .continuing:
                guard !catalog.watched.isEmpty || source.fields["Progress"] == "In Progress" else { continue }
                candidates = catalog.next(now: now).flatMap { episode in episode.release.map { [(episode, $0)] } } ?? []
            case .newEpisodes, .comingSoon:
                candidates = catalog.episodes.compactMap { episode in
                    guard !catalog.watched.contains(episode.id), let date = episode.release else { return nil }
                    if mode == .comingSoon { guard date > now else { return nil } }
                    else { guard date <= now && date >= now.addingTimeInterval(-14 * 86400) else { return nil } }
                    return (episode, date)
                }
            }
            for (episode, date) in candidates {
                guard seen.insert("\(catalog.show.id):\(episode.id)").inserted else { continue }
                items.append(.init(taskID: source.taskID, title: source.title, fields: source.fields, episode: episode, showID: catalog.show.id, release: date))
            }
        }
        items.sort {
            if $0.release != $1.release { return mode == .newEpisodes ? $0.release > $1.release : $0.release < $1.release }
            if $0.showID == $1.showID {
                if $0.episode.season != $1.episode.season { return $0.episode.season < $1.episode.season }
                if $0.episode.number != $1.episode.number { return ($0.episode.number ?? Int.max) < ($1.episode.number ?? Int.max) }
                if $0.episode.id != $1.episode.id { return $0.episode.id < $1.episode.id }
            }
            return $0.id < $1.id
        }
        if onePerShow {
            var shows = Set<Int>()
            items = items.filter { shows.insert($0.showID).inserted }
        }
        return items
    }
    static func tracking(_ fields: [String: String]) -> ShowTracking? {
        fields["Show Tracking"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ShowTracking.self, from: $0) }
    }
    static func encodeTracking(_ tracking: ShowTracking) -> String {
        (try? JSONEncoder().encode(tracking)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func plainSummary(_ html: String?) -> String {
        (html ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }
    static func catalogSearch(title: String) async throws -> [ShowArtwork] {
        var components = URLComponents(string: "https://api.tvmaze.com/search/shows")!
        components.queryItems = [URLQueryItem(name: "q", value: String(title.prefix(200)))]
        let data = try await catalogData(components.url!)
        return try JSONDecoder().decode([ShowSearchResult].self, from: data).map(\.show)
    }
    static func catalogData(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 4_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
    static func fetchTracking(id: Int) async throws -> ShowTracking {
        guard id > 0 else { throw URLError(.badURL) }
        async let showData = catalogData(URL(string: "https://api.tvmaze.com/shows/\(id)")!)
        async let episodeData = catalogData(URL(string: "https://api.tvmaze.com/shows/\(id)/episodes?specials=1")!)
        async let castData = catalogData(URL(string: "https://api.tvmaze.com/shows/\(id)/cast")!)
        struct Cast: Decodable { let person: Person; struct Person: Decodable { let name: String } }
        let show = try JSONDecoder().decode(ShowArtwork.self, from: await showData)
        let episodes = try JSONDecoder().decode([ShowEpisode].self, from: await episodeData)
        let cast = (try? JSONDecoder().decode([Cast].self, from: await castData))?.prefix(12).map { $0.person.name } ?? []
        return ShowTracking(show: show, episodes: episodes, cast: cast)
    }

    struct Capture: Codable, Identifiable {
        var id = UUID()
        var url: String
        var title: String
        var note: String
        var listID: String
        var watch: Bool
        var previewFilename: String? = nil
    }
    private static var previewDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.surratt.TaskFlow")?.appendingPathComponent("SharedMediaPreviews", isDirectory: true)
    }
    static func storePreview(_ data: Data, id: UUID) -> String? {
        guard data.count <= 512_000, let directory = previewDirectory else { return nil }
        let name = id.uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 120 {
                let sorted = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for old in sorted.prefix(files.count - 120) { try? FileManager.default.removeItem(at: old) }
            }
            return name
        } catch { return nil }
    }
    static func capturePreviewData(_ name: String?) -> Data? {
        guard let name, name.hasSuffix(".jpg"), UUID(uuidString: String(name.dropLast(4))) != nil,
              let directory = previewDirectory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }
    private static var captureDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.surratt.TaskFlow")?
            .appendingPathComponent("MediaCaptures", isDirectory: true)
    }
    static func captures() -> [Capture] {
        guard let directory = captureDirectory else { return [] }
        return CaptureQueue(directory: directory).captures()
    }
    static func enqueue(_ capture: Capture) throws {
        guard let directory = captureDirectory else { throw CocoaError(.fileWriteNoPermission) }
        try CaptureQueue(directory: directory).enqueue(capture)
    }
    static func acknowledge(_ id: UUID) {
        guard let directory = captureDirectory else { return }
        try? CaptureQueue(directory: directory).acknowledge(id)
    }

    struct CaptureQueue {
        let directory: URL
        func captures() -> [Capture] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
            return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
                guard $0.pathExtension == "json", let data = try? Data(contentsOf: $0) else { return nil }
                return try? JSONDecoder().decode(Capture.self, from: data)
            }
        }
        /// One atomic file per capture prevents imports from overwriting concurrent shares.
        func enqueue(_ capture: Capture) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(capture)
            try data.write(to: directory.appendingPathComponent(capture.id.uuidString + ".json"), options: .atomic)
        }
        func acknowledge(_ id: UUID) throws {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
        }
    }
}

/// One immutable file per tap avoids overwriting app metadata from a widget process.
struct WatchedEpisodeAction: Codable, Identifiable {
    var id = UUID()
    let taskID: String
    let metadataID: String
    let showID: Int
    let episodeID: Int
    var createdAt = Date()
}

enum WatchedEpisodeActionStore {
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.surratt.TaskFlow")?.appendingPathComponent("WatchedEpisodeActions", isDirectory: true)
    }
    static func record(_ action: WatchedEpisodeAction, directory: URL? = WatchedEpisodeActionStore.directory) throws {
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(action).write(to: directory.appendingPathComponent(action.id.uuidString + ".json"), options: .atomic)
    }
    static func pending(directory: URL? = WatchedEpisodeActionStore.directory) -> [WatchedEpisodeAction] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), data.count < 16_384 else { return nil }
            return try? JSONDecoder().decode(WatchedEpisodeAction.self, from: data)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    static func acknowledge(_ action: WatchedEpisodeAction, directory: URL? = WatchedEpisodeActionStore.directory) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(action.id.uuidString + ".json"))
    }
    static func applying(_ actions: [WatchedEpisodeAction], fields: [String: String], taskID: String, metadataID: String, now: Date = Date()) -> [String: String] {
        actions.filter { $0.taskID == taskID || (!metadataID.isEmpty && $0.metadataID == metadataID) }.reduce(fields) { current, action in
            ReadingMedia.markingEpisodeWatched(current, showID: action.showID, episodeID: action.episodeID, now: now) ?? current
        }
    }
}

extension ReadingMedia {
    static func markingEpisodeWatched(_ fields: [String: String], showID: Int, episodeID: Int, now: Date = Date()) -> [String: String]? {
        guard fields["Progress"] != "Dropped", fields["Progress"] != "Finished", fields["Merged Into"] == nil,
              var catalog = tracking(fields), catalog.show.id == showID,
              let episode = catalog.episodes.first(where: { $0.id == episodeID }), let release = episode.release, release <= now else { return nil }
        if catalog.watched.contains(episodeID) { return fields }
        catalog.watched.insert(episodeID)
        var updated = fields
        updated["Show Tracking"] = encodeTracking(catalog)
        updated["Progress"] = catalog.progress(now: now)
        updated["Season"] = catalog.next(now: now).map { String($0.season) }
        updated["Episode"] = catalog.next(now: now)?.number.map(String.init)
        return updated
    }
    static func widgetEpisode(_ fields: [String: String], now: Date = Date()) -> ShowEpisode? {
        guard fields["Progress"] != "Dropped", fields["Progress"] != "Finished", fields["Merged Into"] == nil, let catalog = tracking(fields) else { return nil }
        let displayed = fields["Widget Episode ID"].flatMap(Int.init)
        let episode = displayed.flatMap { id in catalog.episodes.first { $0.id == id } } ?? (displayed == nil ? catalog.next(now: now) : nil)
        guard let episode, !catalog.watched.contains(episode.id), episode.release.map({ $0 <= now }) == true else { return nil }
        return episode
    }
}

/// Shared by notification handling and widgets so an episode tap can retire its alerts.
enum EpisodeNotificationActions {
    static let category = "TaskFlow.EpisodeRelease"
    static let upcomingCategory = "TaskFlow.EpisodeReleaseUpcoming"
    static let watched = "TaskFlow.MarkEpisodeWatched"
    static let snooze = "TaskFlow.RemindEpisodeLater"
    static let snoozePrefix = "taskflow-episode-snooze-"
    static let taskKey = "taskflowTaskID"
    static let showKey = "taskflowEpisodeShowID"
    static let episodeKey = "taskflowEpisodeID"
    static let labelKey = "taskflowEpisodeLabel"
    static let titleKey = "taskflowEpisodeTitle"
    static var categories: Set<UNNotificationCategory> {
        let mark = UNNotificationAction(identifier: watched, title: "Mark Watched", options: [])
        let later = UNNotificationAction(identifier: snooze, title: "Remind Me Later", options: [])
        return [UNNotificationCategory(identifier: category, actions: [mark, later], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: upcomingCategory, actions: [later], intentIdentifiers: [], options: [])]
    }
    static func snoozeRequest(content: UNNotificationContent, canMarkWatched: Bool) -> UNNotificationRequest? {
        guard let taskID = content.userInfo[taskKey] as? String, !taskID.isEmpty,
              let showID = content.userInfo[showKey] as? Int, let episodeID = content.userInfo[episodeKey] as? Int,
              let copy = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        copy.title = "Episode Reminder"
        copy.body = [content.userInfo[titleKey] as? String, content.userInfo[labelKey] as? String].compactMap { $0 }.joined(separator: " · ") + ". Open your saved show when you're ready."
        copy.categoryIdentifier = canMarkWatched ? category : upcomingCategory
        return UNNotificationRequest(identifier: snoozePrefix + taskID + "-\(showID)-\(episodeID)", content: copy, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
    }
    static func matches(_ content: UNNotificationContent, taskID: String, showID: Int, episodeID: Int) -> Bool {
        content.userInfo[taskKey] as? String == taskID && content.userInfo[showKey] as? Int == showID && content.userInfo[episodeKey] as? Int == episodeID
    }
    static func retire(taskID: String, showID: Int, episodeID: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { matches($0.content, taskID: taskID, showID: showID, episodeID: episodeID) }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { matches($0.request.content, taskID: taskID, showID: showID, episodeID: episodeID) }.map { $0.request.identifier })
    }
}

/// Each text share has its own atomic file, so sharing again cannot replace an earlier capture.
struct TextShareCapture: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    let text: String
    let kind: String

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.surratt.TaskFlow")?
            .appendingPathComponent("TextShareCaptures", isDirectory: true)
    }
    func enqueue(directory: URL? = Self.directory) throws {
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
    }
    static func pending(directory: URL? = Self.directory) -> [Self] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    func acknowledge(directory: URL? = Self.directory) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
}
