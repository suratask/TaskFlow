import Foundation
import UserNotifications
import CloudKit
import EventKit
import Observation
import SwiftUI
import WidgetKit
import LinkPresentation
import UIKit

/// Title, creator, thumbnail, and reading time for a saved link, read from the page's HTML.
struct ReadingLinkMetadata: Equatable, Sendable {
    var title = ""
    var creator = ""
    var format = ""
    var thumbnailURL: URL?
    var estimatedMinutes: Int?
    var mediaFields: [String: String] = [:]

    /// Fields for `SpecializedTaskDetails`, leaving out anything unknown.
    var fields: [String: String] {
        var result: [String: String] = mediaFields
        if !creator.isEmpty { result["Creator"] = creator }
        if !format.isEmpty { result["Format"] = format }
        if let thumbnailURL { result["Thumbnail URL"] = thumbnailURL.absoluteString }
        if let estimatedMinutes { result["Estimated Minutes"] = String(estimatedMinutes) }
        return result
    }

    private static let maximumBytes = 1_000_000

    static func fetch(_ url: URL) async -> ReadingLinkMetadata? {
        var result = await fetchHTML(url)
        if result?.thumbnailURL == nil, let preview = await fetchLinkPreview(url) {
            if result == nil { result = preview }
            else {
                if result?.title.isEmpty == true { result?.title = preview.title }
                result?.mediaFields.merge(preview.mediaFields) { existing, _ in existing }
            }
        }
        return result
    }

