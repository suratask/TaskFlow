import CloudKit
import Foundation

actor CloudMetadataSyncService {
    private var database: CKDatabase { CKContainer(identifier: "iCloud.com.surratt.TaskFlow").privateCloudDatabase }
    private let recordID = CKRecord.ID(recordName: "TaskFlowMetadataSnapshot")
    private let recordType = "TaskFlowMetadata"
    private let attachmentRecordType = "TaskFlowAttachment"
    private static let payloadKey = "payload"
    private static let updatedAtKey = "updatedAt"
    private static let attachmentAssetKey = "file"
    private static let attachmentLocalPathKey = "localPath"

    func synchronize(local snapshot: MetadataSnapshot) async throws -> MetadataSnapshot {
        do {
            let record = try await database.record(for: recordID)
            guard let remoteSnapshot = Self.snapshot(from: record) else {
                throw CocoaError(.coderReadCorrupt)
            }

            let merged = try snapshot.merging(remoteSnapshot)
            if merged != remoteSnapshot { return try await save(merged, replacing: record) }
            return merged
        } catch let error as CKError where error.code == .unknownItem {
            return try await save(snapshot, replacing: nil)
        }
    }

    func upload(_ snapshot: MetadataSnapshot) async throws {
        do {
            let record = try await database.record(for: recordID)
            guard let remote = Self.snapshot(from: record) else { throw CocoaError(.coderReadCorrupt) }
            _ = try await save(try snapshot.merging(remote), replacing: record)
        } catch let error as CKError where error.code == .unknownItem {
            _ = try await save(snapshot, replacing: nil)
        }
    }

    func uploadAttachments(_ uploads: [CloudAttachmentUpload]) async throws {
        for upload in uploads {
            try await uploadAttachment(upload)
        }
    }

    /// Writes each available attachment straight to its destination and returns
    /// how many arrived. Files are copied, not loaded, so large photos and
    /// documents never accumulate in memory, and one attachment missing from
    /// iCloud does not block the others or fail the whole sync.
    func downloadAttachments(_ downloads: [CloudAttachmentDownload]) async throws -> Int {
        var count = 0
        for download in downloads {
            if try await downloadAttachment(download) { count += 1 }
        }
        return count
    }

    private func save(_ snapshot: MetadataSnapshot, replacing existingRecord: CKRecord?) async throws -> MetadataSnapshot {
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        let data = try JSONEncoder.cloud.encode(snapshot)
        record[Self.payloadKey] = data as CKRecordValue
        record[Self.updatedAtKey] = snapshot.cloudUpdatedAt as CKRecordValue
        do {
            _ = try await database.save(record)
            return snapshot
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.serverRecord, let remote = Self.snapshot(from: server) else { throw error }
            let merged = try snapshot.merging(remote)
            server[Self.payloadKey] = try JSONEncoder.cloud.encode(merged) as CKRecordValue
            server[Self.updatedAtKey] = merged.cloudUpdatedAt as CKRecordValue
            _ = try await database.save(server)
            return merged
        }
    }

    private func uploadAttachment(_ upload: CloudAttachmentUpload) async throws {
        let recordID = attachmentRecordID(for: upload.reference)
        do {
            let existingRecord: CKRecord?
            do { existingRecord = try await database.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem { existingRecord = nil }
            if let existingRecord,
               existingRecord[Self.attachmentLocalPathKey] as? String == upload.reference.localPath,
               existingRecord[Self.attachmentAssetKey] as? CKAsset != nil,
               (existingRecord[Self.updatedAtKey] as? Date ?? .distantPast) >= upload.reference.updatedAt {
                return
            }

            let record = existingRecord ?? CKRecord(recordType: attachmentRecordType, recordID: recordID)
            record[Self.attachmentLocalPathKey] = upload.reference.localPath as CKRecordValue
            record[Self.updatedAtKey] = upload.reference.updatedAt as CKRecordValue
            record[Self.attachmentAssetKey] = CKAsset(fileURL: upload.fileURL)
            _ = try await database.save(record)
        } catch {
            throw error
        }
    }

    private func downloadAttachment(_ download: CloudAttachmentDownload) async throws -> Bool {
        let record: CKRecord
        do { record = try await database.record(for: attachmentRecordID(for: download.reference)) }
        catch let error as CKError where error.code == .unknownItem { return false } // Not uploaded yet by its device.
        guard let asset = record[Self.attachmentAssetKey] as? CKAsset, let fileURL = asset.fileURL else { return false }
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("TaskFlowDownload-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: fileURL, to: staging)
        guard !manager.fileExists(atPath: download.destination.path) else { return false }
        try manager.moveItem(at: staging, to: download.destination)
        return true
    }

    private static func snapshot(from record: CKRecord) -> MetadataSnapshot? {
        guard let data = record[payloadKey] as? Data else { return nil }
        return try? JSONDecoder.cloud.decode(MetadataSnapshot.self, from: data)
    }

    private func attachmentRecordID(for reference: CloudAttachmentReference) -> CKRecord.ID {
        CKRecord.ID(recordName: "TaskFlowAttachment-\(reference.id.uuidString)")
    }
}

private extension JSONEncoder {
    static var cloud: JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

private extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = formatter.date(from: value) { return date }
            guard let date = legacyFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid sync date")
            }
            return date
        }
        return decoder
    }
}
