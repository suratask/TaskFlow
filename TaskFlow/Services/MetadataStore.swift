import Foundation

struct MetadataSnapshot: Codable, Equatable {
    var taskMetadata: [String: TaskMetadata] = [:]
    var savedTags: [SavedTag] = []
    var quickNotes: [QuickNote] = []
    var eventTags: [String: [String]] = [:]
    var pinnedListIDs: [String] = []
    var listProfiles: [String: SpecializedListProfile] = [:]
    var specializedTasks: [String: SpecializedTaskDetails] = [:]
    var listTemplates: [SpecializedListTemplate] = []
    var syncedSettings: [String: Data] = [:]
    var fieldUpdatedAt: [String: Date] = [:]
    var cloudUpdatedAt = Date.distantPast
    var smartLists: [SmartListDefinition] = [
        SmartListDefinition(title: "High Priority", icon: "exclamationmark.triangle.fill", priority: .high),
        SmartListDefinition(title: "Blocked", icon: "bolt.fill", status: .blocked, blockedOnly: true, includeCompleted: true),
        SmartListDefinition(title: "Flagged Focus", icon: "flag.fill", flaggedOnly: true)
    ]

    init(
        taskMetadata: [String: TaskMetadata] = [:],
        savedTags: [SavedTag] = [],
        quickNotes: [QuickNote] = [],
        eventTags: [String: [String]] = [:],
        pinnedListIDs: [String] = [],
        cloudUpdatedAt: Date = Date.distantPast,
        smartLists: [SmartListDefinition] = [
            SmartListDefinition(title: "High Priority", icon: "exclamationmark.triangle.fill", priority: .high),
            SmartListDefinition(title: "Blocked", icon: "bolt.fill", status: .blocked, blockedOnly: true, includeCompleted: true),
            SmartListDefinition(title: "Flagged Focus", icon: "flag.fill", flaggedOnly: true)
        ]
    ) {
        self.taskMetadata = taskMetadata
        self.savedTags = savedTags
        self.quickNotes = quickNotes
        self.eventTags = eventTags
        self.pinnedListIDs = pinnedListIDs
        self.cloudUpdatedAt = cloudUpdatedAt
        self.smartLists = smartLists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        syncedSettings = try container.decodeIfPresent([String: Data].self, forKey: .syncedSettings) ?? [:]
        fieldUpdatedAt = try container.decodeIfPresent([String: Date].self, forKey: .fieldUpdatedAt) ?? [:]
        taskMetadata = try container.decodeIfPresent([String: TaskMetadata].self, forKey: .taskMetadata) ?? [:]
        if let storedTags = try? container.decode([SavedTag].self, forKey: .savedTags) {
            savedTags = storedTags
        } else {
            let tagNames = try container.decodeIfPresent([String].self, forKey: .savedTags) ?? []
            savedTags = tagNames.map { SavedTag(name: $0, color: Self.defaultColor(for: $0)) }
        }
        quickNotes = try container.decodeIfPresent([QuickNote].self, forKey: .quickNotes) ?? []
        eventTags = try container.decodeIfPresent([String: [String]].self, forKey: .eventTags) ?? [:]
        pinnedListIDs = try container.decodeIfPresent([String].self, forKey: .pinnedListIDs) ?? []
        cloudUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .cloudUpdatedAt) ?? .distantPast
        listProfiles = try container.decodeIfPresent([String: SpecializedListProfile].self, forKey: .listProfiles) ?? [:]
        specializedTasks = try container.decodeIfPresent([String: SpecializedTaskDetails].self, forKey: .specializedTasks) ?? [:]
        listTemplates = try container.decodeIfPresent([SpecializedListTemplate].self, forKey: .listTemplates) ?? []
        smartLists = try container.decodeIfPresent([SmartListDefinition].self, forKey: .smartLists) ?? [
            SmartListDefinition(title: "High Priority", icon: "exclamationmark.triangle.fill", priority: .high),
            SmartListDefinition(title: "Blocked", icon: "bolt.fill", status: .blocked, blockedOnly: true, includeCompleted: true),
            SmartListDefinition(title: "Flagged Focus", icon: "flag.fill", flaggedOnly: true)
        ]
    }

    func remappingListIDs(_ mapping: [String: String]) -> MetadataSnapshot {
        var result = self
        func mapped(_ id: String) -> String { mapping[id] ?? id }
        result.pinnedListIDs = pinnedListIDs.map(mapped)
        result.listProfiles = Dictionary(listProfiles.map { (mapped($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        result.listTemplates = listTemplates.map { var item = $0; item.listID = mapped(item.listID); return item }
        result.smartLists = smartLists.map { var item = $0; item.listID = item.listID.map(mapped); return item }
        result.fieldUpdatedAt = [:]
        for (key, date) in fieldUpdatedAt {
            let revised = key.hasPrefix("listProfiles/") ? "listProfiles/" + mapped(String(key.dropFirst("listProfiles/".count))) : key
            result.fieldUpdatedAt[revised] = max(result.fieldUpdatedAt[revised] ?? .distantPast, date)
        }
        if let data = syncedSettings["TaskFlow.listIcons"],
           let wrapper = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let icons = wrapper["value"] as? [String: String] {
            let mappedIcons = Dictionary(icons.map { (mapped($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
            if mappedIcons != icons {
                result.syncedSettings["TaskFlow.listIcons"] = try? PropertyListSerialization.data(fromPropertyList: ["value": mappedIcons], format: .xml, options: 0)
            }
        }
        return result
    }

    func remappingCalendarIDs(_ mapping: [String: String]) -> MetadataSnapshot {
        var result = self
        let key = "TaskFlow.excludedAvailabilityCalendarIDs"
        if let data = syncedSettings[key],
           let wrapper = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let ids = wrapper["value"] as? [String] {
            let mapped = Array(Set(ids.map { mapping[$0] ?? $0 })).sorted()
            if mapped != ids {
                result.syncedSettings[key] = try? PropertyListSerialization.data(fromPropertyList: ["value": mapped], format: .xml, options: 0)
            }
        }
        return result
    }

    static let dictionaryFields: Set<String> = ["taskMetadata", "eventTags", "listProfiles", "specializedTasks", "syncedSettings"]

    static let arrayFields: Set<String> = ["quickNotes", "savedTags", "smartLists", "listTemplates"]

    static func indexedRecords(_ value: Any?, field: String) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        var values: [String: Any] = [:]
        for item in value as? [[String: Any]] ?? [] {
            if let id = item["id"] as? String ?? (item["name"] as? String)?.lowercased() { values[id] = item }
        }
        return values
    }

    /// Independent sections merge without an unrelated settings edit replacing task data.
    func merging(_ other: MetadataSnapshot) throws -> MetadataSnapshot {
        let encoder = JSONEncoder()
        guard let left = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any],
              let right = try JSONSerialization.jsonObject(with: encoder.encode(other)) as? [String: Any]
        else { throw CocoaError(.coderReadCorrupt) }
        var result = left
        var revisions = fieldUpdatedAt
        for key in Set(left.keys).union(right.keys) where key != "fieldUpdatedAt" && key != "cloudUpdatedAt" {
            if Self.dictionaryFields.contains(key) || Self.arrayFields.contains(key) {
                let unmodifiedSeed = Self.arrayFields.contains(key) && fieldUpdatedAt[key] == nil && !fieldUpdatedAt.keys.contains(where: { $0.hasPrefix(key + "/") }) && !fieldUpdatedAt.isEmpty
                let localValues = unmodifiedSeed ? [:] : Self.indexedRecords(left[key], field: key)
                let remoteUnmodifiedSeed = Self.arrayFields.contains(key) && other.fieldUpdatedAt[key] == nil && !other.fieldUpdatedAt.keys.contains(where: { $0.hasPrefix(key + "/") }) && !other.fieldUpdatedAt.isEmpty
                let remoteValues = remoteUnmodifiedSeed ? [:] : Self.indexedRecords(right[key], field: key)
                var values = localValues
                let prefix = key + "/"
                let tombstones = Set(Set(fieldUpdatedAt.keys).union(other.fieldUpdatedAt.keys).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
                for id in Set(localValues.keys).union(remoteValues.keys).union(tombstones) {
                    let revisionKey = prefix + id
                    let localDate = fieldUpdatedAt[revisionKey] ?? (localValues[id] == nil ? .distantPast : fieldUpdatedAt[key] ?? (fieldUpdatedAt.isEmpty ? cloudUpdatedAt : .distantPast))
                    let remoteDate = other.fieldUpdatedAt[revisionKey] ?? (remoteValues[id] == nil ? .distantPast : other.fieldUpdatedAt[key] ?? (other.fieldUpdatedAt.isEmpty ? other.cloudUpdatedAt : .distantPast))
                    if remoteDate > localDate || (remoteDate == localDate && Self.prefersRemote(remoteValues[id], over: localValues[id])) { values[id] = remoteValues[id] }
                    revisions[revisionKey] = max(localDate, remoteDate)
                }
                if Self.arrayFields.contains(key) {
                    result[key] = values.keys.sorted().compactMap { values[$0] }
                } else { result[key] = values }
            } else {
                let localDate = fieldUpdatedAt[key] ?? (fieldUpdatedAt.isEmpty ? cloudUpdatedAt : .distantPast)
                let remoteDate = other.fieldUpdatedAt[key] ?? (other.fieldUpdatedAt.isEmpty ? other.cloudUpdatedAt : .distantPast)
                if remoteDate > localDate || (remoteDate == localDate && Self.prefersRemote(right[key], over: left[key])) { result[key] = right[key] }
                revisions[key] = max(localDate, remoteDate)
            }
        }
        var merged = try JSONDecoder().decode(MetadataSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
        merged.fieldUpdatedAt = revisions
        merged.cloudUpdatedAt = max(cloudUpdatedAt, other.cloudUpdatedAt)
        return merged
    }

    /// Stable tie-breaking makes simultaneous edits converge on every device.
    private static func prefersRemote(_ remote: Any?, over local: Any?) -> Bool {
        guard let remote else { return local != nil }
        guard let local else { return false }
        guard let lhs = try? JSONSerialization.data(withJSONObject: local, options: [.sortedKeys, .fragmentsAllowed]),
              let rhs = try? JSONSerialization.data(withJSONObject: remote, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
        return lhs.lexicographicallyPrecedes(rhs)
    }

    static func defaultColor(for tag: String) -> TaskTagColor {
        let colors = TaskTagColor.allCases.filter { $0 != .gray }
        let total = tag.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[abs(total) % colors.count]
    }

    var cloudAttachmentReferences: [CloudAttachmentReference] {
        var references: [CloudAttachmentReference] = []

        for metadata in taskMetadata.values {
            references.append(contentsOf: metadata.attachments.cloudReferences)
        }

        for note in quickNotes {
            references.append(contentsOf: note.attachments.cloudReferences)
        }

        var seen = Set<UUID>()
        return references.filter { reference in
            guard !seen.contains(reference.id) else { return false }
            seen.insert(reference.id)
            return true
        }
    }
}

struct CloudAttachmentReference: Hashable {
    let id: UUID
    let localPath: String
    let updatedAt: Date
}

struct CloudAttachmentUpload {
    let reference: CloudAttachmentReference
    let fileURL: URL
}

struct CloudAttachmentDownload {
    let reference: CloudAttachmentReference
    let data: Data
}

// Frozen value snapshots contain only Codable value data. The store itself is
// never captured by a worker; mutation and publication stay with its owner.
private struct PersistenceCopy<Value>: @unchecked Sendable { let value: Value }

final class MetadataStore {
    private let writer = DispatchQueue(label: "TaskFlow.metadata-writer", qos: .utility)
    private var writeGeneration = 0
    private let url: URL
    private let attachmentDirectory: URL
    private var draftURL: URL { url.deletingLastPathComponent().appendingPathComponent("NoteDrafts.json") }
    private var snapshot = MetadataSnapshot()
    var onChange: (() -> Void)?
    private var lastPersistedSnapshot = MetadataSnapshot()
    private var publishedTaskMetadata: [String: TaskMetadata]?
    private var publishedSpecializedTasks: [String: SpecializedTaskDetails]?
    private var publishedListTypes: [String: String]?
    private var publishedSmartLists: [SmartListDefinition]?
    private var batchDepth = 0
    private var hasPendingWrite = false
    private var hasPendingModification = false
    private(set) var persistenceError: String?

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Metadata.json")
        attachmentDirectory = directory.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        load()
        lastPersistedSnapshot = snapshot
    }

    func loadNoteDrafts() -> [NoteEditorRecovery] {
        guard let data = try? Data(contentsOf: draftURL) else { return [] }
        return (try? JSONDecoder().decode([NoteEditorRecovery].self, from: data)) ?? []
    }

    func writeNoteDrafts(_ drafts: [NoteEditorRecovery]) throws {
        let target = draftURL
        try writer.sync { try JSONEncoder().encode(drafts).write(to: target, options: .atomic) }
    }

    @MainActor
    func writeNoteDraftsAsync(_ drafts: [NoteEditorRecovery]) async throws {
        let target = draftURL
        let copy = PersistenceCopy(value: drafts)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async {
                do {
                    try JSONEncoder().encode(copy.value).write(to: target, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Only immutable snapshots cross to the serial writer. Synchronous saves and
    /// background autosaves share this queue, including discard/close flushes.
    @MainActor
    func saveQuickNotesAsync(_ notes: [QuickNote]) async -> Bool {
        guard snapshot.quickNotes != notes || persistenceError != nil else { return true }
        snapshot.quickNotes = notes
        hasPendingModification = true
        writeGeneration &+= 1
        let generation = writeGeneration
        let payload = prepareWrite()
        let copy = PersistenceCopy(value: payload)
        let target = url
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.async {
                    do {
                        try JSONEncoder.pretty.encode(copy.value).write(to: target, options: .atomic)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            if generation == writeGeneration { completeWrite(payload) }
            return true
        } catch {
            if generation == writeGeneration { persistenceError = error.localizedDescription; hasPendingModification = true }
            return false
        }
    }

    var listProfiles: [String: SpecializedListProfile] {
        get { snapshot.listProfiles }
        set { guard snapshot.listProfiles != newValue else { return }; snapshot.listProfiles = newValue; save() }
    }
    var specializedTasks: [String: SpecializedTaskDetails] {
        get { snapshot.specializedTasks }
        set { guard snapshot.specializedTasks != newValue else { return }; snapshot.specializedTasks = newValue; save() }
    }
    var listTemplates: [SpecializedListTemplate] {
        get { snapshot.listTemplates }
        set { guard snapshot.listTemplates != newValue else { return }; snapshot.listTemplates = newValue; save() }
    }

    var smartLists: [SmartListDefinition] {
        get { snapshot.smartLists }
        set {
            snapshot.smartLists = newValue
            save()
        }
    }

    var savedTags: [SavedTag] {
        get { snapshot.savedTags }
        set {
            snapshot.savedTags = normalizedTags(newValue)
            save()
        }
    }

    var quickNotes: [QuickNote] {
        get { snapshot.quickNotes }
        set {
            snapshot.quickNotes = newValue.sorted { $0.createdAt > $1.createdAt }
            save()
        }
    }

    var eventTags: [String: [String]] {
        get { snapshot.eventTags }
        set {
            snapshot.eventTags = newValue.filter { !$0.key.isEmpty }.mapValues(Self.normalizedTagNames)
            save()
        }
    }

    func setEventTags(_ tags: [String], for eventID: String) {
        guard !eventID.isEmpty else { return }
        var values = snapshot.eventTags
        let normalized = Self.normalizedTagNames(tags)
        if normalized.isEmpty { values[eventID] = nil } else { values[eventID] = normalized }
        eventTags = values
    }

    private static func normalizedTagNames(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let name = normalizedTag(raw)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    var pinnedListIDs: [String] {
        get { snapshot.pinnedListIDs }
        set {
            snapshot.pinnedListIDs = normalizedListIDs(newValue)
            save()
        }
    }

    func metadata(for id: String) -> TaskMetadata {
        snapshot.taskMetadata[id, default: TaskMetadata()]
    }

    func metadata(for id: String, cloudID: String) -> TaskMetadata {
        if let cloudMetadata = snapshot.taskMetadata[cloudID] {
            return cloudMetadata
        }

        if let localMetadata = snapshot.taskMetadata[id] {
            snapshot.taskMetadata[cloudID] = localMetadata
            save()
            return localMetadata
        }

        return TaskMetadata()
    }

    func setMetadata(_ metadata: TaskMetadata, for id: String) {
        guard snapshot.taskMetadata[id] != metadata else { return }
        snapshot.taskMetadata[id] = metadata
        save()
    }

    func removeMetadata(for id: String) {
        guard snapshot.taskMetadata[id] != nil else { return }
        snapshot.taskMetadata[id] = nil
        save()
    }

    /// Updates persisted items, including reminders outside the currently loaded lists.
    func replaceTag(_ oldName: String, with newName: String?) {
        let matches: (String) -> Bool = { $0.localizedCaseInsensitiveCompare(oldName) == .orderedSame }
        func transform(_ tags: [String]) -> [String] {
            Self.normalizedTagNames(tags.compactMap { matches($0) ? newName : $0 })
        }
        snapshot.taskMetadata = snapshot.taskMetadata.mapValues { metadata in
            var updated = metadata
            updated.tags = transform(metadata.tags)
            return updated
        }
        snapshot.quickNotes = snapshot.quickNotes.map { note in
            var updated = note
            updated.tags = transform(note.tags)
            return updated
        }
        snapshot.eventTags = snapshot.eventTags.mapValues(transform)
        snapshot.smartLists = snapshot.smartLists.map { list in
            var updated = list
            if let tag = list.requiredTag, matches(tag) { updated.requiredTag = newName }
            updated.rules = list.rules.compactMap { rule in
                guard rule.field == .tag, matches(rule.value) else { return rule }
                guard let newName else { return nil }
                var renamed = rule
                renamed.value = newName
                return renamed
            }
            return updated
        }
        let existingColor = snapshot.savedTags.first { matches($0.name) }?.color ?? MetadataSnapshot.defaultColor(for: oldName)
        snapshot.savedTags.removeAll { matches($0.name) }
        if let newName, !snapshot.savedTags.contains(where: { $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame }) {
            snapshot.savedTags.append(SavedTag(name: newName, color: existingColor))
        }
        snapshot.savedTags = normalizedTags(snapshot.savedTags)
        save()
    }

    func setSyncedSettings(_ settings: [String: Data]) {
        guard snapshot.syncedSettings != settings else { return }
        snapshot.syncedSettings = settings
        save()
    }

    func currentSnapshot() -> MetadataSnapshot {
        snapshot
    }

    func replace(with snapshot: MetadataSnapshot) {
        self.snapshot = snapshot
        save(markModified: false)
    }

    func attachmentURL(for attachment: TaskAttachment) -> URL? {
        if attachment.kind == .url { return TaskAttachment.webURL(from: attachment.urlString ?? "") }
        guard let localPath = attachment.localPath else { return nil }
        return attachmentURL(forLocalPath: localPath)
    }

    func localAttachmentUploads() -> [CloudAttachmentUpload] {
        currentSnapshot().cloudAttachmentReferences.compactMap { reference in
            guard let fileURL = attachmentURL(forLocalPath: reference.localPath),
                  FileManager.default.fileExists(atPath: fileURL.path)
            else { return nil }
            return CloudAttachmentUpload(reference: reference, fileURL: fileURL)
        }
    }

    func missingCloudAttachmentReferences() -> [CloudAttachmentReference] {
        currentSnapshot().cloudAttachmentReferences.filter { reference in
            guard let fileURL = attachmentURL(forLocalPath: reference.localPath) else { return false }
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    func saveDownloadedAttachments(_ downloads: [CloudAttachmentDownload]) {
        for download in downloads {
            guard let destination = attachmentURL(forLocalPath: download.reference.localPath) else { continue }
            try? download.data.write(to: destination, options: [.atomic])
        }
    }

    func makeURLAttachment(from text: String) -> TaskAttachment? {
        guard let url = TaskAttachment.webURL(from: text) else { return nil }
        return TaskAttachment(kind: .url, title: url.host ?? "Web link", urlString: url.absoluteString)
    }

    func saveFileAttachment(data: Data, suggestedName: String, kind: TaskAttachment.Kind) throws -> TaskAttachment {
        let cleanName = sanitizedFileName(suggestedName.isEmpty ? "Attachment" : suggestedName)
        let fileName = "\(UUID().uuidString)-\(cleanName)"
        let destination = attachmentDirectory.appendingPathComponent(fileName)
        try data.write(to: destination, options: [.atomic])
        return TaskAttachment(kind: kind, title: cleanName, localPath: fileName)
    }

    @MainActor
    func saveFileAttachmentAsync(data: Data? = nil, sourceURL: URL? = nil, suggestedName: String, kind: TaskAttachment.Kind) async throws -> TaskAttachment {
        let cleanName = sanitizedFileName(suggestedName.isEmpty ? "Attachment" : suggestedName)
        let fileName = "\(UUID().uuidString)-\(cleanName)"
        let target = attachmentDirectory.appendingPathComponent(fileName)
        let attachment = TaskAttachment(kind: kind, title: cleanName, localPath: fileName)
        return try await withCheckedThrowingContinuation { continuation in
            writer.async {
                let scoped = sourceURL?.startAccessingSecurityScopedResource() ?? false
                defer { if scoped { sourceURL?.stopAccessingSecurityScopedResource() } }
                do {
                    if let sourceURL {
                        // Copy without materializing an entire large file in RAM.
                        try FileManager.default.copyItem(at: sourceURL, to: target)
                    } else if let data {
                        try data.write(to: target, options: .atomic)
                    } else { throw CocoaError(.fileReadUnknown) }
                    continuation.resume(returning: attachment)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func attachmentURL(forLocalPath localPath: String) -> URL? {
        guard localPath == URL(fileURLWithPath: localPath).lastPathComponent else { return nil }
        return attachmentDirectory.appendingPathComponent(localPath)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        // Accept both millisecond (current) and whole-second ISO 8601 dates, so sync revision times survive a relaunch.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSeconds = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractional.date(from: value) ?? wholeSeconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        // Read the current on-disk format, with compatibility for older numeric dates.
        if let loaded = (try? decoder.decode(MetadataSnapshot.self, from: data))
            ?? (try? JSONDecoder().decode(MetadataSnapshot.self, from: data)) {
            snapshot = loaded
        }
    }

    private func save() {
        save(markModified: true)
    }

    /// Coalesces every mutation made inside `body` into a single disk write and widget sync.
    func performBatchUpdates<T>(_ body: () throws -> T) rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, hasPendingWrite {
                hasPendingWrite = false
                writeToDisk()
            }
        }
        return try body()
    }

    private func save(markModified: Bool) {
        hasPendingModification = hasPendingModification || markModified
        guard batchDepth == 0 else {
            hasPendingWrite = true
            return
        }
        writeToDisk()
    }

    /// Frequent note edits do not need to encode every metadata field twice just
    /// to discover which cloud records changed. Keep the general diff for other
    /// mutations and the first migration of legacy field timestamps.
    private func prepareNoteOnlyWrite(now: Date) -> Bool {
        guard lastPersistedSnapshot.cloudUpdatedAt == .distantPast || !snapshot.fieldUpdatedAt.isEmpty else { return false }
        var otherFields = snapshot
        otherFields.quickNotes = lastPersistedSnapshot.quickNotes
        otherFields.fieldUpdatedAt = lastPersistedSnapshot.fieldUpdatedAt
        otherFields.cloudUpdatedAt = lastPersistedSnapshot.cloudUpdatedAt
        guard otherFields == lastPersistedSnapshot else { return false }
        let before = Dictionary(lastPersistedSnapshot.quickNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(snapshot.quickNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if snapshot.quickNotes != lastPersistedSnapshot.quickNotes {
            snapshot.fieldUpdatedAt["quickNotes"] = now
            for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
                snapshot.fieldUpdatedAt["quickNotes/" + id.uuidString] = now
            }
        }
        snapshot.cloudUpdatedAt = now
        return true
    }

    private func prepareWrite() -> MetadataSnapshot {
        if hasPendingModification {
            let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000)
            if prepareNoteOnlyWrite(now: now) {
                hasPendingModification = false
                return snapshot
            }
            if snapshot.fieldUpdatedAt.isEmpty, lastPersistedSnapshot.cloudUpdatedAt > .distantPast,
               let legacyData = try? JSONEncoder().encode(lastPersistedSnapshot),
               let legacy = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any] {
                for key in legacy.keys where key != "cloudUpdatedAt" && key != "fieldUpdatedAt" {
                    snapshot.fieldUpdatedAt[key] = lastPersistedSnapshot.cloudUpdatedAt
                }
            }
            if let oldData = try? JSONEncoder().encode(lastPersistedSnapshot),
               let newData = try? JSONEncoder().encode(snapshot),
               let old = try? JSONSerialization.jsonObject(with: oldData) as? [String: NSObject],
               let new = try? JSONSerialization.jsonObject(with: newData) as? [String: NSObject] {
                for (key, value) in new where key != "cloudUpdatedAt" && key != "fieldUpdatedAt" {
                    if old[key] != value {
                        snapshot.fieldUpdatedAt[key] = now
                        if MetadataSnapshot.dictionaryFields.contains(key) || MetadataSnapshot.arrayFields.contains(key) {
                            let before = MetadataSnapshot.indexedRecords(old[key], field: key) as NSDictionary
                            let after = MetadataSnapshot.indexedRecords(value, field: key) as NSDictionary
                            for id in Set(before.allKeys.compactMap { $0 as? String }).union(after.allKeys.compactMap { $0 as? String }) where (before[id] as? NSObject) != (after[id] as? NSObject) {
                                snapshot.fieldUpdatedAt[key + "/" + id] = now
                            }
                        }
                    }
                }
            }
            snapshot.cloudUpdatedAt = now
        }
        hasPendingModification = false
        return snapshot
    }

    private func writeToDisk() {
        writeGeneration &+= 1
        let payload = prepareWrite()
        let target = url
        do {
            try writer.sync {
                try JSONEncoder.pretty.encode(payload).write(to: target, options: [.atomic])
            }
        } catch {
            persistenceError = error.localizedDescription
            hasPendingModification = true
            return
        }
        completeWrite(payload)
    }

    private func completeWrite(_ payload: MetadataSnapshot) {
        persistenceError = nil
        lastPersistedSnapshot = payload
        syncWidgetMetadata()
        onChange?()
    }

    private func syncWidgetMetadata() {
        let listTypes = snapshot.listProfiles.mapValues { $0.type.rawValue }
        guard publishedTaskMetadata != snapshot.taskMetadata ||
              publishedSpecializedTasks != snapshot.specializedTasks ||
              publishedListTypes != listTypes || publishedSmartLists != snapshot.smartLists else { return }
        var metadata = snapshot.taskMetadata.mapValues {
            TaskFlowSharedTaskMetadata(
                tags: $0.tags,
                status: $0.status.rawValue,
                isFlagged: $0.isFlagged,
                parentID: $0.parentID,
                durationMinutes: $0.durationMinutes,
                blockedByTaskIDs: $0.blockedByTaskIDs
            )
        }
        for (id, details) in snapshot.specializedTasks {
            var value = metadata[id] ?? TaskFlowSharedTaskMetadata()
            value.specializedFields = details.fields
            metadata[id] = value
        }
        TaskFlowSharedSettings.defaults.set(listTypes, forKey: "TaskFlow.specializedListTypes")
        TaskFlowSharedWidgetMetadata.save(metadata)
        TaskFlowSharedWidgetMetadata.saveSmartLists(snapshot.smartLists.map(\.sharedWidgetDefinition))
        publishedTaskMetadata = snapshot.taskMetadata
        publishedSpecializedTasks = snapshot.specializedTasks
        publishedListTypes = listTypes
        publishedSmartLists = snapshot.smartLists
    }

    private func normalizedTags(_ tags: [SavedTag]) -> [SavedTag] {
        var savedByKey: [String: SavedTag] = [:]
        for tag in tags {
            let normalizedName = Self.normalizedTag(tag.name)
            guard !normalizedName.isEmpty else { continue }
            let key = normalizedName.lowercased()
            if savedByKey[key] == nil {
                savedByKey[key] = SavedTag(name: normalizedName, color: tag.color)
            }
        }
        return savedByKey.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func normalizedListIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard !id.isEmpty, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    static func normalizedTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = name.components(separatedBy: invalid)
        let cleaned = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attachment" : cleaned
    }
}

private extension Array where Element == TaskAttachment {
    var cloudReferences: [CloudAttachmentReference] {
        compactMap { attachment in
            guard attachment.kind != .url, let localPath = attachment.localPath else { return nil }
            return CloudAttachmentReference(
                id: attachment.id,
                localPath: localPath,
                updatedAt: attachment.createdAt
            )
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Keep milliseconds: sync compares per-field revision times that iCloud stores with millisecond precision.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}