    @MainActor
    private static func fetchLinkPreview(_ url: URL) async -> ReadingLinkMetadata? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let metadata: LPLinkMetadata? = await withCheckedContinuation { continuation in
            provider.startFetchingMetadata(for: url) { metadata, _ in continuation.resume(returning: metadata) }
        }
        guard let metadata else { return nil }
        let resolved = metadata.url ?? url
        var result = ReadingLinkMetadata(title: ReadingMedia.cleanTitle(metadata.title ?? "", url: resolved), format: ReadingMedia.format(for: resolved))
        result.mediaFields["Resolved Link"] = resolved.absoluteString
        result.mediaFields["Saved From"] = ReadingMedia.provider(for: resolved)
        if let imageProvider = metadata.imageProvider {
            let data: Data? = await withCheckedContinuation { continuation in
                imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in continuation.resume(returning: data) }
            }
            if let data, data.count <= 8_000_000, let image = UIImage(data: data) {
                let ratio = min(1, 640 / max(image.size.width, image.size.height))
                let rendererFormat = UIGraphicsImageRendererFormat(); rendererFormat.scale = 1
                let resized = UIGraphicsImageRenderer(size: CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio)), format: rendererFormat).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))))
                }
                if let jpeg = resized.jpegData(compressionQuality: 0.8), let filename = ReadingMedia.storePreview(jpeg, id: UUID()) { result.mediaFields["Local Preview"] = filename }
            }
        }
        return result
    }

    // Netflix's public title pages place structured metadata after several MB of CSS.
    private static func maximumBytes(for url: URL) -> Int {
        ReadingMedia.provider(for: url) == "Netflix" ? 4_000_000 : maximumBytes
    }

    static func parseResponse(data: Data, baseURL: URL, isComplete: Bool) -> ReadingLinkMetadata? {
        guard !data.isEmpty else { return nil }
        let limit = maximumBytes(for: baseURL)
        let prefix = data.prefix(limit)
        guard let html = String(data: prefix, encoding: .utf8) ?? String(data: prefix, encoding: .isoLatin1) else { return nil }
        return parse(html: html, baseURL: baseURL, isComplete: isComplete && data.count <= limit)
    }

    private static func fetchHTML(_ url: URL) async -> ReadingLinkMetadata? {
        guard ReadingMedia.isWebURL(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        let baseURL = response.url ?? url
        let limit = maximumBytes(for: baseURL)
        var data = Data()
        data.reserveCapacity(min(limit, 64_000))
        var complete = true
        do {
            for try await byte in bytes {
                if Task.isCancelled { return nil }
                data.append(byte)
                if data.count >= limit { complete = false; break }
            }
        } catch {
            // A closed connection can still contain a complete metadata block.
            if Task.isCancelled { return nil }
            complete = false
        }
        return parseResponse(data: data, baseURL: baseURL, isComplete: complete)
    }

    static func parse(html: String, baseURL: URL, isComplete: Bool = true) -> ReadingLinkMetadata {
        var result = ReadingLinkMetadata()
        result.title = meta(["og:title", "twitter:title"], in: html) ?? element("title", in: html) ?? ""
        result.creator = meta(["author", "article:author", "book:author", "og:site_name", "twitter:creator"], in: html) ?? ""
        if result.creator.lowercased().hasPrefix("http") { result.creator = "" }
        if let image = meta(["og:image:secure_url", "og:image", "twitter:image"], in: html),
           let imageURL = URL(string: image, relativeTo: baseURL)?.absoluteURL, imageURL.scheme?.lowercased() == "https" {
            result.thumbnailURL = imageURL
        }
        let type = (meta(["og:type"], in: html) ?? "").lowercased()
        if type.contains("movie") { result.format = "Movie" }
        else if type.contains("tv_show") { result.format = "TV Show" }
        else if type.contains("episode") { result.format = "Episode" }
        else if type.contains("video") || ReadingMedia.action(for: ReadingMedia.format(for: baseURL)) == "Watch" {
            result.format = ReadingMedia.action(for: ReadingMedia.format(for: baseURL)) == "Watch" ? ReadingMedia.format(for: baseURL) : "Video"
        } else if type.contains("music") || type.contains("audio") || ReadingMedia.format(for: baseURL) == "Audio" {
            result.format = "Audio"
        } else if type.contains("book") {
            result.format = "Book"
        } else if type.contains("article") {
            result.format = "Article"
        }
        if result.format.isEmpty { result.format = ReadingMedia.format(for: baseURL) }
        let structured = structuredMedia(in: html)
        result.mediaFields = structured.fields
        if let format = structured.fields["Format"], format != "Article" || ReadingMedia.action(for: result.format) != "Watch" { result.format = format }
        if let title = structured.title, !title.isEmpty { result.title = title }
        result.mediaFields.removeValue(forKey: "Thumbnail URL")
        if let raw = structured.fields["Thumbnail URL"], let image = URL(string: raw, relativeTo: baseURL)?.absoluteURL, image.scheme == "https" { result.thumbnailURL = image }
        if let service = ReadingMedia.provider(for: baseURL) { result.mediaFields["Saved From"] = service }
        result.mediaFields["Resolved Link"] = baseURL.absoluteString
        result.title = ReadingMedia.cleanTitle(result.title, url: baseURL)
        if result.format == "Article", isComplete {
            let words = wordCount(html)
            if words >= 150 { result.estimatedMinutes = max(1, Int((Double(words) / 230).rounded())) }
        }
        return result
    }

    private static func structuredMedia(in html: String) -> (title: String?, fields: [String: String]) {
        guard let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#, options: [.caseInsensitive]) else { return (nil, [:]) }
        var nodes: [[String: Any]] = []
        func collect(_ value: Any, depth: Int = 0) {
            guard depth < 12 else { return }
            if let array = value as? [Any] { for item in array { collect(item, depth: depth + 1) } }
            if let object = value as? [String: Any] {
                nodes.append(object)
                for key in ["@graph", "mainEntity"] { if let child = object[key] { collect(child, depth: depth + 1) } }
            }
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html), let data = String(html[range]).data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            collect(value)
        }
        let formats = ["Movie": "Movie", "TVSeries": "TV Show", "TVEpisode": "Episode", "VideoObject": "Video", "PodcastEpisode": "Podcast", "AudioObject": "Audio", "Book": "Book", "Article": "Article", "NewsArticle": "Article", "BlogPosting": "Article"]
        func format(_ object: [String: Any]) -> String? {
            let types = (object["@type"] as? [String]) ?? [object["@type"] as? String ?? ""]
            return types.compactMap { formats[$0.components(separatedBy: "/").last ?? $0] }.first
        }
        guard let node = nodes.first(where: { ["Movie", "TV Show", "Episode"].contains(format($0) ?? "") }) ?? nodes.first(where: { format($0) != nil }) else { return (nil, [:]) }
        var fields: [String: String] = [:]
        fields["Format"] = format(node)
        func string(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        if let published = string(node["datePublished"]) ?? string(node["dateCreated"]), published.count >= 4, let year = Int(published.prefix(4)), year > 1800 { fields["Year"] = String(year) }
        if let genres = node["genre"] as? [String] { fields["Genres"] = genres.joined(separator: ", ") }
        else if let genre = string(node["genre"]) { fields["Genres"] = genre }
        fields["Episode"] = string(node["episodeNumber"])
        if let season = node["partOfSeason"] as? [String: Any] { fields["Season"] = string(season["seasonNumber"]) }
        if let series = node["partOfSeries"] as? [String: Any] { fields["Series Title"] = string(series["name"]) }
        let image = node["image"]
        let firstImage = (image as? [Any])?.first ?? image
        fields["Thumbnail URL"] = string(firstImage) ?? (firstImage as? [String: Any]).flatMap { string($0["url"]) ?? string($0["contentUrl"]) }
        if let duration = string(node["duration"]), let regex = try? NSRegularExpression(pattern: #"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$"#), let match = regex.firstMatch(in: duration, range: NSRange(duration.startIndex..., in: duration)) {
            func component(_ index: Int) -> Int { Range(match.range(at: index), in: duration).flatMap { Int(duration[$0]).map { min($0, 100_000) } } ?? 0 }
            let minutes = component(1) * 60 + component(2) + (component(3) > 0 ? 1 : 0)
            if minutes > 0 { fields["Runtime Minutes"] = String(minutes) }
        }
        return (string(node["name"]).map(decodeEntities), fields)
    }

    private static func meta(_ names: [String], in html: String) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            // The content value ends at its own opening quote, so apostrophes inside "…" survive.
            let patterns = [
                "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*?content\\s*=\\s*([\"'])(.*?)\\1",
                "<meta[^>]+?content\\s*=\\s*([\"'])(.*?)\\1[^>]*(?:property|name)\\s*=\\s*[\"']\(escaped)[\"']"
            ]
            for pattern in patterns {
                if let value = firstCapture(pattern, group: 2, in: html), !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func element(_ tag: String, in html: String) -> String? {
        firstCapture("<\(tag)[^>]*>([^<]*)</\(tag)>", group: 1, in: html).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func firstCapture(_ pattern: String, group: Int, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: html) else { return nil }
        return decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&#8217;", "’"), ("&#8211;", "–"), ("&#8212;", "—"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Words of visible body text; scripts, styles, and markup are removed first.
    private static func wordCount(_ html: String) -> Int {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<noscript[\\s\\S]*?</noscript>", "<[^>]+>"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
