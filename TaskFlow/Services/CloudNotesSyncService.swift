import CloudKit
import CryptoKit
import Foundation

/// Release configuration, never a token or setting the user needs to enter.
enum TaskFlowWebNotesConfiguration {
    static var cloudKitEnvironment: String {
        #if DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }
    static var isEnabled: Bool {
        #if DEBUG
        // Development builds exercise the private CloudKit bridge before release validation.
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "TaskFlowWebNotesEnabled") as? Bool == true
        #endif
    }
    static var websiteURL: URL? {
        guard isEnabled, let raw = Bundle.main.object(forInfoDictionaryKey: "TaskFlowWebNotesURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Browser records carry note content and attachment references, never embedded drawings or history.
/// Those remain in native storage and are retained when browser edits are applied.
struct CloudWebNote: Codable, Equatable {
    static let recordType = "TaskFlowWebNote"
    var id: UUID
    var payload: String
    var isDeleted: Bool
    var hasDrawing: Bool

    init(note: QuickNote, isDeleted: Bool = false) throws {
        var projection = note
        projection.drawingData = nil
        projection.versions = []
        projection.updatedAt = nil // Revision checking uses recordChangeTag, not device clocks.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(projection)
        guard data.count <= 600_000, let payload = String(data: data, encoding: .utf8) else { throw NSError(domain: "TaskFlow.WebNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "This note is too large for browser sync."]) }
        self.id = note.id; self.payload = payload; self.isDeleted = isDeleted; self.hasDrawing = note.drawingData != nil
    }
    func note() throws -> QuickNote {
        let decoder = JSONDecoder()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter.date(from: text) { return date }
            guard let date = formatter.date(from: text) else { throw CocoaError(.coderReadCorrupt) }
            return date
        }
        let note = try decoder.decode(QuickNote.self, from: Data(payload.utf8))
        guard note.id == id else { throw CocoaError(.coderReadCorrupt) }
        return note
    }
    var recordName: String { "TaskFlowWebNote-" + id.uuidString.uppercased() }
    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType,
              let raw = record["noteID"] as? String, let id = UUID(uuidString: raw),
              record.recordID.recordName == "TaskFlowWebNote-" + id.uuidString.uppercased(),
              let payload = record["payload"] as? String, payload.utf8.count <= 600_000,
              let deleted = record["isDeleted"] as? NSNumber, [0, 1].contains(deleted.intValue),
              (record["schemaVersion"] as? NSNumber)?.intValue == 1 else { throw CocoaError(.coderReadCorrupt) }
        self.id = id; self.payload = payload; self.isDeleted = deleted.boolValue; self.hasDrawing = false
        self = try CloudWebNote(note: note(), isDeleted: isDeleted)
        self.hasDrawing = (record["hasDrawing"] as? NSNumber)?.boolValue == true
    }
    func writing(to existing: CKRecord? = nil) -> CKRecord {
        let record = existing ?? CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName))
        record["noteID"] = id.uuidString.uppercased() as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["hasDrawing"] = NSNumber(value: hasDrawing)
        record["isDeleted"] = NSNumber(value: isDeleted)
        record["schemaVersion"] = NSNumber(value: 1)
        return record
    }

    struct Resolution {
        let primary: CloudWebNote
        let recovered: QuickNote?
    }
    /// Three-way comparison preserves concurrent edits, including edit-vs-delete.
    static func resolve(local: CloudWebNote?, remote: CloudWebNote?, base: CloudWebNote?) throws -> Resolution? {
        if local == remote { return local.map { Resolution(primary: $0, recovered: nil) } }
        if remote == nil { return local.map { Resolution(primary: $0, recovered: nil) } }
        if local == base { return remote.map { Resolution(primary: $0, recovered: nil) } }
        if remote == base { return local.map { Resolution(primary: $0, recovered: nil) } }
        guard let local else { return remote.map { Resolution(primary: $0, recovered: nil) } }
        guard let remote else { return Resolution(primary: local, recovered: nil) }
        // Never silently erase edited content. Keep the remote state and recover the local edit.
        let edit = local.isDeleted ? remote : local
        if edit.isDeleted { return Resolution(primary: remote, recovered: nil) }
        var recovered = try edit.note()
        let digest = SHA256.hash(data: Data((local.id.uuidString + local.payload + remote.payload + String(local.isDeleted) + String(remote.isDeleted)).utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let id = UUID(uuidString: uuid) else { throw CocoaError(.coderReadCorrupt) }
        recovered.id = id
        recovered.title = (recovered.title.isEmpty ? "Untitled Note" : recovered.title) + " (Recovered Edit)"
        recovered.folder = "Recovered Notes"
        return Resolution(primary: remote, recovered: recovered)
    }
}

/// Opt-in bridge. Legacy metadata sync remains intact until web configuration is validated.
actor CloudNotesSyncService {
    private var container: CKContainer { CKContainer(identifier: "iCloud.com.surratt.TaskFlow") }
    private var pendingCheckpoint: (URL, [String: CloudWebNote])?
    private var database: CKDatabase { container.privateCloudDatabase }

    func synchronize(_ snapshot: MetadataSnapshot) async throws -> MetadataSnapshot {
        pendingCheckpoint = nil
        let account = try await container.userRecordID()
        let hash = SHA256.hash(data: Data(account.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebNoteSync", isDirectory: true)
            .appendingPathComponent(TaskFlowWebNotesConfiguration.cloudKitEnvironment, isDirectory: true)
        let checkpoint = directory.appendingPathComponent(hash + ".json")
        var baselines: [String: CloudWebNote] = [:]
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            // A corrupt checkpoint must not be treated as a clean first migration.
            baselines = try JSONDecoder().decode([String: CloudWebNote].self, from: Data(contentsOf: checkpoint))
        }
        var records: [UUID: CKRecord] = [:]
        var remoteNotes: [UUID: CloudWebNote] = [:]
        let query = CKQuery(recordType: CloudWebNote.recordType, predicate: NSPredicate(value: true))
        var page = try await database.records(matching: query, resultsLimit: 200)
        while true {
            for (_, result) in page.matchResults {
                let record = try result.get()
                let value = try CloudWebNote(record: record)
                records[value.id] = record
                remoteNotes[value.id] = value
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 200)
        }
        var result = snapshot
        var next: [String: CloudWebNote] = [:]
        let localNotes = Dictionary(snapshot.quickNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(localNotes.keys).union(records.keys).union(baselines.keys.compactMap(UUID.init(uuidString:)))
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            let key = id.uuidString.uppercased()
            let revisionKey = "quickNotes/" + key
            let base = baselines[key]
            let remote = remoteNotes[id]
            var local = try localNotes[id].map { try CloudWebNote(note: $0) }
            if local == nil, snapshot.fieldUpdatedAt[revisionKey] != nil, let retained = base ?? remote {
                local = retained; local?.isDeleted = true
            }
            guard let resolved = try CloudWebNote.resolve(local: local, remote: remote, base: base) else { continue }
            if resolved.primary != remote {
                // CKDatabase.save uses the fetched record's change tag; a race aborts, never overwrites.
                _ = try await database.save(resolved.primary.writing(to: records[id]))
            }
            // The local projection is already available; unchanged notes need no array scan or decode.
            if resolved.primary != local || resolved.primary.isDeleted {
                Self.apply(resolved.primary, to: &result)
            }
            next[key] = resolved.primary
            if var recovered = resolved.recovered {
                if local?.isDeleted == false, let original = localNotes[id] {
                    recovered.drawingData = original.drawingData
                    recovered.versions = original.versions
                }
                let projection = try CloudWebNote(note: recovered)
                if let existing = records[recovered.id] {
                    guard try CloudWebNote(record: existing) == projection else { throw CocoaError(.validationMultipleErrors) }
                } else {
                    _ = try await database.save(projection.writing())
                }
                Self.apply(projection, to: &result, preserving: recovered)
                next[recovered.id.uuidString.uppercased()] = projection
            }
        }
        pendingCheckpoint = (checkpoint, next)
        return result
    }

    static func apply(_ value: CloudWebNote, to snapshot: inout MetadataSnapshot, preserving source: QuickNote? = nil) {
        let existing = snapshot.quickNotes.first { $0.id == value.id }
        let old = existing ?? source
        if value.isDeleted, old == nil, snapshot.fieldUpdatedAt["quickNotes/" + value.id.uuidString.uppercased()] != nil { return }
        let oldProjection = try? existing.map { try CloudWebNote(note: $0) }
        guard oldProjection != value else { return }
        snapshot.quickNotes.removeAll { $0.id == value.id }
        if !value.isDeleted, var note = try? value.note() {
            if let old {
                note.createdAt = old.createdAt
                note.attachments = note.attachments.map { incoming in
                    guard let existing = old.attachments.first(where: { $0.id == incoming.id }),
                          existing.kind == incoming.kind, existing.title == incoming.title,
                          existing.urlString == incoming.urlString, existing.localPath == incoming.localPath else { return incoming }
                    return existing
                }
                note.drawingData = old.drawingData
                note.versions = old.versions
                note = note.versioned(replacing: old, forceCheckpoint: true)
            }
            snapshot.quickNotes.append(note)
        }
        let key = "quickNotes/" + value.id.uuidString.uppercased()
        let stamp = max(Date(), (snapshot.fieldUpdatedAt[key] ?? .distantPast).addingTimeInterval(0.001))
        snapshot.fieldUpdatedAt[key] = stamp
        snapshot.cloudUpdatedAt = max(snapshot.cloudUpdatedAt, stamp)
    }

    /// Commit only after the native merged snapshot was durably persisted.
    func confirmSaved() async throws {
        guard let (url, state) = pendingCheckpoint else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        let recordID = CKRecord.ID(recordName: "TaskFlowWebNotesReady")
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "TaskFlowWebNotesState", recordID: recordID) }
        if let version = record["schemaVersion"] as? NSNumber, version.intValue != 1 { throw CocoaError(.coderReadCorrupt) }
        if (record["schemaVersion"] as? NSNumber)?.intValue != 1 {
            record["schemaVersion"] = NSNumber(value: 1)
            _ = try await database.save(record)
        }
        pendingCheckpoint = nil
    }
}
