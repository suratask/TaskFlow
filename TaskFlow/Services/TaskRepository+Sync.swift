import Foundation
import UserNotifications
import CloudKit
import EventKit
import Observation
import SwiftUI
import WidgetKit
import LinkPresentation
import UIKit

extension TaskRepository {
    static func equivalentSyncedSettings(_ lhs: [String: Data], _ rhs: [String: Data]) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { key, data in
            guard let other = rhs[key] else { return false }
            if data == other { return true }
            guard let left = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSObject,
                  let right = try? PropertyListSerialization.propertyList(from: other, options: [], format: nil) as? NSObject else { return false }
            return left == right
        }
    }
    func captureCloudSettings() {
        var values: [String: Data] = [:]
        let previous = metadataStore.currentSnapshot().syncedSettings
        for key in Self.syncedPreferenceKeys {
            if let value = preferences.object(forKey: key),
               let data = try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0) {
                if let oldData = previous[key],
                   let old = try? PropertyListSerialization.propertyList(from: oldData, options: [], format: nil) as? [String: Any],
                   (old["value"] as? NSObject) == (value as? NSObject) {
                    values[key] = oldData
                } else { values[key] = data }
            }
        }
        metadataStore.setSyncedSettings(values)
    }
    func synchronizeCloud() async {
        guard !isCloudSyncRunning else { scheduleCloudSync(); return }
        isCloudSyncRunning = true
        defer {
            isCloudSyncRunning = false
            if hasPendingCloudSync { hasPendingCloudSync = false; scheduleCloudSync() }
        }
        isApplyingCloudSnapshot = true
        captureCloudSettings()
        isApplyingCloudSnapshot = false
        let listIdentities = reminderService.cloudListIdentities()
        let localIDs = Dictionary(listIdentities.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let calendarIdentities = reminderService.cloudEventCalendarIdentities()
        let localCalendarIDs = Dictionary(calendarIdentities.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let sent = metadataStore.currentSnapshot().remappingListIDs(listIdentities).remappingCalendarIDs(calendarIdentities)
        cloudSyncStatus = "Syncing…"
        do {
            let received = try await cloudSync.synchronize(local: sent).remappingListIDs(localIDs).remappingCalendarIDs(localCalendarIDs)
            // Never overwrite edits made while the network request was in flight.
            let merged = try metadataStore.currentSnapshot().merging(received)
            let metadataChanged = merged != metadataStore.currentSnapshot()
            let settingsChanged = !Self.equivalentSyncedSettings(merged.syncedSettings, metadataStore.currentSnapshot().syncedSettings)
            isApplyingCloudSnapshot = true
            if metadataChanged { metadataStore.replace(with: merged) }
            guard metadataStore.persistenceError == nil else { throw CocoaError(.fileWriteUnknown) }
            if settingsChanged {
            for key in Self.syncedPreferenceKeys where merged.syncedSettings[key] == nil && merged.fieldUpdatedAt["syncedSettings/" + key] != nil {
                preferences.removeObject(forKey: key)
            }
            for (key, data) in merged.syncedSettings where Self.syncedPreferenceKeys.contains(key) {
                if let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    preferences.set(values["value"], forKey: key)
                }
            }
            appearanceMode = AppearanceMode(rawValue: preferences.string(forKey: "TaskFlow.appearanceMode") ?? "") ?? .system
            appTheme = (AppTheme(rawValue: preferences.string(forKey: "TaskFlow.appTheme") ?? "") ?? .system).canonical
            taskDensity = TaskDensity(rawValue: preferences.string(forKey: "TaskFlow.taskDensity") ?? "") ?? .comfortable
            taskViewMode = (TaskViewMode(rawValue: preferences.string(forKey: "TaskFlow.taskViewMode") ?? "") ?? .list).normalized
            taskGroupOption = TaskGroupOption(rawValue: preferences.string(forKey: "TaskFlow.taskGroupOption") ?? "") ?? .none
            taskSortOption = TaskSortOption(rawValue: preferences.string(forKey: "TaskFlow.taskSortOption") ?? "") ?? .dueDate
            taskSortDirection = TaskSortDirection(rawValue: preferences.string(forKey: "TaskFlow.taskSortDirection") ?? "") ?? .ascending
            listIcons = preferences.dictionary(forKey: "TaskFlow.listIcons") as? [String: String] ?? [:]
            lists = Self.orderedLists(lists, order: preferences.stringArray(forKey: "TaskFlow.listOrder") ?? [])
            todaySectionRevision &+= 1
            excludedAvailabilityCalendarIDs = Set(preferences.stringArray(forKey: "TaskFlow.excludedAvailabilityCalendarIDs") ?? [])
            includeCompletedTasks = preferences.bool(forKey: "TaskFlow.includeCompletedTasks")
            dueFilter = DueFilter(rawValue: preferences.string(forKey: "TaskFlow.dueFilter") ?? "") ?? .any
            quickDueFilter = DueFilter(rawValue: preferences.string(forKey: "TaskFlow.quickDueFilter") ?? "") ?? .any
            quickStatusFilter = TaskStatus(rawValue: preferences.string(forKey: "TaskFlow.quickStatusFilter") ?? "")
            quickPriorityFilter = TaskPriority(rawValue: preferences.string(forKey: "TaskFlow.quickPriorityFilter") ?? "")
            selectedTagFilter = preferences.data(forKey: "TaskFlow.selectedTagFilter").flatMap { try? JSONDecoder().decode(TagFilter.self, from: $0) }
            quickTagFilter = preferences.data(forKey: "TaskFlow.quickTagFilter").flatMap { try? JSONDecoder().decode(TagFilter.self, from: $0) }
            foldLegacyFilters()
            // Remembered shopping prices sync too, so every device estimates the same way.
            if let data = preferences.data(forKey: "TaskFlow.shoppingPriceHistory"),
               let synced = try? JSONDecoder().decode([String: Double].self, from: data), synced != shoppingPriceHistory {
                shoppingPriceHistory = synced
            }
            }
            isApplyingCloudSnapshot = false
            try await cloudSync.confirmWebNotesSaved()
            // Publish synced links/text before binary downloads; an unavailable
            // photo or document must not hide an already-merged note.
            if metadataChanged { await loadAllData() }
            try await cloudSync.uploadAttachments(metadataStore.localAttachmentUploads())
            let downloaded = try await cloudSync.downloadAttachments(metadataStore.missingCloudAttachmentDownloads())
            if downloaded > 0 {
                attachmentContentRevision &+= 1
                await loadAllData()
            }
            cloudSyncStatus = "Synced"
            if merged != received { scheduleCloudSync() }
        } catch {
            isApplyingCloudSnapshot = false
            cloudSyncStatus = FriendlyError.message(for: error)
        }
    }
    func syncDueTodayActivity() async {
        let day = Calendar.current.startOfDay(for: Date())
        let enabled = showsDueTodayLiveActivity && accessState == .granted
        guard lastActivityTasks != tasks || lastActivityLists != lists || lastActivityDay != day || lastActivityEnabled != enabled else { return }
        lastActivityTasks = tasks; lastActivityLists = lists; lastActivityDay = day; lastActivityEnabled = enabled
        if showsDueTodayLiveActivity && accessState == .granted {
            await dueTodayActivity.sync(tasks: tasks, lists: lists)
        } else {
            await dueTodayActivity.endCurrentActivity()
        }
    }
    /// Scroll anchors and comment drafts write preferences continuously; coalesce
    /// them so scrolling and typing do not re-encode every synced setting.
    func preferencesDidChange() {
        cloudPreferencesCapture?.cancel()
        cloudPreferencesCapture = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, !self.isApplyingCloudSnapshot else { return }
            // Ignore unrelated device-only preferences and unchanged synced values.
            let before = self.metadataStore.currentSnapshot().syncedSettings
            self.isApplyingCloudSnapshot = true
            self.captureCloudSettings()
            self.isApplyingCloudSnapshot = false
            if before != self.metadataStore.currentSnapshot().syncedSettings { self.scheduleCloudSync() }
        }
    }
    func saveNoteDraftAsync(_ draft: NoteEditorRecovery) async -> Bool {
        if let existing = noteDrafts.first(where: { $0.id == draft.id }),
           existing.note == draft.note && existing.originalNoteID == draft.originalNoteID && existing.pendingURL == draft.pendingURL { return true }
        draftWriteGeneration &+= 1
        let generation = draftWriteGeneration
        var drafts = noteDrafts.filter { $0.id != draft.id }
        drafts.insert(draft, at: 0)
        // Publish desired drafts so a simultaneous save of another draft includes
        // the pending one. Discard increments the generation and cannot be undone
        // by a late completion from this write.
        let previousDrafts = noteDrafts
        noteDrafts = drafts
        do {
            try await metadataStore.writeNoteDraftsAsync(drafts)
            return true
        } catch {
            if generation == draftWriteGeneration {
                noteDrafts = previousDrafts
                errorMessage = "Could not recoverably save this draft: " + FriendlyError.message(for: error)
            }
            return false
        }
    }
    func importFileAttachmentAsync(from url: URL) async throws -> TaskAttachment {
        try await metadataStore.saveFileAttachmentAsync(sourceURL: url, suggestedName: url.lastPathComponent, kind: .file)
    }
    func importPhotoAttachmentAsync(data: Data, suggestedName: String) async throws -> TaskAttachment {
        try await metadataStore.saveFileAttachmentAsync(data: data, suggestedName: suggestedName, kind: .photo)
    }
}
