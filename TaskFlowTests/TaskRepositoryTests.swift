import XCTest
import CloudKit
import SwiftUI
import EventKit
import CoreLocation
import UserNotifications
import UIKit
@testable import TaskFlow

@MainActor
final class TaskRepositoryTests: XCTestCase {
    func testAsyncDraftSaveCannotResurrectDiscardedDraft() async {
        let (repository, store, _) = fixture()
        let draft = NoteEditorRecovery(id: UUID(), originalNoteID: nil, note: QuickNote(text: "Recover me"))
        let write = Task { await repository.saveNoteDraftAsync(draft) }
        while repository.noteDrafts.isEmpty { await Task.yield() }
        repository.discardNoteDraft(id: draft.id)
        _ = await write.value
        XCTAssertTrue(repository.noteDrafts.isEmpty)
        XCTAssertTrue(store.loadNoteDrafts().isEmpty)
    }

    func testAsyncMetadataWriteCannotOverwriteNewerExplicitSave() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataStore(directory: directory)
        let older = QuickNote(text: "Autosave")
        var latest = older
        latest.text = "Explicit save"
        let write = Task { await store.saveQuickNotesAsync([older]) }
        while store.quickNotes.isEmpty { await Task.yield() }
        store.quickNotes = [latest]
        _ = await write.value
        XCTAssertEqual(store.quickNotes.first?.text, "Explicit save")
        XCTAssertEqual(MetadataStore(directory: directory).quickNotes.first?.text, "Explicit save")
    }

    func testAsyncDraftFailureCanBeRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataStore(directory: directory)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let repository = TaskRepository(preferences: defaults, metadataStore: store)
        let target = directory.appendingPathComponent("NoteDrafts.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let draft = NoteEditorRecovery(id: UUID(), originalNoteID: nil, note: QuickNote(text: "Retry me"))
        let failed = await repository.saveNoteDraftAsync(draft)
        XCTAssertFalse(failed)
        XCTAssertTrue(repository.noteDrafts.isEmpty)
        try FileManager.default.removeItem(at: target)
        let retried = await repository.saveNoteDraftAsync(draft)
        XCTAssertTrue(retried)
        XCTAssertEqual(store.loadNoteDrafts().first?.note.text, "Retry me")
    }

    func testTaskFilterCacheInvalidatesForEditsAndFilterChanges() {
        let (repository, _, _) = fixture()
        repository.selectedScope = .all
        repository.tasks = [task("a"), task("b")]
        XCTAssertEqual(repository.filteredTasks.count, 2)
        XCTAssertEqual(repository.filteredTasks.count, 2)
        repository.searchQuery = "a"
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["a"])
        repository.tasks[0].title = "Changed"
        repository.searchQuery = "Changed"
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["a"])
        repository.tasks[0].isCompleted = true
        XCTAssertTrue(repository.filteredTasks.isEmpty)
        repository.includeCompletedTasks = true
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["a"])
        repository.searchQuery = ""
        repository.selectedScope = .inbox
        repository.defaultListID = "missing"
        XCTAssertTrue(repository.filteredTasks.isEmpty)
        repository.defaultListID = "list"
        XCTAssertEqual(repository.filteredTasks.count, 2)
    }

    func testNoteRenderingCacheInvalidatesForTextFormatAndQuery() {
        var note = QuickNote(title: "Heading", text: "Paragraph\n- [ ] Milk", format: .markdown)
        XCTAssertEqual(NoteDocument.lines(note.text, format: note.format).compactMap(\.checkbox).count, 1)
        XCTAssertEqual(NoteSearch.matches(note: note, query: "Milk").count, 1)
        note.text = "Paragraph\n- [x] Eggs"
        XCTAssertTrue(NoteDocument.lines(note.text, format: note.format)[1].checkbox!.isChecked)
        XCTAssertTrue(NoteSearch.matches(note: note, query: "Milk").isEmpty)
        XCTAssertEqual(NoteSearch.matches(note: note, query: "Eggs").count, 1)
        XCTAssertTrue(NoteDocument.lines(note.text, format: .plain).compactMap(\.checkbox).isEmpty)
        note.title = "Eggs"
        XCTAssertEqual(NoteSearch.matches(note: note, query: "Eggs").count, 2)
        XCTAssertTrue(NoteSearch.matches(note: note, query: "").isEmpty)
    }

    func testHistoryPayloadBudgetPreservesLatestCheckpoint() {
        var note = QuickNote(text: "First", drawingData: Data(repeating: 1, count: 3 * 1024 * 1024))
        for index in 0..<5 {
            var edited = note
            edited.text = "Version \(index)"
            note = edited.versioned(replacing: note, forceCheckpoint: true)
        }
        XCTAssertEqual(note.versions.count, 1)
        XCTAssertEqual(note.versions.last?.snapshot.text, "Version 3")
        XCTAssertTrue(note.versions.last!.snapshot.versions.isEmpty)
    }

    func testPerformanceColdLongNoteSearch() {
        let text = (0..<2000).map { "- [ ] Item \($0) with **details**" }.joined(separator: "\n")
        var note = QuickNote(text: text, format: .markdown)
        measure {
            for _ in 0..<20 {
                note.title = UUID().uuidString
                _ = NoteSearch.matches(note: note, query: "details")
            }
        }
    }

    func testNoteOnlySaveRecordsCloudEditsAndDeletionRevisions() async throws {
        let (_, store, _) = fixture()
        let first = QuickNote(text: "First")
        let second = QuickNote(text: "Second")
        store.quickNotes = [first, second]
        let before = store.currentSnapshot()
        try await Task.sleep(for: .milliseconds(3))
        var edited = first
        edited.text = "Changed"
        let saved = await store.saveQuickNotesAsync([edited])
        XCTAssertTrue(saved)
        let after = store.currentSnapshot()
        XCTAssertNotNil(after.fieldUpdatedAt["quickNotes/" + first.id.uuidString])
        XCTAssertNotNil(after.fieldUpdatedAt["quickNotes/" + second.id.uuidString])
        XCTAssertEqual(after.taskMetadata, before.taskMetadata)
        let merged = try after.merging(before)
        XCTAssertEqual(merged.quickNotes.map(\.text), ["Changed"])
    }

    func testPerformanceWarmLongNoteSearch() {
        let text = (0..<2000).map { "- [ ] Item \($0) with **details**" }.joined(separator: "\n")
        let note = QuickNote(text: text, format: .markdown)
        _ = NoteSearch.matches(note: note, query: "details")
        measure {
            for _ in 0..<20 { _ = NoteSearch.matches(note: note, query: "details") }
        }
    }

    func testPerformanceLargeTaskListFiltering() {
        let (repository, _, _) = fixture()
        repository.selectedScope = .all
        repository.tasks = (0..<10_000).map { task("Task \($0)") }
        _ = repository.filteredTasks
        measure {
            for _ in 0..<100 { _ = repository.filteredTasks }
        }
    }

    func testAsyncAttachmentImportPreservesFileAndPhotoBytes() async throws {
        let (repository, _, _) = fixture()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = Data("Attachment content".utf8)
        try bytes.write(to: source)
        let file = try await repository.importFileAttachmentAsync(from: source)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(for: file)!), bytes)
        let photo = try await repository.importPhotoAttachmentAsync(data: bytes, suggestedName: "photo.jpg")
        XCTAssertEqual(photo.kind, .photo)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(for: photo)!), bytes)
    }

    func testSubtaskIndexInvalidatesOnReparentAndDeletion() {
        let (repository, _, _) = fixture()
        let parent = task("parent")
        var child = task("child")
        child.parentID = parent.id
        repository.tasks = [parent, child]
        XCTAssertEqual(repository.subtasks(for: parent).map(\.id), ["child"])
        repository.tasks[1].parentID = nil
        XCTAssertTrue(repository.subtasks(for: parent).isEmpty)
        repository.tasks[1].parentID = parent.id
        repository.tasks.removeLast()
        XCTAssertTrue(repository.subtasks(for: parent).isEmpty)
    }

    func testNoteURLAttachmentsSaveResolveAndSurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataStore(directory: directory)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let repository = TaskRepository(preferences: defaults, metadataStore: store)
        let note = try XCTUnwrap(QuickNote(text: "").addingURLAttachment(" Example.com/article?q=notes#section "))
        XCTAssertTrue(repository.saveNoteSnapshot(note))
        let saved = try XCTUnwrap(MetadataStore(directory: directory).quickNotes.first)
        let attachment = try XCTUnwrap(saved.attachments.first)
        XCTAssertEqual(attachment.urlString, "https://example.com/article?q=notes#section")
        XCTAssertEqual(store.attachmentURL(for: attachment)?.absoluteString, attachment.urlString)
        XCTAssertTrue(store.currentSnapshot().cloudAttachmentReferences.isEmpty)
        XCTAssertEqual(saved.addingURLAttachment(attachment.urlString!)?.attachments.count, 1)
        XCTAssertEqual(saved.addingURLAttachment(attachment.urlString!)?.attachments.first?.id, attachment.id)
    }

    func testNoteURLAttachmentSurvivesCrossDeviceMetadataMerge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MetadataStore(directory: directory.appendingPathComponent("source"))
        let target = MetadataStore(directory: directory.appendingPathComponent("target"))
        let note = try XCTUnwrap(QuickNote(text: "Reference").addingURLAttachment("https://example.com/source?x=1&y=2"))
        source.quickNotes = [note]
        target.replace(with: try target.currentSnapshot().merging(source.currentSnapshot()))
        let synced = try XCTUnwrap(target.quickNotes.first?.attachments.first)
        XCTAssertEqual(synced.id, note.attachments[0].id)
        XCTAssertEqual(target.attachmentURL(for: synced)?.absoluteString, "https://example.com/source?x=1&y=2")
    }

    func testPendingNoteURLDraftRecoveryAndLegacyDecoding() throws {
        let (_, store, _) = fixture()
        let draft = NoteEditorRecovery(id: UUID(), originalNoteID: nil, note: QuickNote(text: ""), pendingURL: "https://example.com/unfinished")
        try store.writeNoteDrafts([draft])
        XCTAssertEqual(store.loadNoteDrafts().first?.pendingURL, draft.pendingURL)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        legacy.removeValue(forKey: "pendingURL")
        let decoded = try JSONDecoder().decode(NoteEditorRecovery.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.pendingURL)
    }

    func testURLValidationRejectsInvalidAndUnsafeSchemes() {
        for invalid in ["", "https://", "https://exa mple.com", "file:///etc/passwd", "javascript://alert", "https://user:password@example.com"] {
            XCTAssertNil(TaskAttachment.webURL(from: invalid), invalid)
        }
        XCTAssertEqual(TaskAttachment.webURL(from: "//example.com/path")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(TaskAttachment.webURL(from: "HTTPS://Example.COM/path")?.host, "example.com")
    }

    func testBareNoteURLsAndMarkdownLinksAreTappable() {
        let rendered = NoteTextFormatting.inline("Read **this**: https://example.com/path and [guide](https://example.org/docs)")
        let links = rendered.runs.compactMap { $0.link?.absoluteString }
        XCTAssertTrue(links.contains("https://example.com/path"))
        XCTAssertTrue(links.contains("https://example.org/docs"))
        XCTAssertEqual(String(rendered.characters), "Read this: https://example.com/path and guide")
    }

    func testUpdatingPendingURLDoesNotSkipDraftPersistence() async {
        let (repository, store, _) = fixture()
        var draft = NoteEditorRecovery(id: UUID(), originalNoteID: nil, note: QuickNote(text: ""), pendingURL: "example.com/first")
        _ = await repository.saveNoteDraftAsync(draft)
        draft.pendingURL = "example.com/second"
        _ = await repository.saveNoteDraftAsync(draft)
        XCTAssertEqual(store.loadNoteDrafts().first?.pendingURL, "example.com/second")
    }

    func testMovingNotePreservesLatestContentAndPersistsFolder() {
        let (repository, store, _) = fixture()
        var note = QuickNote(title: "Reference", text: "Original")
        note.folder = "Work"
        XCTAssertTrue(repository.saveNoteSnapshot(note))
        note.text = "Latest content"
        note.attachments = [TaskAttachment(kind: .url, title: "Example", urlString: "https://example.com")]
        XCTAssertTrue(repository.saveNoteSnapshot(note))
        XCTAssertTrue(repository.moveNote(id: note.id, toFolder: "  Research  "))
        XCTAssertEqual(repository.quickNotes[0].folder, "Research")
        XCTAssertEqual(store.quickNotes[0].text, "Latest content")
        XCTAssertEqual(store.quickNotes[0].attachments, note.attachments)
        XCTAssertEqual(repository.noteFolders, ["Research"])
        XCTAssertTrue(repository.moveNote(id: note.id, toFolder: ""))
        XCTAssertTrue(store.quickNotes[0].folder.isEmpty)
        XCTAssertFalse(repository.moveNote(id: UUID(), toFolder: "Missing"))
    }

    func testFolderMoveReusesExistingNameAndUndoRestoresFolder() {
        let (repository, store, _) = fixture()
        var first = QuickNote(text: "First")
        first.folder = "Work"
        let second = QuickNote(text: "Second")
        _ = repository.saveNoteSnapshot(first)
        _ = repository.saveNoteSnapshot(second)
        XCTAssertTrue(repository.moveNote(id: second.id, toFolder: " work "))
        XCTAssertEqual(store.quickNotes.first { $0.id == second.id }?.folder, "Work")
        repository.restoreNote(repository.noteUndo!)
        XCTAssertEqual(store.quickNotes.first { $0.id == second.id }?.folder, "")
    }

    func testEventDeletionScopePreservesPastAndUnrelatedOccurrences() {
        let date = Date(timeIntervalSince1970: 10_000)
        let selected = CalendarEvent(id: "series", calendarID: "calendar", title: "Weekly", startDate: date, endDate: date.addingTimeInterval(60), isAllDay: false)
        var earlier = selected; earlier.startDate = date.addingTimeInterval(-3600)
        var later = selected; later.startDate = date.addingTimeInterval(3600)
        let unrelated = CalendarEvent(id: "other", calendarID: "calendar", title: "Other", startDate: date, endDate: date.addingTimeInterval(60), isAllDay: false)
        let single = EventDeletion(eventID: selected.id, startDate: date, scope: .thisEvent)
        XCTAssertEqual([earlier, selected, later, unrelated].filter { single.includes($0) }.map(\.occurrenceKey), [selected.occurrenceKey])
        let future = EventDeletion(eventID: selected.id, startDate: date, scope: .thisAndFuture)
        XCTAssertEqual([earlier, selected, later, unrelated].filter { future.includes($0) }.map(\.occurrenceKey), [selected.occurrenceKey, later.occurrenceKey])
    }

    func testConfirmedNativeEventDeletionPublishesSelectionCleanupAndClearsStaleUndo() async {
        let (repository, _, _) = fixture()
        let date = Date(timeIntervalSince1970: 10_000)
        let event = CalendarEvent(id: "deleted", calendarID: "calendar", title: "Deleted", startDate: date, endDate: date.addingTimeInterval(60), isAllDay: false)
        repository.calendarEvents = [event]
        repository.previousEventEdit = EventDraft(event: event)
        repository.previousEventBatchIDs = [event.id]
        let deletion = EventDeletion(eventID: event.id, startDate: date, scope: .thisEvent)
        await repository.eventDeletionDidComplete(deletion)
        XCTAssertEqual(repository.lastEventDeletion, deletion)
        XCTAssertFalse(repository.calendarEvents.contains { deletion.includes($0) })
        XCTAssertNil(repository.previousEventEdit)
        XCTAssertTrue(repository.previousEventBatchIDs.isEmpty)
        XCTAssertEqual(repository.eventSaveStatus, "Event deleted")
    }

    func testDeletingEventDoesNotDiscardUnrelatedEventUndo() async {
        let (repository, _, _) = fixture()
        let date = Date()
        let other = CalendarEvent(id: "other", calendarID: "calendar", title: "Other", startDate: date, endDate: date.addingTimeInterval(60), isAllDay: false)
        repository.previousEventEdit = EventDraft(event: other)
        repository.previousEventBatchIDs = ["other"]
        await repository.eventDeletionDidComplete(EventDeletion(eventID: "deleted", startDate: date, scope: .thisEvent))
        XCTAssertEqual(repository.previousEventEdit?.eventID, "other")
        XCTAssertEqual(repository.previousEventBatchIDs, ["other"])
    }

    func testEventDeletionWithoutCalendarPermissionKeepsSelectionAndAllowsRetry() async throws {
        guard EKEventStore.authorizationStatus(for: .event) != .fullAccess else {
            throw XCTSkip("This failure-path test requires calendar permission to be unavailable.")
        }
        let (repository, _, _) = fixture()
        let date = Date()
        let event = CalendarEvent(id: "not-deleted", calendarID: "calendar", title: "Keep", startDate: date, endDate: date.addingTimeInterval(60), isAllDay: false)
        repository.calendarEvents = [event]
        let first = await repository.deleteCalendarEvent(event, scope: .thisEvent)
        XCTAssertFalse(first)
        XCTAssertNil(repository.lastEventDeletion)
        XCTAssertEqual(repository.calendarEvents, [event])
        let retry = await repository.deleteCalendarEvent(event, scope: .thisEvent)
        XCTAssertFalse(retry)
        XCTAssertTrue(repository.eventSaveStatus.contains("Could not delete"))
    }

    func testNoteShortcutsCreateAppendAndRejectStaleWidgetActions() throws {
        let (repository, _, _) = fixture()
        let handler = RepositoryNoteIntentHandler(repository: repository)
        let created = try handler.create(title: "Trip", text: "- [ ] Pack", folder: "Travel", format: "checklist", pinned: true)
        XCTAssertEqual(created.folder, "Travel")
        XCTAssertTrue(created.isPinned)
        let appended = try handler.append(noteID: created.id, text: "- [ ] Tickets")
        XCTAssertTrue(appended.text.contains("Tickets"))
        try handler.setChecked(noteID: created.id, itemID: 0, expectedSource: "- [ ] Pack", checked: true)
        XCTAssertTrue(repository.quickNotes[0].text.hasPrefix("- [x] Pack"))
        XCTAssertThrowsError(try handler.setChecked(noteID: created.id, itemID: 0, expectedSource: "- [ ] Pack", checked: false))
        XCTAssertTrue(repository.quickNotes[0].text.hasPrefix("- [x] Pack"))
        XCTAssertThrowsError(try handler.append(noteID: UUID(), text: "Missing"))
        XCTAssertThrowsError(try handler.create(title: "", text: " ", folder: "", format: "plain", pinned: false))
    }

    func testWidgetSnapshotKeepsOnlyExplicitRichTextChecklistItems() {
        let note = QuickNote(text: "Paragraph\n# Section\n- [ ] First\n  - [X] Nested", format: .markdown)
        let snapshot = TaskFlowSharedNote(note: note)
        XCTAssertEqual(snapshot.checklistItems.map(\.id), [2, 3])
        XCTAssertEqual(snapshot.checklistItems.map(\.isChecked), [false, true])
    }

    func testRichNotesKeepParagraphsAndNestedCheckboxesDistinct() {
        let text = "# Meeting\nDiscuss **budget**\n- [ ] Follow up\n  - [x] Email [team](https://example.com)"
        let lines = NoteDocument.lines(text, format: .markdown)
        XCTAssertEqual(lines[0].headingLevel, 1)
        XCTAssertNil(lines[1].checkbox)
        XCTAssertEqual(lines[1].displayText, "Discuss budget")
        XCTAssertEqual(lines[3].checkbox?.depth, 1)
        XCTAssertEqual(lines[3].displayText, "Email team")
        var note = QuickNote(text: text, format: .markdown)
        XCTAssertTrue(note.hasUnfinishedChecklist)
        note.text = text.replacingOccurrences(of: "- [ ]", with: "- [x]")
        XCTAssertFalse(note.hasUnfinishedChecklist)
    }

    func testNoteSearchIncludesEveryOccurrenceAndSupportsAccents() {
        let note = QuickNote(title: "Café", text: "Cafe cafe\n# Café\n- [ ] cafe", format: .markdown)
        let matches = NoteSearch.matches(note: note, query: "cafe")
        XCTAssertEqual(matches.map(\.lineID), [-1, 0, 0, 1, 2])
        XCTAssertEqual(matches.map(\.ordinalWithinLine), [0, 0, 1, 0, 0])
        XCTAssertTrue(NoteSearch.matches(note: note, query: "").isEmpty)
    }

    func testNoteDisplayFiltersAndCollapseDoNotAlterText() {
        let text = "# Home\n- [x] Done\n- [ ] Next\n# Work\nParagraph"
        let shown = NoteDocument.presentedLines(text, format: .markdown, hideCompleted: true, completedLast: false, collapsed: [3])
        XCTAssertEqual(shown.map(\.id), [0, 2, 3])
        let sorted = NoteDocument.presentedLines(text, format: .markdown, hideCompleted: false, completedLast: true, collapsed: [])
        XCTAssertEqual(sorted.map(\.id), [0, 2, 1, 3, 4])
    }

    func testChecklistDragMovesNestedChildrenWithTheirParent() {
        let text = "- [ ] Parent\n  - [x] Child\n- [ ] Second\n- [ ] Third"
        XCTAssertEqual(NoteChecklist.moving(text, itemID: 0, before: 3), "- [ ] Second\n- [ ] Parent\n  - [x] Child\n- [ ] Third")
        XCTAssertEqual(NoteChecklist.moving(text, itemID: 0, before: 1), text)
        XCTAssertEqual(NoteChecklist.items(in: text)[1].depth, 1)
    }

    func testChecklistSectionsDoNotBecomeItemsAndKeepSourceIndices() {
        let text = "# Kitchen\n- [ ] Milk\n# Office\n- [x] Paper"
        let items = NoteChecklist.items(in: text)
        XCTAssertEqual(items.map(\.section), ["Kitchen", "Office"])
        XCTAssertEqual(items.map(\.id), [1, 3])
        XCTAssertEqual(NoteChecklist.setAll(text, checked: false), "# Kitchen\n- [ ] Milk\n# Office\n- [ ] Paper")
    }

    func testNotesDecodeBeforeFoldersAndHistoryWereAdded() throws {
        let note = try JSONDecoder().decode(QuickNote.self, from: Data("{\"text\":\"Existing note\"}".utf8))
        XCTAssertEqual(note.folder, "")
        XCTAssertTrue(note.versions.isEmpty)
        XCTAssertEqual(note.format, .plain)
    }

    func testNoteHistoryIsBoundedAndHasNoRecursiveSnapshots() {
        var note = QuickNote(text: "Original")
        let start = Date(timeIntervalSince1970: 1000)
        for index in 0..<60 {
            var next = note
            next.text = "Revision \(index)"
            note = next.versioned(replacing: note, now: start.addingTimeInterval(Double(index * 61)))
        }
        XCTAssertEqual(note.versions.count, 50)
        XCTAssertTrue(note.versions.allSatisfy { $0.snapshot.versions.isEmpty })
    }

    func testNoteDraftsRecoverAfterStoreReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataStore(directory: directory)
        var note = QuickNote(text: "Unfinished dictated text", format: .checklist)
        note.folder = "Work"
        let recovery = NoteEditorRecovery(id: UUID(), originalNoteID: nil, note: note)
        try store.writeNoteDrafts([recovery])
        XCTAssertEqual(MetadataStore(directory: directory).loadNoteDrafts(), [recovery])
        XCTAssertTrue(store.quickNotes.isEmpty)
    }

    func testRestoringNoteHistoryKeepsCurrentContentRecoverable() {
        let (repository, _, _) = fixture()
        var note = QuickNote(text: "Original")
        XCTAssertTrue(repository.saveNoteSnapshot(note))
        note.text = "Updated"
        XCTAssertTrue(repository.saveNoteSnapshot(note))
        let version = repository.quickNotes[0].versions[0]
        repository.restoreNoteVersion(noteID: note.id, revision: version)
        XCTAssertEqual(repository.quickNotes[0].text, "Original")
        XCTAssertEqual(repository.quickNotes[0].versions.last?.snapshot.text, "Updated")
    }

    func testNoteChecklistDuplicateTitlesBlankLinesAndCheckedMarkers() {
        let text = "- [ ] Milk\n\n- [X] Milk\n- [x] Keep - hyphen\n- [ ] "
        let items = NoteChecklist.items(in: text)
        XCTAssertEqual(items.map(\.id), [0, 2, 3, 4])
        XCTAssertEqual(items.map(\.isChecked), [false, true, true, false])
        let updated = NoteChecklist.replacing(text, itemID: 2, checked: false)
        XCTAssertEqual(updated, "- [ ] Milk\n\n- [ ] Milk\n- [x] Keep - hyphen\n- [ ] ")
        XCTAssertEqual(NoteChecklist.replacing(text, itemID: 99, checked: true), text)
    }

    func testNoteChecklistFormattingPreservesCheckedStateAndLiteralText() {
        let text = "- [x] Done - do not strip\n\n  - [ ] Next > literal\nPlain item"
        XCTAssertEqual(NoteChecklist.formatted(text, prefix: "- [ ] "), "- [x] Done - do not strip\n\n  - [ ] Next > literal\n- [ ] Plain item")
        let checked = NoteChecklist.setAll(text, checked: true)
        XCTAssertTrue(NoteChecklist.items(in: checked).allSatisfy(\.isChecked))
        XCTAssertTrue(NoteChecklist.items(in: NoteChecklist.setAll(checked, checked: false)).allSatisfy { !$0.isChecked })
        XCTAssertEqual(NoteChecklist.removing(text, itemIDs: [0]), "\n  - [ ] Next > literal\nPlain item")
    }

    func testNoteChecklistPreviewChangesPersistAndUndoWithoutOverwritingOtherFields() async {
        let (repository, store, _) = fixture()
        await repository.addQuickNote(title: "Shopping", text: "- [ ] Milk\n- [ ] Milk", tags: ["Home"], linkedTaskID: nil, format: .checklist)
        let note = repository.quickNotes[0]
        repository.setNoteChecklistItem(noteID: note.id, itemID: 1, checked: true)
        XCTAssertEqual(repository.quickNotes[0].text, "- [ ] Milk\n- [x] Milk")
        XCTAssertEqual(store.quickNotes[0].text, repository.quickNotes[0].text)
        XCTAssertEqual(repository.quickNotes[0].tags, ["Home"])
        if let undo = repository.noteUndo { repository.restoreNote(undo) } else { XCTFail("Missing checklist undo") }
        XCTAssertEqual(repository.quickNotes[0].text, note.text)
        repository.setNoteChecklistItem(noteID: note.id, itemID: 0, checked: true)
        repository.setNoteChecklistItem(noteID: note.id, itemID: 0, checked: false)
        XCTAssertEqual(repository.quickNotes[0].text, note.text)
    }

    func testShortcutSearchReturnsMoreThanTenAndFiltersCompletionAndList() {
        let tasks = (0..<40).map { index in
            TaskFlowReminderEntity(id: "\(index)", title: "Report \(index)", listName: "Work", dueDate: nil, isCompleted: index % 2 == 0, priority: 0, notes: "Budget review", listID: index < 20 ? "work" : "home")
        }
        XCTAssertEqual(TaskFlowIntentReminderEdits.filter(tasks, phrase: "", listID: nil, completion: .all, limit: 100).count, 40)
        let results = TaskFlowIntentReminderEdits.filter(tasks, phrase: "  BUDGET   report  ", listID: "work", completion: .completed, limit: 100)
        XCTAssertEqual(results.map(\.id), stride(from: 0, to: 20, by: 2).map(String.init))
        XCTAssertEqual(TaskFlowIntentReminderEdits.filter(tasks, phrase: "missing", listID: nil, completion: .all, limit: 100).count, 0)
        XCTAssertEqual(TaskFlowIntentReminderEdits.filter(tasks, phrase: "", listID: nil, completion: .incomplete, limit: 3).map(\.id), ["1", "3", "5"])
    }

    func testShortcutRescheduleAddsTimeToDateOnlyReminderAndMovesAlarm() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let oldDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let newDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 14, minute: 30)))
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = TaskFlowIntentReminderEdits.components(for: oldDate, includeTime: false, calendar: calendar)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDate.addingTimeInterval(-900)))
        reminder.addAlarm(EKAlarm(relativeOffset: -600))
        TaskFlowIntentReminderEdits.reschedule(reminder, to: newDate, includeTime: true, calendar: calendar)
        XCTAssertEqual(reminder.dueDateComponents?.hour, 14)
        XCTAssertEqual(reminder.dueDateComponents?.minute, 30)
        XCTAssertEqual(reminder.dueDateComponents?.date, newDate)
        XCTAssertTrue(reminder.alarms?.contains { $0.absoluteDate == newDate.addingTimeInterval(-900) } == true)
        XCTAssertTrue(reminder.alarms?.contains { $0.absoluteDate == nil && $0.relativeOffset == -600 } == true)
    }

    func testShortcutRescheduleSupportsAllDayAndMovesInvalidStartDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.startDateComponents = TaskFlowIntentReminderEdits.components(for: date.addingTimeInterval(86400), includeTime: true, calendar: calendar)
        TaskFlowIntentReminderEdits.reschedule(reminder, to: date, includeTime: false, calendar: calendar)
        XCTAssertNil(reminder.dueDateComponents?.hour)
        XCTAssertEqual(reminder.dueDateComponents?.date, calendar.startOfDay(for: date))
        XCTAssertEqual(reminder.startDateComponents?.date, calendar.startOfDay(for: date))
    }

    func testShortcutRoutesRoundTripIdentifiersAndConsumeOnce() {
        let suite = "TaskFlow.IntentRouteTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "source/reminder ?#% ü"
        for url in [TaskFlowDeepLink.taskURL(id), TaskFlowDeepLink.listURL(id), TaskFlowDeepLink.captureURL, TaskFlowDeepLink.newNoteURL, TaskFlowDeepLink.dictateNoteURL] {
            if url.host == "task" || url.host == "list" { XCTAssertEqual(url.pathComponents.dropFirst().first, id) }
            TaskFlowIntentRoute.open(url: url, defaults: defaults)
            XCTAssertEqual(TaskFlowIntentRoute.consume(defaults: defaults), url)
            XCTAssertNil(TaskFlowIntentRoute.consume(defaults: defaults))
        }
    }

    func testShortcutSuggestionsIncludeCompletedRemindersForReopen() {
        let tasks = (0..<100).map { index in
            TaskFlowReminderEntity(id: "\(index)", title: "Task", listName: "Inbox", dueDate: nil, isCompleted: index >= 90, priority: 0)
        }
        let suggestions = TaskFlowIntentReminderEdits.suggestions(tasks)
        XCTAssertEqual(suggestions.filter { !$0.isCompleted }.count, 30)
        XCTAssertEqual(suggestions.filter { $0.isCompleted }.count, 10)
        XCTAssertEqual(suggestions.last?.id, "99")
    }

    func testShortcutPriorityLevelsMatchReminderPriorities() {
        XCTAssertEqual(TaskFlowPriorityLevel.none.eventKitValue, 0)
        XCTAssertEqual(TaskFlowPriorityLevel.low.eventKitValue, 9)
        XCTAssertEqual(TaskFlowPriorityLevel.medium.eventKitValue, 5)
        XCTAssertEqual(TaskFlowPriorityLevel.high.eventKitValue, 1)
    }

    func testSimultaneousCloudEditsConvergeAndDeletionWins() throws {
        var a = MetadataSnapshot()
        var b = MetadataSnapshot()
        a.eventTags = ["event": ["Work"]]
        b.eventTags = ["event": ["Home"]]
        a.fieldUpdatedAt = ["eventTags/event": Date(timeIntervalSince1970: 100)]
        b.fieldUpdatedAt = a.fieldUpdatedAt
        XCTAssertEqual(try a.merging(b), try b.merging(a))
        b.eventTags = [:]
        XCTAssertNil(try a.merging(b).eventTags["event"])
        XCTAssertEqual(try a.merging(b), try b.merging(a))
    }

    func testMetadataFailedWriteIsNotPublishedAndCanRecover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataStore(directory: directory)
        let file = directory.appendingPathComponent("Metadata.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var publications = 0
        store.onChange = { publications += 1 }
        store.setEventTags(["Work"], for: "event")
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(publications, 0)
        try FileManager.default.removeItem(at: file)
        store.setEventTags(["Home"], for: "other")
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(MetadataStore(directory: directory).eventTags["event"], ["Work"])
    }

    func testPlanningRejectsUnsafeDurationAndUnboundedRange() {
        let now = Date()
        XCTAssertTrue(CalendarPlanningEngine.slots(from: now, through: now, duration: Int.max, settings: CalendarWorkspaceSettings(), events: [], tasks: []).isEmpty)
        XCTAssertTrue(CalendarPlanningEngine.slots(from: now, through: now.addingTimeInterval(400 * 86400), duration: 30, settings: CalendarWorkspaceSettings(), events: [], tasks: []).isEmpty)
    }

    func testBatchMetadataEditsPublishOnceAndPreserveRevisions() throws {
        let (_, store, _) = fixture()
        var count = 0
        store.onChange = { count += 1 }
        store.performBatchUpdates {
            for index in 0..<100 { store.setEventTags(["Work"], for: "event-\(index)") }
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.eventTags.count, 100)
        let snapshot = store.currentSnapshot()
        XCTAssertNotNil(snapshot.fieldUpdatedAt["eventTags/event-0"])
        XCTAssertNotNil(snapshot.fieldUpdatedAt["eventTags/event-99"])
    }

    func testConflictScanBoundsDenseResults() {
        let start = Date()
        let events = (0..<100).map { CalendarEvent(id: "event-\($0)", calendarID: "calendar", title: "Event", startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false) }
        XCTAssertEqual(EventConflictChecker.pairs(in: events, from: start, to: start.addingTimeInterval(3600), limit: 20).count, 20)
        XCTAssertTrue(EventConflictChecker.pairs(in: events, from: start, to: start.addingTimeInterval(3600), limit: 0).isEmpty)
    }

    func testDeletingSmartListPersistsAndDoesNotResurrectDuringSync() throws {
        let (repository, store, _) = fixture()
        let list = SmartListDefinition(title: "Temporary View")
        repository.saveSmartList(list)
        let before = store.currentSnapshot()
        repository.selectedScope = .smart(list.id)
        repository.deleteSmartList(list)
        XCTAssertEqual(repository.selectedScope, .inbox)
        XCTAssertFalse(store.smartLists.contains { $0.id == list.id })
        let after = store.currentSnapshot()
        XCTAssertFalse(try after.merging(before).smartLists.contains { $0.id == list.id })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = MetadataStore(directory: directory)
        copy.replace(with: after)
        XCTAssertFalse(MetadataStore(directory: directory).smartLists.contains { $0.id == list.id })
    }

    func testSyncSettingsCompareValuesRatherThanSerialization() throws {
        let value: [String: Any] = ["value": ["one": "cart", "two": "house"]]
        let binary = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let xml = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        XCTAssertTrue(TaskRepository.equivalentSyncedSettings(["icons": binary], ["icons": xml]))
        XCTAssertFalse(TaskRepository.equivalentSyncedSettings(["icons": binary], [:]))
        var snapshot = MetadataSnapshot()
        snapshot.syncedSettings = ["TaskFlow.listIcons": binary]
        XCTAssertEqual(snapshot.remappingListIDs([:]).syncedSettings, snapshot.syncedSettings)
    }

    func testCloudMergeKeepsIndependentRecordsAndDeletion() throws {
        var local = MetadataSnapshot()
        local.eventTags = ["one": ["Work"]]
        local.fieldUpdatedAt = ["eventTags/one": Date(timeIntervalSince1970: 10), "eventTags/deleted": Date(timeIntervalSince1970: 30)]
        var remote = MetadataSnapshot()
        remote.eventTags = ["two": ["Home"], "deleted": ["Old"]]
        remote.fieldUpdatedAt = ["eventTags/two": Date(timeIntervalSince1970: 20), "eventTags/deleted": Date(timeIntervalSince1970: 20)]
        let merged = try local.merging(remote)
        XCTAssertEqual(merged.eventTags, ["one": ["Work"], "two": ["Home"]])
        XCTAssertEqual(try merged.merging(local), merged)
    }

    func testCloudMergeKeepsIndependentSettings() throws {
        var local = MetadataSnapshot()
        local.syncedSettings = ["theme": Data([1])]
        local.fieldUpdatedAt = ["syncedSettings/theme": Date(timeIntervalSince1970: 30)]
        var remote = MetadataSnapshot()
        remote.syncedSettings = ["theme": Data([2]), "density": Data([3])]
        remote.fieldUpdatedAt = ["syncedSettings/theme": Date(timeIntervalSince1970: 20), "syncedSettings/density": Date(timeIntervalSince1970: 40)]
        let merged = try local.merging(remote)
        XCTAssertEqual(merged.syncedSettings, ["theme": Data([1]), "density": Data([3])])
    }

    func testCloudSnapshotDecodesOlderPayload() throws {
        let snapshot = try JSONDecoder().decode(MetadataSnapshot.self, from: Data("{}".utf8))
        XCTAssertTrue(snapshot.syncedSettings.isEmpty)
        XCTAssertTrue(snapshot.fieldUpdatedAt.isEmpty)
    }

    func testCloudDeletionRevisionSurvivesDiskReload() throws {
        let (_, store, _) = fixture()
        store.setEventTags(["Work"], for: "event")
        store.setEventTags([], for: "event")
        XCTAssertNotNil(store.currentSnapshot().fieldUpdatedAt["eventTags/event"])
        XCTAssertNil(store.currentSnapshot().eventTags["event"])
    }

    func testCloudListIdentityRoundTripPreservesPinsAndRevisions() throws {
        var snapshot = MetadataSnapshot()
        snapshot.pinnedListIDs = ["native", "builtin"]
        snapshot.fieldUpdatedAt = ["listProfiles/native": Date(timeIntervalSince1970: 20)]
        let cloud = snapshot.remappingListIDs(["native": "cloud-list:work"])
        XCTAssertEqual(cloud.pinnedListIDs, ["cloud-list:work", "builtin"])
        XCTAssertNotNil(cloud.fieldUpdatedAt["listProfiles/cloud-list:work"])
        XCTAssertEqual(cloud.remappingListIDs(["cloud-list:work": "native"]), snapshot)
    }

    func testCloudNewDeviceDoesNotDuplicateSeededSmartLists() throws {
        var newDevice = MetadataSnapshot()
        newDevice.fieldUpdatedAt = ["syncedSettings": Date(timeIntervalSince1970: 20)]
        var existingDevice = MetadataSnapshot()
        existingDevice.fieldUpdatedAt = ["smartLists": Date(timeIntervalSince1970: 10)]
        let merged = try newDevice.merging(existingDevice)
        XCTAssertEqual(merged.smartLists.count, existingDevice.smartLists.count)
        XCTAssertEqual(try merged.merging(newDevice).smartLists.count, existingDevice.smartLists.count)
    }

    func testEventConflictsRespectAvailabilityAndBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        func event(_ id: String, _ lower: Double, _ upper: Double, _ availability: String = "Busy") -> CalendarEvent {
            CalendarEvent(id: id, calendarID: "calendar", title: id, startDate: start.addingTimeInterval(lower), endDate: start.addingTimeInterval(upper), isAllDay: false, availability: availability)
        }
        let events = [event("before", -60, 0), event("after", 60, 120), event("busy", 10, 20), event("free", 10, 20, "Free"), event("tentative", 30, 40, "Tentative")]
        XCTAssertEqual(EventConflictChecker.overlaps(start: start, end: start.addingTimeInterval(60), events: events).map(\.id), ["busy", "tentative"])
        XCTAssertTrue(EventConflictChecker.overlaps(start: start, end: start.addingTimeInterval(60), events: events, availability: "Free").isEmpty)
        XCTAssertTrue(EventConflictChecker.overlaps(start: start, end: start, events: events).isEmpty)
    }

    func testConflictCheckExcludesOnlyEditedRecurringOccurrence() {
        let start = Date(timeIntervalSince1970: 1_000)
        let own = CalendarEvent(id: "series", calendarID: "calendar", title: "Own", startDate: start, endDate: start.addingTimeInterval(60), isAllDay: false)
        let other = CalendarEvent(id: "series", calendarID: "calendar", title: "Another occurrence", startDate: start.addingTimeInterval(20), endDate: start.addingTimeInterval(80), isAllDay: false)
        let results = EventConflictChecker.overlaps(start: start, end: start.addingTimeInterval(90), events: [own, other], excludingID: "series", excludingStart: start)
        XCTAssertEqual(results.map(\.title), ["Another occurrence"])
        XCTAssertEqual(EventDraft(event: own).originalStartDate, start)
    }

    func testConflictPageFindsEveryOverlappingPairWithoutDuplicates() {
        let start = Date(timeIntervalSince1970: 1_000)
        func event(_ id: String, _ lower: Double, _ upper: Double, _ availability: String = "Busy") -> CalendarEvent {
            CalendarEvent(id: id, calendarID: "calendar", title: id, startDate: start.addingTimeInterval(lower), endDate: start.addingTimeInterval(upper), isAllDay: false, availability: availability)
        }
        let one = event("one", 0, 60), two = event("two", 20, 80), three = event("three", 30, 70)
        let results = EventConflictChecker.pairs(in: [one, two, three, one, event("free", 0, 90, "Free"), event("adjacent", 80, 120)], from: start, to: start.addingTimeInterval(120))
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(results.map(\.id)).count, 3)
        XCTAssertEqual(results.map(\.id), EventConflictChecker.pairs(in: [three, two, one], from: start, to: start.addingTimeInterval(120)).map(\.id))
    }

    func testConflictPageClipsOverlapsToRequestedRange() {
        let start = Date(timeIntervalSince1970: 1_000)
        let one = CalendarEvent(id: "one", calendarID: "calendar", title: "one", startDate: start.addingTimeInterval(-60), endDate: start.addingTimeInterval(120), isAllDay: false)
        let two = CalendarEvent(id: "two", calendarID: "calendar", title: "two", startDate: start.addingTimeInterval(-30), endDate: start.addingTimeInterval(100), isAllDay: false)
        let results = EventConflictChecker.pairs(in: [one, two], from: start, to: start.addingTimeInterval(60))
        XCTAssertEqual(results.first?.start, start)
        XCTAssertEqual(results.first?.end, start.addingTimeInterval(60))
        XCTAssertTrue(EventConflictChecker.pairs(in: [one, two], from: start, to: start).isEmpty)
    }

    func testConflictPageSupportsAllDayToggleAndRecurringOccurrences() {
        let start = Date(timeIntervalSince1970: 1_000)
        let allDay = CalendarEvent(id: "allDay", calendarID: "calendar", title: "allDay", startDate: start, endDate: start.addingTimeInterval(86400), isAllDay: true)
        let first = CalendarEvent(id: "series", calendarID: "calendar", title: "first", startDate: start.addingTimeInterval(20), endDate: start.addingTimeInterval(60), isAllDay: false)
        let second = CalendarEvent(id: "series", calendarID: "calendar", title: "second", startDate: start.addingTimeInterval(40), endDate: start.addingTimeInterval(80), isAllDay: false)
        XCTAssertEqual(EventConflictChecker.pairs(in: [allDay, first, second], from: start, to: start.addingTimeInterval(100)).count, 3)
        XCTAssertEqual(EventConflictChecker.pairs(in: [allDay, first, second], from: start, to: start.addingTimeInterval(100), includeAllDay: false).count, 1)
    }

    func testCalendarAvailabilityExclusionsPersistWithoutHidingEvents() {
        let (repository, store, preferences) = fixture()
        let calendar = EventCalendar(id: "holidays", title: "Holidays", color: .red)
        let event = CalendarEvent(id: "event", calendarID: calendar.id, title: "Holiday", startDate: Date(), endDate: Date().addingTimeInterval(3600), isAllDay: true)
        repository.calendarEvents = [event]
        XCTAssertTrue(repository.calendarAffectsAvailability(calendar.id))
        repository.setCalendarAffectsAvailability(calendar, false)
        XCTAssertFalse(repository.calendarAffectsAvailability(calendar.id))
        XCTAssertEqual(repository.calendarEvents, [event])
        let restored = TaskRepository(preferences: preferences, metadataStore: store)
        XCTAssertFalse(restored.calendarAffectsAvailability(calendar.id))
        XCTAssertTrue(restored.calendarAffectsAvailability("work"))
        let draft = EventDraft(event: event)
        XCTAssertTrue(restored.eventConflicts(for: draft).isEmpty)
        restored.setCalendarAffectsAvailability(calendar, true)
        XCTAssertTrue(restored.calendarAffectsAvailability(calendar.id))
        XCTAssertTrue((preferences.stringArray(forKey: "TaskFlow.excludedAvailabilityCalendarIDs") ?? []).isEmpty)
    }

    func testAvailabilityExclusionsMapAcrossDeviceCalendarIDs() throws {
        let key = "TaskFlow.excludedAvailabilityCalendarIDs"
        var snapshot = MetadataSnapshot()
        snapshot.syncedSettings[key] = try PropertyListSerialization.data(fromPropertyList: ["value": ["native", "unavailable"]], format: .binary, options: 0)
        let cloud = snapshot.remappingCalendarIDs(["native": "cloud-calendar:holidays"])
        let device = cloud.remappingCalendarIDs(["cloud-calendar:holidays": "other-device-id"])
        let wrapper = try XCTUnwrap(try PropertyListSerialization.propertyList(from: XCTUnwrap(device.syncedSettings[key]), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(Set(wrapper["value"] as? [String] ?? []), ["other-device-id", "unavailable"])
    }

    private func fixture() -> (TaskRepository, MetadataStore, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TaskFlow.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = MetadataStore(directory: directory)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (TaskRepository(preferences: defaults, metadataStore: store), store, defaults)
    }

    private func task(_ id: String, completed: Bool = false, dependencies: [String] = []) -> TaskItem {
        TaskItem(id: id, metadataID: "cloud-\(id)", listID: "list", title: id, notes: "", dueDate: nil,
                 hasDueTime: false, durationMinutes: nil, location: nil, isCompleted: completed,
                 completedAt: nil, isFlagged: false, status: completed ? .done : .notStarted,
                 priority: .none, recurrence: nil, tags: [], attachments: [], comments: [],
                 parentID: nil, blockedByTaskIDs: dependencies, createdAt: nil, modifiedAt: nil)
    }

    func testProjectSectionMoveCreatesSingleUndoWithOldDetails() {
        let (repository, _, _) = fixture()
        let first = task("one"), second = task("two")
        repository.tasks = [first, second]
        repository.moveProjectItems([first, second], to: "In Progress")
        XCTAssertEqual(repository.specializedDetails(first).fields["Section"], "In Progress")
        XCTAssertEqual(repository.taskUndo?.previous.count, 2)
        XCTAssertNil(repository.taskUndo?.specializedPrevious[first.id]?.fields["Section"])
    }

    func testListLayoutsAtCompactAndAccessibilitySizes() async throws {
        let (repository, _, _) = fixture()
        repository.lists = [TaskList(id: "list", title: "Shopping", color: .blue)]
        repository.tasks = [task("Apples"), task("Whole grain bread with a longer descriptive title")]
        repository.setListProfile(.init(type: .shopping), for: "list")
        for item in repository.tasks { repository.setSpecializedDetails(.init(fields: ["Category": "Produce", "Quantity": "3", "Price": "2.50"]), for: item) }
        let (projects, _, _) = fixture()
        projects.lists = [TaskList(id: "list", title: "Projects", color: .blue)]
        projects.tasks = [task("Review the launch plan and customer feedback")]
        projects.setListProfile(.init(type: .projects, settings: ["Sections": "In Progress\nReady for Review"]), for: "list")
        projects.setSpecializedDetails(.init(fields: ["Section": "In Progress", "Milestone": "Public launch", "Blocked Reason": "Waiting for feedback from the review team"]), for: projects.tasks[0])
        let (media, _, _) = fixture()
        media.lists = [TaskList(id: "list", title: "Watch Later", color: .blue)]
        media.tasks = [task("Slow Horses · A long episode title for compact screens")]
        media.setListProfile(.init(type: .reading), for: "list")
        media.setSpecializedDetails(.init(fields: ["Format": "TV Show", "Progress": "In Progress", "Source Link": "https://tv.apple.com/show/123", "Saved From": "Apple TV", "Season": "2", "Episode": "3", "Year": "2022", "Why Saved": "A recommendation from a friend"]), for: media.tasks[0])
        let (polish, _, _) = fixture()
        polish.lists = [TaskList(id: "list", title: "Planning and projects", color: .blue), TaskList(id: "other", title: "Home", color: .green)]
        polish.tasks = [task("Prepare the agenda"), task("Review the notes")]
        polish.calendarEvents = [CalendarEvent(id: "meeting", calendarID: "calendar", title: "Project review and planning meeting", location: "Conference room", notes: nil, url: nil, startDate: Date().addingTimeInterval(3600), endDate: Date().addingTimeInterval(7200), isAllDay: false)]
        let (today, _, _) = fixture()
        today.accessState = .granted
        today.eventAccessState = .granted
        today.lists = polish.lists
        var priority = task("Prepare a clear plan for the product launch")
        priority.dueDate = Calendar.current.startOfDay(for: Date())
        var overdue = task("Review the overdue project follow-up")
        overdue.dueDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        today.tasks = [priority, overdue]
        today.calendarEvents = polish.calendarEvents
        today.toggleTodayPriority(priority)
        let (tomorrowOnly, _, _) = fixture()
        tomorrowOnly.accessState = .granted
        tomorrowOnly.eventAccessState = .granted
        tomorrowOnly.lists = polish.lists
        var tomorrowItem = task("Prepare for tomorrow’s review")
        tomorrowItem.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        tomorrowOnly.tasks = [tomorrowItem]
        for section in TodayDashboardSection.allCases where section != .tomorrow { tomorrowOnly.setTodaySectionVisible(section, false) }
        let (blockedPreview, _, _) = fixture()
        let blocker = task("Approval from the product and security review teams")
        let blockedItem = task("Publish the launch announcement", dependencies: [blocker.id])
        blockedPreview.tasks = [blocker, blockedItem]
        let (noMatches, _, _) = fixture()
        noMatches.accessState = .granted
        noMatches.tasks = [task("Plan the launch")]
        noMatches.searchQuery = "unmatched"
        today.setTodaySectionVisible(.timeline, true)
        let (focusPreview, _, _) = fixture()
        focusPreview.accessState = .granted
        focusPreview.eventAccessState = .granted
        focusPreview.tasks = [priority]
        for section in TodayDashboardSection.allCases { focusPreview.setTodaySectionVisible(section, section == .focus) }
        let (timelinePreview, _, _) = fixture()
        timelinePreview.accessState = .granted
        timelinePreview.eventAccessState = .granted
        var timedPreview = priority
        timedPreview.dueDate = Date().addingTimeInterval(60)
        timedPreview.hasDueTime = true
        timedPreview.durationMinutes = 30
        timelinePreview.tasks = [timedPreview]
        timelinePreview.calendarEvents = [CalendarEvent(id: "overlap", calendarID: "calendar", title: "Project review", location: nil, notes: nil, url: nil, startDate: Date(), endDate: Date().addingTimeInterval(1800), isAllDay: false)]
        for section in TodayDashboardSection.allCases { timelinePreview.setTodaySectionVisible(section, section == .timeline) }
        let (showPreview, _, _) = fixture()
        showPreview.tasks = [priority]
        let previewShow = ReadingMedia.ShowArtwork(id: 1, name: "Example show", url: URL(string: "https://www.tvmaze.com/shows/1/example")!, premiered: "2024-01-01", image: nil, genres: ["Drama"], status: "Running", summary: "A show saved to watch later.", averageRuntime: 45)
        let previewEpisode = ReadingMedia.ShowEpisode(id: 1, name: "Episode name", season: 1, number: 1, airdate: "2024-01-01", airstamp: nil, runtime: 45, summary: "Spoiler details stay collapsed.")
        showPreview.setSpecializedDetails(.init(fields: ["Show Tracking": ReadingMedia.encodeTracking(.init(show: previewShow, episodes: [previewEpisode], cast: ["Example actor"]))]), for: priority)
        showPreview.setListProfile(.init(type: .reading), for: priority.listID)
        let upcomingEpisode = ReadingMedia.ShowEpisode(id: 2, name: "Future episode", season: 1, number: 2, airdate: nil, airstamp: ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)), runtime: 45, summary: nil)
        showPreview.setSpecializedDetails(.init(fields: ["Show Tracking": ReadingMedia.encodeTracking(.init(show: previewShow, episodes: [previewEpisode, upcomingEpisode], cast: ["Example actor"]))]), for: priority)
        let views: [(String, AnyView, DynamicTypeSize)] = [
            ("watch-upcoming-compact", AnyView(UpcomingWatchReleases(repository: showPreview, listID: priority.listID)), .large),
            ("watch-upcoming-accessibility", AnyView(UpcomingWatchReleases(repository: showPreview, listID: priority.listID)), .accessibility3),
            ("watch-tracker-compact", AnyView(WatchShowTracker(repository: showPreview, taskID: priority.id)), .large),
            ("watch-tracker-accessibility", AnyView(WatchShowTracker(repository: showPreview, taskID: priority.id)), .accessibility3),
            ("focus-next-accessibility", AnyView(NavigationStack { TodayDashboardView(repository: focusPreview, editorDraft: .constant(nil)) }), .accessibility3),
            ("focus-next-compact", AnyView(NavigationStack { TodayDashboardView(repository: focusPreview, editorDraft: .constant(nil)) }), .large),
            ("combined-timeline-compact", AnyView(NavigationStack { TodayDashboardView(repository: timelinePreview, editorDraft: .constant(nil)) }), .large),
            ("row-reschedule-accessibility", AnyView(BulkRescheduleTasksSheet(selectedCount: 1, initialTask: priority) { _, _ in }), .accessibility3),
            ("no-matching-tasks-accessibility", AnyView(NavigationStack { List { EmptyTaskStateView(repository: noMatches, editorDraft: .constant(nil)) } }), .accessibility3),
            ("today-tomorrow-collapsed", AnyView(NavigationStack { TodayDashboardView(repository: tomorrowOnly, editorDraft: .constant(nil)) }), .large),
            ("today-waiting-accessibility", AnyView(NavigationStack { List { TaskRowView(task: blockedItem, subtasks: [], isSelected: false, listColor: .blue, tagColor: { _ in .blue }, density: .comfortable, repository: blockedPreview) } }), .accessibility3),
            ("today-sections-accessibility", AnyView(TodaySectionsEditor(repository: today)), .accessibility3),
            ("today-compact", AnyView(NavigationStack { TodayDashboardView(repository: today, editorDraft: .constant(nil)) }), .large),
            ("today-accessibility", AnyView(NavigationStack { TodayDashboardView(repository: today, editorDraft: .constant(nil)) }), .accessibility3),
            ("today-priorities-compact", AnyView(TodayPriorityPicker(repository: today)), .large),
            ("today-overdue-accessibility", AnyView(TodayOverduePlanner(repository: today)), .accessibility3),
            ("note-formatting-compact", AnyView(NavigationStack { Form { NoteFormattingTextEditor(text: .constant("A simple note with **one bold word**.\n- A bullet item\n\nA normal paragraph after the list."), command: .constant(nil), focused: .constant(false)).frame(height: 180); QuickNoteFormattingToolbar(format: .constant(.markdown), text: .constant("Note"), command: .constant(nil)) } }), .large),
            ("note-formatting-accessibility", AnyView(NavigationStack { Form { NoteFormattingTextEditor(text: .constant("A simple note with **one bold word**.\n- A bullet item\n\nA normal paragraph after the list."), command: .constant(nil), focused: .constant(false)).frame(height: 220); QuickNoteFormattingToolbar(format: .constant(.markdown), text: .constant("Note"), command: .constant(nil)) } }), .accessibility3),
            ("list-order-compact", AnyView(NavigationStack { ListOrderEditor(repository: polish) }), .large),
            ("list-icons-accessibility", AnyView(NavigationStack { ListIconPicker(selection: .constant("film")) }), .accessibility3),
            ("dependencies-compact", AnyView(NavigationStack { DependencyTaskPicker(repository: polish, taskID: polish.tasks[0].id) }), .large),
            ("event-link-accessibility", AnyView(NavigationStack { EventLinkPicker(repository: polish, selection: .constant("")) }), .accessibility3),
            ("tag-chips-accessibility", AnyView(NavigationStack { Form { TagSelectionEditor(savedTags: [], selectedTags: .constant(["Work", "Personal", "A longer tag name"]), colorForTag: { _ in .blue }, onCreate: { _ in }) } }), .accessibility3),
            ("type-chooser-compact", AnyView(NavigationStack { ListTypeChooser(selection: .constant(.packing)) }), .large),
            ("type-chooser-accessibility", AnyView(NavigationStack { ListTypeChooser(selection: .constant(.packing)) }), .accessibility3),
            ("shopping-compact", AnyView(NavigationStack { SpecializedTaskListView(repository: repository, listID: "list", editorDraft: .constant(nil)).navigationTitle("Shopping") }), .large),
            ("shopping-accessibility", AnyView(NavigationStack { SpecializedTaskListView(repository: repository, listID: "list", editorDraft: .constant(nil)).navigationTitle("Shopping") }), .accessibility3),
            ("project-board-compact", AnyView(NavigationStack { SpecializedTaskListView(repository: projects, listID: "list", viewMode: .board, editorDraft: .constant(nil)).navigationTitle("Projects") }), .large),
            ("project-board-accessibility", AnyView(NavigationStack { SpecializedTaskListView(repository: projects, listID: "list", viewMode: .board, editorDraft: .constant(nil)).navigationTitle("Projects") }), .accessibility3),
            ("media-list-compact", AnyView(NavigationStack { SpecializedTaskListView(repository: media, listID: "list", editorDraft: .constant(nil)).navigationTitle("Watch Later") }), .large),
            ("media-list-accessibility", AnyView(NavigationStack { SpecializedTaskListView(repository: media, listID: "list", editorDraft: .constant(nil)).navigationTitle("Watch Later") }), .accessibility3),
            ("media-editor-compact", AnyView(NavigationStack { SpecializedTaskEditor(repository: media, task: media.tasks[0], type: .reading) }), .large),
            ("media-editor-accessibility", AnyView(NavigationStack { SpecializedTaskEditor(repository: media, task: media.tasks[0], type: .reading) }), .accessibility3),
            ("media-detail-compact", AnyView(NavigationStack { MediaItemDetailView(repository: media, task: media.tasks[0]) }), .large),
            ("media-detail-accessibility", AnyView(NavigationStack { MediaItemDetailView(repository: media, task: media.tasks[0]) }), .accessibility3),
            ("numeric-field-accessibility", AnyView(NavigationStack { Form { ListNumberField(title: "Estimated Minutes", value: .constant("15"), integer: true) } }), .accessibility3)
        ]
        for (name, view, size) in views {
            let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size).environment(\.colorScheme, .light))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
            window.backgroundColor = .white
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(image.size.width, 320)
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 2_000, "The layout snapshot must contain rendered content.")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
            try image.pngData()?.write(to: file)
            print("LAYOUT_SNAPSHOT " + file.path)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    func testBulkListEditCapturesOneUndoAndPreservesOtherFields() async throws {
        let (repository, store, _) = fixture()
        let first = task("first"), second = task("second")
        var other = task("elsewhere")
        other.listID = "other"
        repository.tasks = [first, second, other]
        repository.setListProfile(.init(type: .household), for: "list")
        repository.setSpecializedDetails(.init(fields: ["Room": "Kitchen", "Instructions": "Use gentle cleaner"]), for: first)
        let applied = await repository.bulkUpdateListDetails(ids: [first.id, second.id, other.id], listID: "list", field: "Room", value: "Bathroom")
        XCTAssertEqual(applied, [first.id, second.id])
        XCTAssertEqual(repository.specializedDetails(first).fields["Room"], "Bathroom")
        XCTAssertEqual(repository.specializedDetails(first).fields["Instructions"], "Use gentle cleaner")
        XCTAssertNil(repository.specializedDetails(other).fields["Room"])
        let undo = try XCTUnwrap(repository.taskUndo)
        XCTAssertEqual(undo.previous.map(\.id), [first.id, second.id])
        XCTAssertEqual(undo.specializedPrevious[first.id]?.fields["Room"], "Kitchen")
        XCTAssertNil(undo.specializedPrevious[second.id]?.fields["Room"])
        XCTAssertEqual(store.specializedTasks[first.metadataID]?.fields["Room"], "Bathroom")
        let restored = await repository.performUndo(undo)
        XCTAssertTrue(restored)
        XCTAssertEqual(repository.specializedDetails(first).fields["Room"], "Kitchen")
        XCTAssertEqual(repository.specializedDetails(first).fields["Instructions"], "Use gentle cleaner")
        XCTAssertNil(repository.specializedDetails(second).fields["Room"])
        XCTAssertNil(repository.taskUndo)
    }

    func testBulkListEditRejectsInvalidFieldsAndDoesNotReplaceUndoForNoOp() async {
        let (repository, _, _) = fixture()
        let first = task("first")
        repository.tasks = [first]
        repository.setListProfile(.init(type: .projects), for: "list")
        let invalid = await repository.bulkUpdateListDetails(ids: [first.id], listID: "list", field: "Amount", value: "10")
        XCTAssertTrue(invalid.isEmpty)
        _ = await repository.bulkUpdateListDetails(ids: [first.id], listID: "list", field: "Section", value: "Review")
        let undoID = repository.taskUndo?.id
        let same = await repository.bulkUpdateListDetails(ids: [first.id], listID: "list", field: "Section", value: "Review")
        XCTAssertEqual(same, [first.id])
        XCTAssertEqual(repository.taskUndo?.id, undoID)
        _ = await repository.bulkUpdateListDetails(ids: [first.id], listID: "list", field: "Section", value: "")
        XCTAssertNil(repository.specializedDetails(first).fields["Section"])
        XCTAssertEqual(repository.taskUndo?.specializedPrevious[first.id]?.fields["Section"], "Review")
    }

    func testCompletionKeepsWorkflowStagesAndOtherFieldsConsistent() {
        let finished = SpecializedListType.reading.fieldsForCompletion(true, fields: ["Progress": "In Progress", "Creator": "Author"])
        XCTAssertEqual(finished["Progress"], "Finished")
        XCTAssertEqual(finished["Creator"], "Author")
        XCTAssertEqual(SpecializedListType.reading.fieldsForCompletion(false, fields: finished)["Progress"], "Saved")
        XCTAssertEqual(SpecializedListType.packing.fieldsForCompletion(true, fields: [:])["Stage"], "Packed")
        XCTAssertEqual(SpecializedListType.bills.fieldsForCompletion(true, fields: ["Stage": "Canceled"])["Stage"], "Canceled")
        XCTAssertEqual(SpecializedListType.bills.fieldsForCompletion(false, fields: ["Stage": "Paid"])["Stage"], "Unpaid")
        XCTAssertEqual(SpecializedListType.household.fieldsForCompletion(true, fields: ["Room": "Kitchen"]), ["Room": "Kitchen"])
    }

    func testListWorkflowProgressDistinguishesCanceledBills() {
        XCTAssertTrue(SpecializedListType.bills.workflowDone(completed: true, fields: ["Stage": "Paid"]))
        XCTAssertFalse(SpecializedListType.bills.workflowDone(completed: true, fields: ["Stage": "Canceled"]))
        XCTAssertTrue(SpecializedListType.packing.workflowDone(completed: false, fields: ["Stage": "Packed"]))
        XCTAssertFalse(SpecializedListType.packing.workflowDone(completed: false, fields: ["Stage": "Prepared"]))
        XCTAssertTrue(SpecializedListType.reading.workflowDone(completed: false, fields: ["Progress": "Finished"]))
        XCTAssertFalse(SpecializedListType.reading.workflowDone(completed: false, fields: ["Progress": "In Progress"]))
        XCTAssertEqual(ListEmptyState.resolve(total: 0, open: 0), .empty)
        XCTAssertEqual(ListEmptyState.resolve(total: 3, open: 0), .finished)
        XCTAssertEqual(ListEmptyState.resolve(total: 3, open: 1), .filtered)
    }

    func testListNumberFieldsValidateLocalizedFractionsAndWholeMinutes() {
        XCTAssertEqual(ListFieldNumber.parse("0,5", key: "Quantity", decimalSeparator: ","), 0.5)
        XCTAssertEqual(ListFieldNumber.parse("12,50", key: "Amount", decimalSeparator: ","), 12.5)
        XCTAssertNil(ListFieldNumber.parse("1.5", key: "Timer Minutes"))
        XCTAssertNil(ListFieldNumber.parse("0", key: "Timer Minutes"))
        XCTAssertNil(ListFieldNumber.parse("-4", key: "Amount"))
        XCTAssertNil(ListFieldNumber.parse("nan", key: "Quantity"))
        XCTAssertNil(ListFieldNumber.parse("inf", key: "Price"))
        XCTAssertEqual(ListFieldNumber.parse("0", key: "Amount"), 0)
    }

    func testListTypeGuidesAndStarterTemplatesAreComplete() throws {
        for type in SpecializedListType.allCases {
            XCTAssertFalse(type.shortDescription.isEmpty)
            XCTAssertFalse(type.example.title.isEmpty)
            if type == .standard { continue }
            let template = try XCTUnwrap(type.starterTemplate(index: 0, listID: "list"))
            XCTAssertEqual(template.listID, "list")
            XCTAssertFalse(template.items.isEmpty)
        }
        let routine = try XCTUnwrap(SpecializedListType.routines.starterTemplate(index: 0, listID: "list"))
        XCTAssertEqual(routine.items.map { $0.details.fields["Step Order"] }, ["1", "2", "3"])
        XCTAssertNil(SpecializedListType.packing.starterTemplate(index: 99, listID: "list"))
    }

    func testClearShoppingSelectionIncludesOnlyCompletedItemsInThatList() {
        let (repository, _, _) = fixture()
        let complete = task("bought", completed: true)
        let open = task("needed")
        var elsewhere = task("other", completed: true)
        elsewhere.listID = "other-list"
        repository.tasks = [complete, open, elsewhere]
        XCTAssertTrue(repository.completedShoppingItemIDs(in: "list").isEmpty)
        repository.setListProfile(.init(type: .shopping), for: "list")
        XCTAssertEqual(repository.completedShoppingItemIDs(in: "list"), [complete.id])
        XCTAssertTrue(repository.completedShoppingItemIDs(in: "other-list").isEmpty)
    }

    func testCalendarFetchRangesMergeOverlapWithoutFetchingGaps() {
        let date = Date(timeIntervalSince1970: 1000)
        let first = DateInterval(start: date, duration: 100)
        let overlap = DateInterval(start: date.addingTimeInterval(50), duration: 150)
        XCTAssertEqual(TaskRepository.mergedCalendarRanges(first, overlap), [DateInterval(start: date, duration: 200)])
        let distant = DateInterval(start: date.addingTimeInterval(1000), duration: 100)
        XCTAssertEqual(TaskRepository.mergedCalendarRanges(distant, first), [first, distant])
    }

    func testUnchangedMetadataDoesNotTriggerAnotherPersistenceUpdate() {
        let (_, store, _) = fixture()
        let profile = SpecializedListProfile(type: .shopping, settings: ["Group Store": "true"])
        store.listProfiles = ["list": profile]
        let updated = store.currentSnapshot().cloudUpdatedAt
        store.listProfiles = ["list": profile]
        XCTAssertEqual(store.currentSnapshot().cloudUpdatedAt, updated)
        store.specializedTasks = ["task": SpecializedTaskDetails(fields: ["Store": "Target"])]
        let taskUpdated = store.currentSnapshot().cloudUpdatedAt
        let existing = store.specializedTasks
        store.specializedTasks = existing
        XCTAssertEqual(store.currentSnapshot().cloudUpdatedAt, taskUpdated)
    }

    func testCompletedClearCandidatesRespectListAndSearch() {
        let (repository, _, _) = fixture()
        var complete = task("Milk", completed: true)
        complete.tags = ["groceries"]
        let open = task("Bread")
        var elsewhere = task("Milk elsewhere", completed: true)
        elsewhere.listID = "other"
        repository.tasks = [complete, open, elsewhere]
        repository.selectedScope = .list("list")
        repository.includeCompletedTasks = false
        XCTAssertEqual(repository.completedTasksInSelectedScope.map(\.id), [complete.id])
        repository.searchQuery = "Bread"
        XCTAssertTrue(repository.completedTasksInSelectedScope.isEmpty)
        repository.searchQuery = "#groceries"
        XCTAssertEqual(repository.completedTasksInSelectedScope.map(\.id), [complete.id])
        repository.searchQuery = ""
        repository.selectedScope = .completed
        XCTAssertEqual(Set(repository.completedTasksInSelectedScope.map(\.id)), [complete.id, elsewhere.id])
    }

    func testShoppingStoreFilterMatchesNamesAndScopesCompletedClearing() {
        let (repository, _, _) = fixture()
        let target = task("target", completed: true), home = task("home", completed: true), unset = task("unset")
        repository.tasks = [target, home, unset]
        repository.setSpecializedDetails(.init(fields: ["Store": " Target "]), for: target)
        repository.setSpecializedDetails(.init(fields: ["Store": "Home Depot"]), for: home)
        repository.setListProfile(.init(type: .shopping, settings: ["Store Filter": "target"]), for: "list")
        repository.selectedScope = .list("list")
        XCTAssertTrue(repository.shoppingTask(target, matchesStore: "TARGET"))
        XCTAssertTrue(repository.shoppingTask(unset, matchesStore: ""))
        XCTAssertEqual(repository.completedTasksInSelectedScope.map(\.id), [target.id])
        repository.setListProfile(.init(type: .shopping), for: "list")
        XCTAssertEqual(Set(repository.completedTasksInSelectedScope.map(\.id)), [target.id, home.id])
    }

    func testShoppingSharedNotesRoundTripPreservesUserTextAndDetails() {
        let notes = "Bring coupons.\nChoose the organic brand."
        let details = SpecializedTaskDetails(fields: ["Quantity": "3", "Unit": "bags", "Store": "Market", "Added By": "Alex", "Purchased By": "Sam", "Price": "2.50"])
        let encoded = ShoppingReminderNotes.encode(notes, details: details)
        let decoded = ShoppingReminderNotes.decode(encoded)
        XCTAssertEqual(decoded.text, notes)
        XCTAssertEqual(decoded.details, details)
        XCTAssertEqual(ShoppingReminderNotes.encode(encoded, details: details), encoded)
        XCTAssertEqual(ShoppingReminderNotes.decode(ShoppingReminderNotes.encode("", details: details)).text, "")
    }

    func testShoppingMalformedSharedEnvelopeDoesNotRemoveUserText() {
        for notes in ["Ordinary notes", "A note\n\n[TaskFlow Shopping v1] invalid", "A note\n\n[TaskFlow Shopping v1] e30=", "A note\n\n[TaskFlow Shopping v1] dGV4dA=="] {
            XCTAssertEqual(ShoppingReminderNotes.decode(notes).text, notes)
            XCTAssertNil(ShoppingReminderNotes.decode(notes).details)
        }
    }

    func testShoppingBudgetUsesQuantityAndRejectsInvalidPrices() {
        XCTAssertEqual(ShoppingQuantity.cost(["Quantity": "3", "Price": "2.50"]), 7.5)
        XCTAssertEqual(ShoppingQuantity.cost(["Price": "2.50"]), 2.5)
        XCTAssertEqual(ShoppingQuantity.cost(["Quantity": "0.5", "Price": "4"]), 2)
        XCTAssertEqual(ShoppingQuantity.cost(["Price": "0"]), 0)
        for fields in [["Price": "-1"], ["Price": "nan"], ["Price": "inf"], ["Price": "2", "Quantity": "custom"], ["Price": "2", "Quantity": "0"], ["Price": "1e308", "Quantity": "1e308"]] {
            XCTAssertNil(ShoppingQuantity.cost(fields))
        }
    }

    func testShoppingQuantityFormattingKeepsFractionsWithoutGrouping() {
        XCTAssertEqual(ShoppingQuantity.text(3), "3")
        XCTAssertEqual(ShoppingQuantity.text(1.5), "1.5")
        XCTAssertEqual(ShoppingQuantity.text(1000), "1000")
        XCTAssertEqual(ShoppingQuantity.value(nil), 1)
        XCTAssertNil(ShoppingQuantity.value("nan"))
        XCTAssertNil(ShoppingQuantity.value("-1"))
    }

    func testShoppingDuplicatesRespectStoreUnitAndCompletedState() {
        let (repository, _, _) = fixture()
        var open = task("open")
        open.title = " Apples "
        let completed = task("completed", completed: true)
        repository.tasks = [open, completed]
        repository.setSpecializedDetails(.init(fields: ["Store": "Market", "Unit": "bags"]), for: open)
        let match = SpecializedListTemplate.Item(title: "apples", notes: "", details: .init(fields: ["Store": "market", "Unit": "BAGS"]))
        XCTAssertEqual(repository.shoppingDuplicate(match, listID: "list", store: "")?.id, open.id)
        XCTAssertNil(repository.shoppingDuplicate(match, listID: "other", store: ""))
        XCTAssertNil(repository.shoppingDuplicate(match, listID: "list", store: "Elsewhere"))
        var differentUnit = match
        differentUnit.details.fields["Unit"] = "pounds"
        XCTAssertNil(repository.shoppingDuplicate(differentUnit, listID: "list", store: ""))
        let completedItem = SpecializedListTemplate.Item(title: completed.title, notes: "", details: .init())
        XCTAssertNil(repository.shoppingDuplicate(completedItem, listID: "list", store: ""))
        XCTAssertTrue(repository.shoppingHasDuplicates([differentUnit, differentUnit], listID: "list", store: ""))
    }

    func testShoppingRepeatSuggestionsUseUsualQuantityAndPreserveStore() {
        let (repository, _, _) = fixture()
        var first = task("one", completed: true), second = task("two", completed: true), recent = task("three", completed: true)
        first.title = "Milk"; second.title = "Milk"; recent.title = "Milk"
        first.completedAt = Date(timeIntervalSince1970: 1)
        second.completedAt = Date(timeIntervalSince1970: 2)
        recent.completedAt = Date(timeIntervalSince1970: 3)
        var open = task("open"); open.title = "Bread"
        repository.tasks = [first, second, recent, open]
        for item in [first, second] {
            repository.setSpecializedDetails(.init(fields: ["Quantity": "2", "Unit": "bottles", "Store": "Market", "Purchased By": "Alex", "Added By": "Alex"]), for: item)
        }
        repository.setSpecializedDetails(.init(fields: ["Quantity": "1", "Unit": "bottles", "Store": "Market"]), for: recent)
        let suggestions = repository.shoppingRepeatSuggestions(listID: "list")
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.details.fields["Quantity"], "2")
        XCTAssertEqual(suggestions.first?.details.fields["Unit"], "bottles")
        XCTAssertEqual(suggestions.first?.details.fields["Store"], "Market")
        XCTAssertNil(suggestions.first?.details.fields["Purchased By"])
        XCTAssertNil(suggestions.first?.details.fields["Added By"])
    }

    func testShoppingSharedDetailsTakePrecedenceOverPrivateMetadata() {
        let (repository, _, _) = fixture()
        var item = task("shared")
        item.sharedShoppingDetails = .init(fields: ["Quantity": "4", "Purchased By": "Sam"])
        repository.tasks = [item]
        repository.specializedTasks[item.metadataID] = .init(fields: ["Quantity": "1"])
        XCTAssertEqual(repository.specializedDetails(item).fields["Quantity"], "4")
        repository.setSpecializedDetails(.init(fields: ["Quantity": "5"]), for: item)
        XCTAssertEqual(repository.specializedDetails(item).fields["Quantity"], "5")
        XCTAssertEqual(repository.specializedTasks[item.metadataID]?.fields["Quantity"], "5")
    }

    func testShopperPickerRemembersNamesDeduplicatesAndDiscoversSharedShoppers() {
        let (repository, store, defaults) = fixture()
        repository.selectShoppingShopper(" Alex ")
        repository.selectShoppingShopper("Sam")
        repository.selectShoppingShopper("alex")
        XCTAssertEqual(repository.shoppingShopperName, "Alex")
        XCTAssertEqual(repository.shoppingShopperChoices, ["Alex", "Sam"])
        repository.selectShoppingShopper("")
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(restored.shoppingShopperChoices, ["Alex", "Sam"])
        var shared = task("shared-shopper")
        shared.sharedShoppingDetails = .init(fields: ["Added By": "Taylor", "Purchased By": "Unnamed shopper"])
        restored.tasks = [shared]
        XCTAssertEqual(restored.shoppingShopperChoices, ["Alex", "Sam", "Taylor"])
        restored.selectShoppingShopper("Taylor")
        restored.tasks = []
        XCTAssertTrue(restored.shoppingShopperChoices.contains("Taylor"))
    }

    func testShoppingShopperNamePersists() {
        let (repository, store, defaults) = fixture()
        repository.shoppingShopperName = "Alex"
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(restored.shoppingShopperName, "Alex")
    }

    func testExpandedShoppingCategorySuggestionsAndLegacyAliases() {
        let examples = ["Frozen peas": "Frozen Foods", "Dog food": "Pet Supplies", "Paper towels": "Paper & Disposable Goods", "Baby formula": "Baby & Kids", "Rotisserie chicken": "Deli & Prepared Foods", "Canned beans": "Canned & Jarred Goods", "Flour": "Baking Supplies", "Cereal": "Breakfast & Cereal", "Mustard": "Condiments & Spices", "Chocolate": "Snacks & Candy", "Detergent": "Cleaning Supplies", "Vitamins": "Health & Pharmacy", "Caulk": "Home Improvement", "Mulch": "Garden & Outdoor", "Socks": "Clothing & Accessories"]
        for (title, expected) in examples { XCTAssertEqual(ShoppingCatalog.category(for: title), expected, title) }
        XCTAssertEqual(ShoppingCatalog.canonicalCategory("Frozen"), "Frozen Foods")
        XCTAssertEqual(ShoppingCatalog.canonicalCategory("snacks"), "Snacks & Candy")
    }

    func testCustomCategoriesPersistDeduplicateAndKeepAssignedItems() {
        let (repository, store, defaults) = fixture()
        XCTAssertEqual(repository.addShoppingCategory(" Party Supplies ", listID: "list"), "Party Supplies")
        XCTAssertEqual(repository.addShoppingCategory("party supplies", listID: "list"), "Party Supplies")
        XCTAssertEqual(repository.addShoppingCategory("frozen", listID: "list"), "Frozen Foods")
        XCTAssertEqual(repository.shoppingCustomCategories(listID: "list"), ["Party Supplies"])
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertTrue(restored.shoppingCategories(listID: "list").contains("Party Supplies"))
        let item = task("party")
        restored.tasks = [item]
        restored.setSpecializedDetails(.init(fields: ["Category": "Party Supplies"]), for: item)
        restored.removeShoppingCategory("Party Supplies", listID: "list")
        XCTAssertTrue(restored.shoppingCustomCategories(listID: "list").isEmpty)
        XCTAssertEqual(restored.specializedDetails(item).fields["Category"], "Party Supplies")
        XCTAssertTrue(restored.shoppingCategories(listID: "list").contains("Party Supplies"))
    }

    func testPerStoreAisleOrdersPersistAndFallBackToDefault() {
        let (repository, store, defaults) = fixture()
        repository.setShoppingCategoryOrder(["Bakery", "Produce"], listID: "list", store: nil)
        repository.setShoppingCategoryOrder(["Dairy & Eggs", "Produce"], listID: "list", store: " Market ")
        XCTAssertEqual(Array(repository.shoppingCategoryOrder(listID: "list", store: "MARKET").prefix(2)), ["Dairy & Eggs", "Produce"])
        XCTAssertEqual(Array(repository.shoppingCategoryOrder(listID: "list", store: "Elsewhere").prefix(2)), ["Bakery", "Produce"])
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(Array(restored.shoppingCategoryOrder(listID: "list", store: "market").prefix(2)), ["Dairy & Eggs", "Produce"])
        restored.setShoppingCategoryOrder(nil, listID: "list", store: "market")
        XCTAssertEqual(Array(restored.shoppingCategoryOrder(listID: "list", store: "market").prefix(2)), ["Bakery", "Produce"])
        restored.setShoppingCategoryOrder(nil, listID: "list", store: nil)
        XCTAssertEqual(restored.shoppingCategoryOrder(listID: "list", store: nil), ShoppingCatalog.categories)
    }

    func testCommonListLayoutSuggestions() {
        XCTAssertEqual(SpecializedListType.suggested(for: "Weekly Groceries"), .shopping)
        XCTAssertEqual(SpecializedListType.suggested(for: "Read Later"), .reading)
        XCTAssertEqual(SpecializedListType.suggested(for: "Watch Later 🎬"), .reading)
        XCTAssertNil(SpecializedListType.suggested(for: "Work"))
        XCTAssertNil(SpecializedListType.suggested(for: "Shoppington"))
    }

    func testShoppingDefaultStorePersistsWithoutChangingItemOverrides() {
        let (repository, store, defaults) = fixture()
        let item = task("item")
        repository.tasks = [item]
        repository.setSpecializedDetails(.init(fields: ["Store": "Other Store"]), for: item)
        var profile = SpecializedListProfile(type: .shopping, settings: ["Default Store": " Market ", "Last Store": "Previous Store"])
        repository.setListProfile(profile, for: "list")
        XCTAssertEqual(repository.shoppingCaptureStore(for: "list"), "Market")
        XCTAssertTrue(repository.shoppingStores(for: "list").contains("Market"))
        XCTAssertEqual(repository.specializedDetails(item).fields["Store"], "Other Store")
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(restored.shoppingCaptureStore(for: "list"), "Market")
        profile.settings["Store Filter"] = "Selected Store"
        restored.setListProfile(profile, for: "list")
        XCTAssertEqual(restored.shoppingCaptureStore(for: "list"), "Selected Store")
        profile.settings["Store Filter"] = " "
        restored.setListProfile(profile, for: "list")
        XCTAssertEqual(restored.shoppingCaptureStore(for: "list"), "Market")
        profile.settings["Default Store"] = ""
        restored.setListProfile(profile, for: "list")
        XCTAssertEqual(restored.shoppingCaptureStore(for: "list"), "Previous Store")
    }

    func testPriceHistorySurvivesRemovedItemsAndMatchesStoreAndUnit() {
        let (repository, store, defaults) = fixture()
        let fields = ["Store": " Market ", "Unit": "bottles", "Price": "3.49"]
        repository.rememberShoppingEstimate(title: " Milk ", fields: fields)
        repository.tasks = []
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(restored.rememberedShoppingPrice(title: "milk", fields: ["Store": "MARKET", "Unit": "BOTTLES"]), 3.49)
        XCTAssertNil(restored.rememberedShoppingPrice(title: "milk", fields: ["Store": "Elsewhere", "Unit": "bottles"]))
        XCTAssertNil(restored.rememberedShoppingPrice(title: "milk", fields: ["Store": "Market", "Unit": "gallons"]))
        XCTAssertNil(restored.rememberedShoppingPrice(title: "bread", fields: fields))
        restored.rememberShoppingEstimate(title: "milk", fields: ["Store": "Market", "Unit": "bottles", "Price": "4.25"])
        XCTAssertEqual(restored.rememberedShoppingPrice(title: "milk", fields: fields), 4.25)
    }

    func testPriceHistorySeedsNewestItemsWithoutOverwritingCorrections() {
        let (repository, _, _) = fixture()
        var old = task("old-price"), recent = task("new-price")
        old.title = "Milk"; recent.title = "Milk"
        old.modifiedAt = Date(timeIntervalSince1970: 1)
        recent.modifiedAt = Date(timeIntervalSince1970: 2)
        old.sharedShoppingDetails = .init(fields: ["Price": "1.50"])
        recent.sharedShoppingDetails = .init(fields: ["Price": "2.50"])
        repository.seedShoppingPriceHistory(from: [old, recent])
        XCTAssertEqual(repository.rememberedShoppingPrice(title: "Milk", fields: [:]), 2.5)
        repository.rememberShoppingEstimate(title: "Milk", fields: ["Price": "3.25"])
        repository.seedShoppingPriceHistory(from: [old, recent])
        XCTAssertEqual(repository.rememberedShoppingPrice(title: "Milk", fields: [:]), 3.25)
    }

    func testPriceEntryAcceptsLocalizedDecimalsAndRejectsInvalidText() {
        XCTAssertEqual(ShoppingPriceInput.value("3.49", locale: Locale(identifier: "en_US")), 3.49)
        XCTAssertEqual(ShoppingPriceInput.value("3,49", locale: Locale(identifier: "de_DE")), 3.49)
        XCTAssertEqual(ShoppingPriceInput.value("٣٫٤٩", locale: Locale(identifier: "ar_SA")), 3.49)
        XCTAssertEqual(ShoppingPriceInput.value("0"), 0)
        for raw in ["", "-1", "nan", "inf", "3.4.5", "3 apples", "$3.49"] { XCTAssertNil(ShoppingPriceInput.value(raw)) }
    }

    func testPriceAwareSuggestionUsesMatchingStoreEstimate() {
        let (repository, _, _) = fixture()
        repository.rememberShoppingEstimate(title: "Milk", fields: ["Store": "Market", "Unit": "bottles", "Price": "3.49"])
        repository.rememberShoppingEstimate(title: "Milk", fields: ["Store": "Other Store", "Unit": "bottles", "Price": "4.25"])
        let item = SpecializedListTemplate.Item(title: "Milk", notes: "usual brand", details: .init(fields: ["Store": "Market", "Unit": "bottles", "Price": "2.99"]))
        let suggestion = repository.pricedShoppingSuggestion(item, store: "Other Store")
        XCTAssertEqual(suggestion.details.fields["Price"], "4.25")
        XCTAssertEqual(suggestion.details.fields["Store"], "Other Store")
        XCTAssertEqual(suggestion.notes, "usual brand")
        XCTAssertEqual(repository.pricedShoppingSuggestion(item, store: "").details.fields["Price"], "3.49")
    }

    func testPriceRecallPreservesExplicitEstimatesAndRejectsInvalidHistory() {
        let (repository, _, _) = fixture()
        repository.rememberShoppingEstimate(title: "Apples", fields: ["Price": "2.50"])
        XCTAssertEqual(repository.recallingShoppingPrice(title: "apples", details: .init()).fields["Price"], "2.5")
        XCTAssertEqual(repository.recallingShoppingPrice(title: "apples", details: .init(fields: ["Price": "1.99"])).fields["Price"], "1.99")
        for price in ["nan", "inf", "-1", ""] { repository.rememberShoppingEstimate(title: "Apples", fields: ["Price": price]) }
        XCTAssertEqual(repository.rememberedShoppingPrice(title: "Apples", fields: [:]), 2.5)
        repository.rememberShoppingEstimate(title: "Free item", fields: ["Price": "0"])
        XCTAssertEqual(repository.rememberedShoppingPrice(title: "Free item", fields: [:]), 0)
    }

    func testShoppingPasteParsesQuantitiesAndCategories() {
        let items = ShoppingCatalog.parse("2 apples\n• Milk\n\n- Bread\nParty decorations")
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0], ShoppingCaptureItem(title: "apples", quantity: "2", category: "Produce"))
        XCTAssertEqual(items[1].category, "Dairy & Eggs")
        XCTAssertEqual(items[2].title, "Bread")
        XCTAssertEqual(items[3].category, "Other")
        XCTAssertEqual(ShoppingCatalog.category(for: "Pineapple candle"), "Other")
    }

    func testTemplateEditingAndDeletionPreserveSpecializedDetails() {
        let (repository, store, _) = fixture()
        var details = SpecializedTaskDetails()
        details.fields["Required"] = "Yes"
        var template = SpecializedListTemplate(title: "Morning", listID: "list", items: [.init(title: "Plan", notes: "", details: details)])
        repository.listTemplates = [template]
        template.title = "Weekday Morning"
        repository.updateListTemplate(template)
        XCTAssertEqual(store.listTemplates.first?.title, "Weekday Morning")
        XCTAssertEqual(store.listTemplates.first?.items.first?.details.fields["Required"], "Yes")
        repository.deleteListTemplate(template.id)
        XCTAssertTrue(store.listTemplates.isEmpty)
    }

    func testRememberedShoppingStoresDeduplicateAndPersist() {
        let (repository, store, defaults) = fixture()
        repository.rememberShoppingStore(" Target ", for: "list")
        repository.rememberShoppingStore("target", for: "list")
        repository.rememberShoppingStore("", for: "list")
        XCTAssertEqual(repository.shoppingStores(for: "list"), ["Target"])
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(restored.shoppingStores(for: "list"), ["Target"])
    }

    func testFollowUpDatesPreserveLocalCalendarDay() throws {
        let now = Date()
        let restored = try XCTUnwrap(SpecializedTaskDetails.dateValue(SpecializedTaskDetails.dateText(now)))
        XCTAssertTrue(Calendar.current.isDate(now, inSameDayAs: restored))
        XCTAssertNil(SpecializedTaskDetails.dateValue("not a date"))
    }

    func testSpecializedListTypeSwitchPreservesFieldsAndTemplates() {
        let (repository, store, defaults) = fixture()
        let reminder = task("shopping")
        repository.tasks = [reminder]
        repository.setListProfile(SpecializedListProfile(type: .shopping), for: "list")
        let details = SpecializedTaskDetails(fields: ["Quantity": "2", "Unit": "kg", "Store": "Market"], isFavorite: true)
        repository.setSpecializedDetails(details, for: reminder)
        repository.saveListTemplate(listID: "list", title: "Weekly groceries")
        repository.setListProfile(SpecializedListProfile(type: .standard), for: "list")
        let reopened = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(reopened.listProfile("list").type, .standard)
        XCTAssertEqual(reopened.specializedDetails(reminder), details)
        XCTAssertEqual(reopened.listTemplates.first?.items.first?.details, details)
    }

    func testAllSpecializedProfilesRoundTripAndLegacySnapshotLoads() throws {
        let (_, store, _) = fixture()
        for type in SpecializedListType.allCases {
            store.listProfiles[type.id] = SpecializedListProfile(type: type, settings: ["Trip": "Weekend"])
        }
        let encoded = try JSONEncoder().encode(store.currentSnapshot())
        let decoded = try JSONDecoder().decode(MetadataSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.listProfiles.count, SpecializedListType.allCases.count)
        XCTAssertEqual(decoded.listProfiles[SpecializedListType.packing.id]?.settings["Trip"], "Weekend")
        let legacy = try JSONDecoder().decode(MetadataSnapshot.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.listProfiles.isEmpty)
        XCTAssertTrue(legacy.specializedTasks.isEmpty)
        XCTAssertTrue(legacy.listTemplates.isEmpty)
    }

    func testSpecializedDataSurvivesMetadataStoreRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataStore(directory: directory)
        store.listProfiles = ["chores": SpecializedListProfile(type: .household)]
        store.specializedTasks = ["task": SpecializedTaskDetails(fields: ["Room": "Kitchen"], repeatAfterDays: 7)]
        let reopened = MetadataStore(directory: directory)
        XCTAssertEqual(reopened.listProfiles["chores"]?.type, .household)
        XCTAssertEqual(reopened.specializedTasks["task"]?.repeatAfterDays, 7)
        XCTAssertEqual(reopened.specializedTasks["task"]?.fields["Room"], "Kitchen")
    }

    func testPinningListsAndTileOrderPersistAcrossLaunches() {
        let (repository, store, defaults) = fixture()
        let work = TaskList(id: "work", title: "Work", color: .blue)
        repository.lists = [work]
        repository.togglePinnedList(work)
        XCTAssertTrue(repository.pinnedItemIDs.contains(work.id))
        repository.movePinnedItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let reopened = TaskRepository(preferences: defaults, metadataStore: store)
        reopened.lists = [work]
        XCTAssertEqual(reopened.pinnedItemIDs.first, work.id)
        XCTAssertTrue(reopened.pinnedListIDs.contains(work.id))
        reopened.togglePinnedList(work)
        XCTAssertFalse(reopened.pinnedItemIDs.contains(work.id))
        XCTAssertFalse(TaskRepository(preferences: defaults, metadataStore: store).pinnedListIDs.contains(work.id))
    }

    func testSystemThemeIsDefaultWithoutReplacingSavedTheme() {
        let (repository, store, defaults) = fixture()
        XCTAssertEqual(repository.appTheme, .system)
        XCTAssertEqual(TaskRepository.AppTheme.selectableCases.first, .system)
        defaults.set("Grape", forKey: "TaskFlow.appTheme")
        XCTAssertEqual(TaskRepository(preferences: defaults, metadataStore: store).appTheme, .grape)
    }

    func testThemePalettesMapToWidgetsAndRestorePreferences() {
        let (_, store, defaults) = fixture()
        for theme in TaskRepository.AppTheme.selectableCases {
            XCTAssertEqual(theme.sharedTheme.rawValue, theme.rawValue)
            defaults.set(theme.rawValue, forKey: "TaskFlow.appTheme")
            let reopened = TaskRepository(preferences: defaults, metadataStore: store)
            XCTAssertEqual(reopened.appTheme, theme)
        }
        defaults.set("Ocean", forKey: "TaskFlow.appTheme")
        XCTAssertEqual(TaskRepository(preferences: defaults, metadataStore: store).appTheme, .oceanTeal)
    }

    func testAlarmMinuteConversionRejectsInvalidAndOutOfRangeValues() {
        XCTAssertNil(EventKitReminderService.alarmMinutes(.infinity))
        XCTAssertNil(EventKitReminderService.alarmMinutes(.nan))
        XCTAssertNil(EventKitReminderService.alarmMinutes(.greatestFiniteMagnitude))
        XCTAssertEqual(EventKitReminderService.alarmMinutes(1800), 30)
        XCTAssertEqual(EventKitReminderService.alarmMinutes(-1800), -30)
    }

    func testStaleNoteEditorPreservesNewerPinState() async {
        let (repository, _, _) = fixture()
        await repository.addQuickNote(title: "Before", text: "Body", tags: [], linkedTaskID: nil)
        let stale = repository.quickNotes[0]
        repository.toggleNotePin(stale)
        await repository.updateQuickNote(stale, title: "After", text: "Edited", tags: [], linkedTaskID: nil, linkedEventID: nil, format: .plain, layout: .standard, drawingData: nil, attachments: [])
        XCTAssertTrue(repository.quickNotes[0].isPinned)
        XCTAssertEqual(repository.quickNotes[0].title, "After")
    }

    func testNotificationScheduleIgnoresNonfiniteDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var reminder = task("invalid")
        reminder.dueDate = Date(timeIntervalSince1970: .infinity)
        reminder.additionalAlerts = [.absolute(Date(timeIntervalSince1970: .infinity)), .absolute(now.addingTimeInterval(600))]
        XCTAssertEqual(NotificationScheduler.requests(for: [reminder], now: now).count, 1)
    }

    func testNotePinUndoRedoPreservesOtherNotes() async {
        let (repository, store, _) = fixture()
        await repository.addQuickNote(title: "First", text: "Body", tags: [], linkedTaskID: nil)
        await repository.addQuickNote(title: "Second", text: "Other", tags: [], linkedTaskID: nil)
        let note = repository.quickNotes.first { $0.title == "First" }!
        repository.toggleNotePin(note)
        XCTAssertTrue(repository.quickNotes.first { $0.id == note.id }!.isPinned)
        repository.restoreNote(repository.noteUndo!)
        XCTAssertFalse(repository.quickNotes.first { $0.id == note.id }!.isPinned)
        repository.restoreNote(repository.noteRedo!, isRedo: true)
        XCTAssertTrue(repository.quickNotes.first { $0.id == note.id }!.isPinned)
        XCTAssertEqual(repository.quickNotes.count, 2)
        XCTAssertEqual(store.quickNotes.count, 2)
    }

    func testNoteDeleteUndoAndLegacyPinDecoding() async throws {
        let legacy = Data("{\"text\":\"Legacy\"}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(QuickNote.self, from: legacy).isPinned)
        let (repository, _, _) = fixture()
        await repository.addQuickNote(title: "Keep", text: "Text", tags: [], linkedTaskID: nil)
        let note = repository.quickNotes[0]
        await repository.deleteQuickNote(note)
        XCTAssertTrue(repository.quickNotes.isEmpty)
        repository.restoreNote(repository.noteUndo!)
        XCTAssertEqual(repository.quickNotes.first?.id, note.id)
        repository.restoreNote(repository.noteRedo!, isRedo: true)
        XCTAssertTrue(repository.quickNotes.isEmpty)
    }

    func testListIconPersistsAndRejectsUnsupportedSymbols() {
        let (repository, store, defaults) = fixture()
        repository.setListIcon("briefcase", for: "work")
        XCTAssertEqual(repository.listIcon(for: "work"), "briefcase")
        repository.setListIcon("invalid.symbol", for: "work")
        XCTAssertEqual(repository.listIcon(for: "work"), "briefcase")
        let reopened = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(reopened.listIcon(for: "work"), "briefcase")
        XCTAssertEqual(reopened.listIcon(for: "other"), "list.bullet")
    }

    func testNotificationScheduleUsesAdvanceAlertsAndNearestLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var later = task("later")
        later.dueDate = now.addingTimeInterval(7200)
        later.hasDueTime = true
        later.alarmOffsetMinutes = 30
        later.additionalAlerts = [.relative(minutesBefore: 30)]
        var earlier = task("earlier")
        earlier.dueDate = now.addingTimeInterval(3600)
        earlier.hasDueTime = true
        let requests = NotificationScheduler.requests(for: [later, earlier], now: now)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.first?.content.userInfo[TaskFlowNotificationPayload.taskIDKey] as? String, "earlier")
        XCTAssertEqual(NotificationScheduler.requests(for: [later, earlier], now: now, limit: 1).count, 1)
    }

    func testNotificationScheduleExcludesCompletedAndPastButSupportsUndatedAlerts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var undated = task("undated")
        undated.additionalAlerts = [.absolute(now.addingTimeInterval(600)), .absolute(now.addingTimeInterval(-60))]
        var completed = task("completed", completed: true)
        completed.dueDate = now.addingTimeInterval(600)
        let requests = NotificationScheduler.requests(for: [undated, completed], now: now)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.userInfo[TaskFlowNotificationPayload.taskIDKey] as? String, "undated")
    }

    func testGlobalTagRenameMergesDuplicatesAndUpdatesUnloadedMetadata() {
        let (_, store, _) = fixture()
        store.setMetadata(TaskMetadata(tags: ["Work", "Office"], comments: [TaskComment(text: "Keep me")]), for: "unloaded")
        store.quickNotes = [QuickNote(text: "Note", tags: ["work", "Office"])]
        store.eventTags = ["event": ["Work", "Office"]]
        store.savedTags = [SavedTag(name: "Work", color: .red), SavedTag(name: "Office", color: .blue)]
        store.smartLists = [SmartListDefinition(title: "Work", requiredTag: "Work", rules: [SmartTaskFilterRule(field: .tag, value: "Work")])]
        store.replaceTag("work", with: "Office")
        XCTAssertEqual(store.metadata(for: "unloaded").tags, ["Office"])
        XCTAssertEqual(store.metadata(for: "unloaded").comments.count, 1)
        XCTAssertEqual(store.quickNotes.first?.tags, ["Office"])
        XCTAssertEqual(store.eventTags["event"], ["Office"])
        XCTAssertEqual(store.savedTags, [SavedTag(name: "Office", color: .blue)])
        XCTAssertEqual(store.smartLists.first?.requiredTag, "Office")
        XCTAssertEqual(store.smartLists.first?.rules.first?.value, "Office")
        store.replaceTag("Office", with: nil)
        XCTAssertTrue(store.metadata(for: "unloaded").tags.isEmpty)
        XCTAssertTrue(store.smartLists.first?.rules.isEmpty == true)
        XCTAssertNil(store.smartLists.first?.requiredTag)
    }

    func testPinnedListsTolerateDuplicateIdentifiers() {
        let (repository, _, _) = fixture()
        repository.lists = [TaskList(id: "list", title: "One", color: .blue), TaskList(id: "list", title: "Duplicate", color: .red)]
        repository.pinnedListIDs = ["list"]
        repository.pinnedItemOrder = ["list"]
        XCTAssertEqual(repository.pinnedLists.map(\.title), ["One"])
    }

    func testAttachmentPathsCannotEscapeStorageDirectory() {
        let (_, store, _) = fixture()
        let attachment = TaskAttachment(kind: .file, title: "Invalid", localPath: "../Metadata.json")
        XCTAssertNil(store.attachmentURL(for: attachment))
    }

    func testSmartListRulesSupportAndOrAndRelativeDates() {
        var dueToday = task("today")
        dueToday.dueDate = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date())
        dueToday.priority = .high

        let andList = SmartListDefinition(
            title: "Today high priority",
            matchMode: .all,
            rules: [
                SmartTaskFilterRule(field: .due, value: "Today"),
                SmartTaskFilterRule(field: .priority, value: "High")
            ]
        )
        XCTAssertTrue(andList.matches(dueToday))

        var noDate = task("no-date")
        let orList = SmartListDefinition(
            title: "High or undated",
            matchMode: .any,
            rules: [
                SmartTaskFilterRule(field: .priority, value: "High"),
                SmartTaskFilterRule(field: .due, value: "No date")
            ]
        )
        XCTAssertTrue(orList.matches(noDate))
        noDate.priority = .low
        XCTAssertTrue(orList.matches(noDate))
        XCTAssertFalse(andList.matches(noDate))
    }

    func testCalendarPlanningRespectsBusyEventsBuffersAndTaskDuration() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        func at(_ hour: Int, _ minute: Int = 0) -> Date { day.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        let busy = CalendarEvent(id: "busy", calendarID: "work", title: "Meeting", startDate: at(10), endDate: at(11), isAllDay: false)
        var scheduledTask = task("timed")
        scheduledTask.hasDueTime = true
        scheduledTask.dueDate = at(13)
        scheduledTask.durationMinutes = 60
        let slots = CalendarPlanningEngine.slots(from: day, through: day, duration: 30, settings: CalendarWorkspaceSettings(), events: [busy], tasks: [scheduledTask], now: day, calendar: calendar)
        XCTAssertTrue(slots.contains { $0.start == at(9) })
        XCTAssertFalse(slots.contains { $0.start == at(9, 30) })
        XCTAssertFalse(slots.contains { $0.start == at(11) })
        XCTAssertTrue(slots.contains { $0.start == at(11, 15) })
        XCTAssertFalse(slots.contains { $0.start == at(13, 30) })
        XCTAssertTrue(slots.allSatisfy { $0.start >= at(9) && $0.end <= at(17) })
        XCTAssertTrue(slots.first?.preferred == true)
    }

    func testCalendarPlanningFreeEventsAndAllDayBusyEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        var event = CalendarEvent(id: "day", calendarID: "work", title: "Away", startDate: day, endDate: day.addingTimeInterval(86400), isAllDay: true)
        XCTAssertTrue(CalendarPlanningEngine.slots(from: day, through: day, duration: 30, settings: CalendarWorkspaceSettings(), events: [event], tasks: [], now: day, calendar: calendar).isEmpty)
        event.availability = "Free"
        XCTAssertFalse(CalendarPlanningEngine.slots(from: day, through: day, duration: 30, settings: CalendarWorkspaceSettings(), events: [event], tasks: [], now: day, calendar: calendar).isEmpty)
        let saturday = day.addingTimeInterval(3 * 86400)
        XCTAssertTrue(CalendarPlanningEngine.slots(from: saturday, through: saturday, duration: 30, settings: CalendarWorkspaceSettings(), events: [], tasks: [], now: day, calendar: calendar).isEmpty)
    }

    func testCalendarConflictReviewFindsOverlapGapAndOutsideWorkTask() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        func at(_ minutes: Int) -> Date { day.addingTimeInterval(Double(minutes * 60)) }
        let events = [
            CalendarEvent(id: "1", calendarID: "c", title: "One", startDate: at(540), endDate: at(600), isAllDay: false),
            CalendarEvent(id: "2", calendarID: "c", title: "Two", startDate: at(590), endDate: at(660), isAllDay: false),
            CalendarEvent(id: "3", calendarID: "c", title: "Three", startDate: at(665), endDate: at(700), isAllDay: false)
        ]
        var late = task("Late")
        late.hasDueTime = true
        late.dueDate = at(1020)
        let messages = CalendarPlanningEngine.conflicts(events: events, tasks: [late], settings: CalendarWorkspaceSettings(), calendar: calendar)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.contains { $0.contains("overlaps") })
        XCTAssertTrue(messages.contains { $0.contains("5 minutes") })
        XCTAssertTrue(messages.contains { $0.contains("outside working hours") })
    }

    func testEventsOnDifferentCalendarsDoNotConflict() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        func at(_ minutes: Int) -> Date { day.addingTimeInterval(Double(minutes * 60)) }
        let events = [
            CalendarEvent(id: "1", calendarID: "calA", title: "Work Meeting", startDate: at(540), endDate: at(600), isAllDay: false),
            CalendarEvent(id: "2", calendarID: "calB", title: "Personal Task", startDate: at(590), endDate: at(660), isAllDay: false)
        ]
        let messages = CalendarPlanningEngine.conflicts(events: events, tasks: [], settings: CalendarWorkspaceSettings(), calendar: calendar)
        XCTAssertTrue(messages.isEmpty)
    }

    func testSpecializedFieldFormatReadsDatesAndAmounts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        XCTAssertEqual(SpecializedFieldFormat.date("2026-10-05", now: now, calendar: calendar), "Today")
        XCTAssertEqual(SpecializedFieldFormat.date("2026-10-06", now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(SpecializedFieldFormat.date("2026-10-04", now: now, calendar: calendar), "Yesterday")
        XCTAssertTrue(SpecializedFieldFormat.date("2026-10-08", now: now, calendar: calendar)?.hasSuffix("in 3 days") == true)
        XCTAssertTrue(SpecializedFieldFormat.date("2026-09-25", now: now, calendar: calendar)?.hasSuffix("10 days ago") == true)
        XCTAssertNil(SpecializedFieldFormat.date("not a date", now: now, calendar: calendar))
        XCTAssertNil(SpecializedFieldFormat.date(nil, now: now, calendar: calendar))
        XCTAssertEqual(SpecializedFieldFormat.amount(12.5, currency: "usd"), 12.5.formatted(.currency(code: "USD")))
        XCTAssertEqual(SpecializedFieldFormat.amount(12.5, currency: "points"), "12.50 POINTS")
        XCTAssertEqual(SpecializedFieldFormat.amount(3, currency: nil), "3.00")
    }

    func testReadingLinkMetadataParsesOpenGraphAndReadingTime() {
        let words = Array(repeating: "word", count: 460).joined(separator: " ")
        let html = """
        <html><head><title>Fallback &amp; Title</title>
        <meta property="og:title" content="Don't Panic: A Guide">
        <meta content='Jane Doe' name='author'>
        <meta property="og:image" content="/img/cover.jpg">
        <meta property="og:type" content="article"></head>
        <body><script>var ignored = "\(words)";</script><p>\(words)</p></body></html>
        """
        let metadata = ReadingLinkMetadata.parse(html: html, baseURL: URL(string: "https://example.com/post")!)
        XCTAssertEqual(metadata.title, "Don't Panic: A Guide")
        XCTAssertEqual(metadata.creator, "Jane Doe")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://example.com/img/cover.jpg")
        XCTAssertEqual(metadata.format, "Article")
        XCTAssertEqual(metadata.estimatedMinutes, 2)

        let plain = ReadingLinkMetadata.parse(html: "<title> A &amp; B </title>", baseURL: URL(string: "https://youtube.com/watch?v=1")!)
        XCTAssertEqual(plain.title, "A & B")
        XCTAssertEqual(plain.format, "Video")
        XCTAssertNil(plain.estimatedMinutes)
        XCTAssertNil(plain.thumbnailURL)
    }

    func testMediaQueueRetainsOtherCapturesWhenImportIsAcknowledged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = ReadingMedia.CaptureQueue(directory: folder)
        let first = ReadingMedia.Capture(url: "https://example.com/news", title: "News", note: "Read this", listID: "reading", watch: false)
        let second = ReadingMedia.Capture(url: "https://youtu.be/123?t=42", title: "Video", note: "", listID: "watch", watch: true)
        try queue.enqueue(first)
        let importSnapshot = queue.captures()
        XCTAssertEqual(importSnapshot.count, 1)
        try queue.enqueue(second)
        try queue.acknowledge(first.id)
        let reopened = ReadingMedia.CaptureQueue(directory: folder).captures()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.id, second.id)
        XCTAssertEqual(reopened.first?.url, second.url)
        XCTAssertEqual(reopened.first?.listID, "watch")
        XCTAssertEqual(reopened.first?.watch, true)
    }

    func testStreamingMetadataUsesStructuredMovieAndEpisodeFields() {
        let movie = ReadingLinkMetadata.parse(html: """
        <title>Watch Arrival | Netflix</title>
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"Movie","name":"Arrival","datePublished":"2016-11-11","genre":["Science Fiction","Drama"],"duration":"PT1H56M","image":{"url":"https://images.example.com/poster.jpg"}}</script>
        """, baseURL: URL(string: "https://www.netflix.com/title/80117799")!)
        XCTAssertEqual(movie.title, "Arrival")
        XCTAssertEqual(movie.format, "Movie")
        XCTAssertEqual(movie.fields["Saved From"], "Netflix")
        XCTAssertEqual(movie.fields["Year"], "2016")
        XCTAssertEqual(movie.fields["Runtime Minutes"], "116")
        XCTAssertEqual(movie.fields["Genres"], "Science Fiction, Drama")
        XCTAssertNil(movie.estimatedMinutes)
        XCTAssertEqual(movie.thumbnailURL?.absoluteString, "https://images.example.com/poster.jpg")
        let episode = ReadingLinkMetadata.parse(html: """
        <script type='application/ld+json'>{"@graph":[{"@type":"WebPage","mainEntity":{"@type":"TVEpisode","name":"The first mission","episodeNumber":3,"partOfSeason":{"@type":"TVSeason","seasonNumber":2},"partOfSeries":{"@type":"TVSeries","name":"Slow Horses"}}}]}</script>
        """, baseURL: URL(string: "https://tv.apple.com/us/episode/123")!)
        XCTAssertEqual(episode.format, "Episode")
        XCTAssertEqual(episode.fields["Season"], "2")
        XCTAssertEqual(episode.fields["Episode"], "3")
        XCTAssertEqual(episode.fields["Series Title"], "Slow Horses")
    }

    func testOlderMediaCaptureDecodesWithoutPreviewAndLocalPathsAreRestricted() throws {
        let id = UUID()
        let json = "{\"id\":\"\(id.uuidString)\",\"url\":\"https://netflix.com/title/123\",\"title\":\"Title\",\"note\":\"\",\"listID\":\"list\",\"watch\":true}"
        let capture = try JSONDecoder().decode(ReadingMedia.Capture.self, from: Data(json.utf8))
        XCTAssertEqual(capture.id, id)
        XCTAssertNil(capture.previewFilename)
        XCTAssertNil(ReadingMedia.capturePreviewData("../../private.jpg"))
        XCTAssertNil(ReadingMedia.capturePreviewData("/tmp/image.jpg"))
    }

    func testMediaProviderDetectionAndTitleCleanupAvoidFalsePositives() {
        XCTAssertEqual(ReadingMedia.provider(for: URL(string: "https://play.hbomax.com/series/123")!), "HBO Max")
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://www.primevideo.com/detail/123")!), "Video")
        XCTAssertNil(ReadingMedia.provider(for: URL(string: "https://amazon.com/dp/product")!))
        XCTAssertNil(ReadingMedia.provider(for: URL(string: "https://a.co/d/123")!))
        XCTAssertNil(ReadingMedia.provider(for: URL(string: "https://notnetflix.com/title/123")!))
        XCTAssertEqual(ReadingMedia.cleanTitle("Watch Arrival | Netflix", url: URL(string: "https://netflix.com/title/123")!), "Arrival")
        XCTAssertEqual(ReadingMedia.cleanTitle("Watch Dogs", url: URL(string: "https://netflix.com/title/123")!), "Watch Dogs")
        XCTAssertEqual(ReadingMedia.cleanTitle("Watch out for storms", url: URL(string: "https://news.example.com/article")!), "Watch out for storms")
    }

    func testWatchLinksPreserveMultipleProvidersAndCaptureIdentities() {
        let links: [ReadingMedia.WatchLink] = [.init(provider: "Netflix", url: "https://netflix.com/watch/123?utm_source=share"), .init(provider: "Prime Video", url: "https://primevideo.com/detail/456", region: "US", note: "Rental")]
        let fields = ["Format": "Movie", "Source Link": "https://netflix.com/title/123", "Watch Links": ReadingMedia.encodeLinks(links), "Genres": "Drama, Mystery", "Share Capture ID": "first", "Share Capture IDs": "first,second"]
        let decoded = ReadingMedia.watchLinks(fields)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.last?.region, "US")
        XCTAssertEqual(decoded.last?.note, "Rental")
        XCTAssertEqual(Set(ReadingMedia.captureIDs(fields)), ["first", "second"])
        XCTAssertEqual(Set(ReadingMedia.suggestedTags(fields)), ["movie", "netflix", "prime-video", "drama", "mystery"])
        XCTAssertFalse(ReadingMedia.suggestedTags(fields, includeGenres: false).contains("drama"))
        XCTAssertEqual(ReadingMedia.tagNames("#My Movie, Favorite, favorite"), ["My Movie", "Favorite"])
        XCTAssertNotEqual(ReadingMedia.canonicalURL("https://example.com/data?source=one"), ReadingMedia.canonicalURL("https://example.com/data?source=two"))
        XCTAssertNotEqual(ReadingMedia.canonicalURL("https://play.hbomax.com/#/movie/one"), ReadingMedia.canonicalURL("https://play.hbomax.com/#/movie/two"))
        XCTAssertFalse(ReadingMedia.identifiesItem(URL(string: "https://netflix.com/?utm_source=share")!))
        XCTAssertTrue(ReadingMedia.identifiesItem(URL(string: "https://netflix.com/title/123")!))
    }

    func testPossibleMediaDuplicatesKeepDifferentReleasesAndEpisodesSeparate() {
        XCTAssertTrue(ReadingMedia.sameTitle("Arrival", fields: ["Format": "Movie", "Year": "2016"], "arrival", fields: ["Format": "Movie", "Year": "2016"]))
        XCTAssertFalse(ReadingMedia.sameTitle("Arrival", fields: ["Format": "Movie", "Year": "2016"], "Arrival", fields: ["Format": "Movie", "Year": "1996"]))
        XCTAssertFalse(ReadingMedia.sameTitle("Pilot", fields: ["Format": "Episode", "Episode": "1"], "Pilot", fields: ["Format": "Episode", "Episode": "2"]))
        XCTAssertFalse(ReadingMedia.sameTitle("Title", fields: ["Format": "Movie"], "Title", fields: ["Format": "TV Show"]))
        XCTAssertFalse(ReadingMedia.sameTitle("Pilot", fields: ["Format": "Episode", "Series Title": "One Show"], "Pilot", fields: ["Format": "Episode", "Series Title": "Another Show"]))
        XCTAssertFalse(ReadingMedia.isPending(["Format": "Movie", "Merged Into": "kept"], watch: true))
    }

    func testMediaTaskDeepLinkOpensItsListAndFollowsMergedEntries() {
        let (repository, _, _) = fixture()
        let source = task("source"), target = task("target")
        repository.tasks = [source, target]
        repository.setSpecializedDetails(.init(fields: ["Merged Into": "target"]), for: source)
        repository.openTask(id: source.id)
        XCTAssertEqual(repository.selectedTaskID, target.id)
        XCTAssertEqual(repository.selectedScope, .list("list"))
        XCTAssertEqual(TaskFlowDeepLink.taskURL(target.id).absoluteString, "taskflow://task/target")
        let kept = task("kept")
        repository.tasks.append(kept)
        repository.setSpecializedDetails(.init(fields: ["Merged Into": "kept"]), for: target)
        repository.openTask(id: source.id)
        XCTAssertEqual(repository.selectedTaskID, kept.id)
    }

    func testEpisodeFeedsFilterWatchedDroppedUnknownAndDeduplicateShows() throws {
        let show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: Data(#"{"id":1,"name":"Show","url":"https://www.tvmaze.com/shows/1/show","premiered":null,"image":null}"#.utf8))
        let now = Date(), formatter = ISO8601DateFormatter()
        func episode(_ id: Int, days: Double?) -> ReadingMedia.ShowEpisode {
            .init(id: id, name: "Spoiler", season: 1, number: id, airdate: nil, airstamp: days.map { formatter.string(from: now.addingTimeInterval($0 * 86400)) }, runtime: 45, summary: nil)
        }
        var catalog = ReadingMedia.ShowTracking(show: show, episodes: [episode(1, days: -30), episode(2, days: -2), episode(3, days: 1), episode(4, days: 2), episode(5, days: nil)], cast: [], watched: [1])
        let fields = ["Show Tracking": ReadingMedia.encodeTracking(catalog), "Progress": "In Progress"]
        let sources = [ReadingMedia.EpisodeFeedSource(taskID: "a", title: "Saved Show", fields: fields), .init(taskID: "b", title: "Duplicate Show", fields: fields)]
        XCTAssertEqual(ReadingMedia.episodeFeed(sources, mode: .continuing, now: now).map { $0.episode.id }, [2])
        XCTAssertEqual(ReadingMedia.episodeFeed(sources, mode: .newEpisodes, now: now).map { $0.episode.id }, [2])
        XCTAssertEqual(ReadingMedia.episodeFeed(sources, mode: .comingSoon, now: now).map { $0.episode.id }, [3, 4])
        XCTAssertEqual(ReadingMedia.episodeFeed(sources, mode: .comingSoon, now: now, onePerShow: true).map { $0.episode.id }, [3])
        XCTAssertEqual(ReadingMedia.episodeFeed(sources, mode: .comingSoon, now: now).first?.taskID, "a")
        catalog.watched.insert(2)
        let watchedSource = ReadingMedia.EpisodeFeedSource(taskID: "a", title: "Show", fields: ["Show Tracking": ReadingMedia.encodeTracking(catalog)])
        XCTAssertTrue(ReadingMedia.episodeFeed([watchedSource], mode: .newEpisodes, now: now).isEmpty)
        for excluded in ["Dropped", "Finished"] {
            let source = ReadingMedia.EpisodeFeedSource(taskID: "a", title: "Show", fields: ["Show Tracking": ReadingMedia.encodeTracking(catalog), "Progress": excluded])
            XCTAssertTrue(ReadingMedia.episodeFeed([source], mode: .comingSoon, now: now).isEmpty)
        }
        XCTAssertFalse(ReadingMedia.isPending(["Format": "TV Show", "Progress": "Dropped"], watch: true))
        XCTAssertEqual(TaskFlowDeepLink.taskURL("a").host, "task")
        XCTAssertTrue(ReadingMedia.hasEpisodeCalendarLink(notes: "Release\nTaskFlow episode: 2\nLink", episodeID: 2))
        XCTAssertFalse(ReadingMedia.hasEpisodeCalendarLink(notes: "TaskFlow episode: 20", episodeID: 2))
        let batchDate = formatter.string(from: now.addingTimeInterval(86400))
        let batch = [ReadingMedia.ShowEpisode(id: 9, name: "First", season: 1, number: 1, airdate: nil, airstamp: batchDate, runtime: nil, summary: nil),
                     ReadingMedia.ShowEpisode(id: 10, name: "Second", season: 1, number: 2, airdate: nil, airstamp: batchDate, runtime: nil, summary: nil)]
        let batchSource = ReadingMedia.EpisodeFeedSource(taskID: "a", title: "Show", fields: ["Show Tracking": ReadingMedia.encodeTracking(.init(show: show, episodes: batch, cast: []))])
        XCTAssertEqual(ReadingMedia.episodeFeed([batchSource], mode: .comingSoon, now: now, onePerShow: true).first?.episode.id, 9)
    }

    func testWatchRemainingTimeAndReleaseBadge() throws {
        let now = Date()
        let show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: Data(#"{"id":1,"name":"Show","url":"https://www.tvmaze.com/shows/1/show","status":"Running","image":null}"#.utf8))
        func episode(_ id: Int, days: Double, runtime: Int?) -> ReadingMedia.ShowEpisode {
            .init(id: id, name: "Episode", season: 1, number: id, airdate: nil, airstamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(days * 86400)), runtime: runtime, summary: nil)
        }
        var catalog = ReadingMedia.ShowTracking(show: show, episodes: [episode(1, days: -20, runtime: 45), episode(2, days: -1, runtime: 40), episode(3, days: 1, runtime: 50)], cast: [])
        func fields() -> [String: String] { ["Show Tracking": ReadingMedia.encodeTracking(catalog)] }
        XCTAssertFalse(ReadingMedia.hasNewEpisode(fields(), now: now))
        catalog.watched = [1]
        XCTAssertTrue(ReadingMedia.hasNewEpisode(fields(), now: now))
        XCTAssertEqual(ReadingMedia.remainingWatchTime(fields(), now: now), "1 episode · about 40 min left in season")
        catalog.episodes[1] = episode(2, days: -1, runtime: nil)
        XCTAssertNil(ReadingMedia.remainingWatchTime(fields(), now: now))
        catalog.watched.insert(2)
        XCTAssertFalse(ReadingMedia.hasNewEpisode(fields(), now: now))
        XCTAssertNil(ReadingMedia.remainingWatchTime(fields(), now: now))
    }

    func testWatchGroupsFollowEpisodeProgress() throws {
        let now = Date()
        var show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: Data(#"{"id":1,"name":"Show","url":"https://www.tvmaze.com/shows/1/show","status":"Running","image":null}"#.utf8))
        func episode(_ id: Int, season: Int, future: Bool = false) -> ReadingMedia.ShowEpisode {
            .init(id: id, name: "Episode", season: season, number: id, airdate: nil, airstamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(future ? 86400 : -86400)), runtime: nil, summary: nil)
        }
        var catalog = ReadingMedia.ShowTracking(show: show, episodes: [episode(1, season: 1), episode(2, season: 1), episode(3, season: 2), episode(4, season: 2, future: true)], cast: [])
        func group(_ completed: Bool = false, status: String? = nil) -> String {
            var fields = ["Show Tracking": ReadingMedia.encodeTracking(catalog)]
            fields["Progress"] = status
            return ReadingMedia.watchGroup(fields, completed: completed, now: now)
        }
        XCTAssertEqual(group(), "Not Started")
        catalog.watched = [999]
        XCTAssertEqual(group(), "Not Started")
        catalog.watched = [1]
        XCTAssertEqual(group(), "Continue Watching")
        catalog.watched = [1, 2]
        XCTAssertEqual(group(), "Ready for Next Season")
        catalog.watched = [1, 2, 3]
        XCTAssertEqual(group(), "Up to Date")
        XCTAssertEqual(group(status: "Dropped"), "Dropped")
        XCTAssertEqual(group(true), "Finished Series")
        XCTAssertEqual(group(status: "Finished"), "Finished Series")
        catalog.watched = [2, 3]
        XCTAssertEqual(group(), "Continue Watching") // An earlier gap must not be hidden.
        show.status = "Ended"; catalog.show = show; catalog.watched = [1, 2, 3]
        XCTAssertEqual(group(), "Up to Date") // A future known episode remains.
        catalog.watched.insert(4)
        XCTAssertEqual(group(), "Finished Series")
        XCTAssertEqual(ReadingMedia.watchGroup([:], completed: false), "Saved for Later")
        XCTAssertEqual(ReadingMedia.watchGroup([:], completed: true), "Finished")
    }

    func testShowEpisodeTrackingAdvancesAndDistinguishesCaughtUp() throws {
        let showData = Data(#"{"id":1,"name":"Example","url":"https://www.tvmaze.com/shows/1/example","premiered":"2020-01-01","genres":["Drama"],"status":"Running","image":null}"#.utf8)
        let show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: showData)
        let now = Date()
        let stamp = ISO8601DateFormatter()
        func episode(_ id: Int, season: Int = 1, days: Double) -> ReadingMedia.ShowEpisode {
            ReadingMedia.ShowEpisode(id: id, name: "Spoiler title", season: season, number: id, airdate: "2020-01-01", airstamp: stamp.string(from: now.addingTimeInterval(days * 86400)), runtime: 45, summary: "<p>Summary</p>")
        }
        var catalog = ReadingMedia.ShowTracking(show: show, episodes: [episode(1, days: -2), episode(2, days: -1), episode(3, season: 2, days: 3)], cast: ["Actor"])
        XCTAssertEqual(catalog.next(now: now)?.id, 1)
        catalog.watched.insert(1)
        XCTAssertEqual(catalog.next(now: now)?.id, 2)
        XCTAssertEqual(catalog.progress(now: now), "In Progress")
        catalog.watched.insert(2)
        XCTAssertEqual(catalog.progress(now: now), "Caught Up")
        XCTAssertEqual(catalog.upcoming(now: now)?.id, 3)
        XCTAssertEqual(catalog.next(now: now.addingTimeInterval(4 * 86400))?.id, 3)
        let encoded = ReadingMedia.encodeTracking(catalog)
        let restored = try XCTUnwrap(ReadingMedia.tracking(["Show Tracking": encoded]))
        XCTAssertEqual(restored.watched, [1, 2])
        XCTAssertEqual(restored.cast, ["Actor"])
        catalog.show.status = "Ended"; catalog.watched.insert(3)
        XCTAssertEqual(catalog.progress(now: now.addingTimeInterval(4 * 86400)), "Finished")
        XCTAssertEqual(ReadingMedia.plainSummary("<p>A &amp; B</p>"), "A & B")
    }

    func testMarkWatchedEpisodesPreservesNotesAndRejectsFutureEpisodes() async throws {
        let (repository, _, _) = fixture()
        let item = task("Show")
        repository.tasks = [item]
        let show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: Data(#"{"id":10,"name":"Show","url":"https://www.tvmaze.com/shows/10/show","premiered":null,"image":null}"#.utf8))
        let formatter = ISO8601DateFormatter()
        let released = ReadingMedia.ShowEpisode(id: 1, name: "Released", season: 1, number: 1, airdate: nil, airstamp: formatter.string(from: Date().addingTimeInterval(-86400)), runtime: nil, summary: nil)
        let future = ReadingMedia.ShowEpisode(id: 2, name: "Future", season: 1, number: 2, airdate: nil, airstamp: formatter.string(from: Date().addingTimeInterval(86400)), runtime: nil, summary: nil)
        let original = ReadingMedia.ShowTracking(show: show, episodes: [released, future], cast: [])
        repository.setSpecializedDetails(.init(fields: ["Show Tracking": ReadingMedia.encodeTracking(original), "Why Saved": "A recommendation", "Source Link": "https://www.netflix.com/title/123"]), for: item)
        await repository.setWatchedEpisodes([1, 2], watched: true, taskID: item.id)
        let details = repository.specializedDetails(item)
        XCTAssertEqual(ReadingMedia.tracking(details.fields)?.watched, [1])
        XCTAssertEqual(details.fields["Progress"], "Caught Up")
        XCTAssertEqual(details.fields["Why Saved"], "A recommendation")
        XCTAssertEqual(details.fields["Source Link"], "https://www.netflix.com/title/123")
        XCTAssertEqual(ReadingMedia.tracking(repository.taskUndo?.specializedPrevious[item.id]?.fields ?? [:])?.watched, [])
        await repository.setWatchedEpisodes([1], watched: false, taskID: item.id)
        XCTAssertEqual(ReadingMedia.tracking(repository.specializedDetails(item).fields)?.next()?.id, 1)
    }

    func testStreamingServiceChoicesIncludeRememberedAndCustomServices() {
        let (repository, _, preferences) = fixture()
        preferences.set(["Custom TV", "Netflix"], forKey: "TaskFlow.streamingServices")
        let item = task("Show")
        repository.tasks = [item]
        repository.setSpecializedDetails(.init(fields: ["Streaming Service": "custom tv"]), for: item)
        XCTAssertTrue(repository.streamingServiceChoices.contains("Custom TV"))
        XCTAssertEqual(repository.streamingServiceChoices.filter { $0.lowercased() == "custom tv" }.count, 1)
        XCTAssertTrue(repository.streamingServiceChoices.contains("Netflix"))
    }

    func testEpisodeCatchUpCorrectionAndUndo() async throws {
        let (repository, _, _) = fixture()
        let item = task("Show")
        repository.tasks = [item]
        let show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: Data(#"{"id":10,"name":"Show","status":"Ended","url":"https://www.tvmaze.com/shows/10/show","premiered":null,"image":null}"#.utf8))
        let episodes = (1...4).map { ReadingMedia.ShowEpisode(id: $0, name: "Episode", season: $0 < 3 ? 1 : 2, number: $0 < 3 ? $0 : $0 - 2, airdate: "2020-01-01", airstamp: nil, runtime: nil, summary: nil) }
        repository.setSpecializedDetails(.init(fields: ["Show Tracking": ReadingMedia.encodeTracking(.init(show: show, episodes: episodes, cast: [])), "Why Saved": "Keep notes"]), for: item)
        let caughtUp = await repository.setEpisodePosition(3, catchUp: true, taskID: item.id)
        XCTAssertTrue(caughtUp)
        XCTAssertEqual(ReadingMedia.tracking(repository.specializedDetails(item).fields)?.watched, [1, 2, 3])
        let corrected = await repository.setEpisodePosition(2, catchUp: false, taskID: item.id)
        XCTAssertTrue(corrected)
        XCTAssertEqual(ReadingMedia.tracking(repository.specializedDetails(item).fields)?.next()?.id, 2)
        XCTAssertEqual(repository.specializedDetails(item).fields["Why Saved"], "Keep notes")
        XCTAssertEqual(ReadingMedia.tracking(repository.taskUndo?.specializedPrevious[item.id]?.fields ?? [:])?.watched, [1, 2, 3])
        await repository.setWatchedEpisodes([2, 3, 4], watched: true, taskID: item.id)
        XCTAssertEqual(repository.specializedDetails(item).fields["Progress"], "Caught Up")
        XCTAssertFalse(repository.tasks.first!.isCompleted)
    }

    func testEpisodeReleaseAlertsGroupBatchesAndRespectOptOut() throws {
        let (repository, _, _) = fixture()
        let show = try JSONDecoder().decode(ReadingMedia.ShowArtwork.self, from: Data(#"{"id":10,"name":"Show","url":"https://www.tvmaze.com/shows/10/show","premiered":null,"image":null}"#.utf8))
        let future = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: future)
        let episodes = [1, 2].map { ReadingMedia.ShowEpisode(id: $0, name: "Episode", season: 1, number: $0, airdate: date, airstamp: nil, runtime: nil, summary: nil) }
        let catalog = ReadingMedia.ShowTracking(show: show, episodes: episodes, cast: [])
        let item = task("Show")
        repository.tasks = [item]
        repository.setSpecializedDetails(.init(fields: ["Show Tracking": ReadingMedia.encodeTracking(catalog), "Episode Alerts": "true"]), for: item)
        XCTAssertEqual(repository.episodeReleaseAlerts.count, 1)
        let requests = NotificationScheduler.requests(for: [], deadlines: repository.episodeReleaseAlerts, now: Date())
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].content.body.contains("2 episodes"))
        XCTAssertEqual(requests[0].content.userInfo[TaskFlowNotificationPayload.taskIDKey] as? String, item.id)
        XCTAssertEqual((requests[0].trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 9)
        var details = repository.specializedDetails(item)
        details.fields["Episode Alert Hour"] = "18"
        details.fields["Episode Alert Minute"] = "45"
        details.fields["Episode Alert Sound"] = "false"
        details.fields["Episode Alert Advance"] = "30"
        repository.setSpecializedDetails(details, for: item)
        let customized = NotificationScheduler.requests(for: [], deadlines: repository.episodeReleaseAlerts, now: Date())
        XCTAssertNil(repository.episodeReleaseAlerts.first?.exactFireDate, "Unknown air times must use the chosen release-day time")
        XCTAssertEqual((customized.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 18)
        XCTAssertEqual((customized.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents.minute, 45)
        XCTAssertNil(customized.first?.content.sound)
        details.fields["Episode Alerts"] = "false"; repository.setSpecializedDetails(details, for: item)
        XCTAssertTrue(repository.episodeReleaseAlerts.isEmpty)
    }

    func testEpisodeNotificationCustomizationUsesExactTimeAndSilentFallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2030, month: 1, day: 2))!
        let exact = day.addingTimeInterval(19 * 3600 + 30 * 60)
        let alert = NotificationScheduler.DeadlineAlert(taskID: "show", listID: "list", taskTitle: "Show", label: "Episode Release", date: day, leadDays: 0, hour: 18, minute: 45, exactFireDate: exact, playsSound: false)
        var requests = NotificationScheduler.requests(for: [], deadlines: [alert, alert], now: day, calendar: calendar)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].content.sound)
        XCTAssertEqual((requests[0].trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 19)
        XCTAssertEqual((requests[0].trigger as? UNCalendarNotificationTrigger)?.dateComponents.minute, 30)
        var fallback = alert; fallback.exactFireDate = nil
        requests = NotificationScheduler.requests(for: [], deadlines: [fallback], now: day, calendar: calendar)
        XCTAssertEqual((requests[0].trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 18)
        XCTAssertEqual((requests[0].trigger as? UNCalendarNotificationTrigger)?.dateComponents.minute, 45)
        XCTAssertTrue(NotificationScheduler.requests(for: [], deadlines: [alert], now: exact, calendar: calendar).isEmpty)
    }

    func testWidgetEpisodeActionTargetsDisplayedEpisodeAndRejectsFutureOrRematchedShows() throws {
        let show = ReadingMedia.ShowArtwork(id: 10, name: "Show", url: URL(string: "https://www.tvmaze.com/shows/10")!, premiered: nil, image: nil)
        let now = Date()
        let episodes = [1, 2, 3].map { ReadingMedia.ShowEpisode(id: $0, name: "Episode", season: 1, number: $0, airdate: nil, airstamp: ISO8601DateFormatter().string(from: now.addingTimeInterval($0 == 3 ? 86400 : -86400)), runtime: nil, summary: nil) }
        let catalog = ReadingMedia.ShowTracking(show: show, episodes: episodes, cast: [])
        var fields = ["Show Tracking": ReadingMedia.encodeTracking(catalog), "Widget Episode ID": "2", "Why Saved": "A recommendation", "Source Link": "https://www.netflix.com/title/123"]
        XCTAssertEqual(ReadingMedia.widgetEpisode(fields, now: now)?.id, 2)
        let updated = try XCTUnwrap(ReadingMedia.markingEpisodeWatched(fields, showID: 10, episodeID: 2, now: now))
        XCTAssertEqual(ReadingMedia.tracking(updated)?.watched, [2])
        XCTAssertEqual(ReadingMedia.tracking(updated)?.next(now: now)?.id, 1)
        XCTAssertEqual(ReadingMedia.markingEpisodeWatched(updated, showID: 10, episodeID: 2, now: now), updated, "Repeated taps must not replace progress or Undo")
        XCTAssertEqual(updated["Why Saved"], fields["Why Saved"])
        XCTAssertEqual(updated["Source Link"], fields["Source Link"])
        XCTAssertNil(ReadingMedia.markingEpisodeWatched(fields, showID: 11, episodeID: 2, now: now))
        XCTAssertNil(ReadingMedia.markingEpisodeWatched(fields, showID: 10, episodeID: 3, now: now))
        XCTAssertNil(ReadingMedia.markingEpisodeWatched(fields, showID: 10, episodeID: 999, now: now))
        fields["Widget Episode ID"] = "3"
        XCTAssertNil(ReadingMedia.widgetEpisode(fields, now: now))
        fields["Widget Episode ID"] = "999"
        XCTAssertNil(ReadingMedia.widgetEpisode(fields, now: now))
        fields["Progress"] = "Dropped"
        XCTAssertNil(ReadingMedia.markingEpisodeWatched(fields, showID: 10, episodeID: 1, now: now))
    }

    func testWatchedEpisodeJournalPreservesConcurrentTapsAndAcknowledgesOnlyAppliedAction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WatchedEpisodeAction(taskID: "task", metadataID: "metadata", showID: 10, episodeID: 1)
        let second = WatchedEpisodeAction(taskID: "task", metadataID: "metadata", showID: 10, episodeID: 2)
        try WatchedEpisodeActionStore.record(first, directory: directory)
        try WatchedEpisodeActionStore.record(second, directory: directory)
        XCTAssertEqual(Set(WatchedEpisodeActionStore.pending(directory: directory).map(\.id)), [first.id, second.id])
        WatchedEpisodeActionStore.acknowledge(first, directory: directory)
        XCTAssertEqual(WatchedEpisodeActionStore.pending(directory: directory).map(\.id), [second.id])
        WatchedEpisodeActionStore.acknowledge(first, directory: directory)
        XCTAssertEqual(WatchedEpisodeActionStore.pending(directory: directory).map(\.id), [second.id])
    }

    func testPendingWidgetEpisodeActionAppliesOncePreservingNotesAndUndo() async throws {
        let (repository, _, _) = fixture()
        repository.accessState = .granted
        let item = task("Show")
        repository.tasks = [item]
        let show = ReadingMedia.ShowArtwork(id: 10, name: "Show", url: URL(string: "https://www.tvmaze.com/shows/10")!, premiered: nil, image: nil)
        let episodes = [1, 2].map { ReadingMedia.ShowEpisode(id: $0, name: "Episode", season: 1, number: $0, airdate: nil, airstamp: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400)), runtime: nil, summary: nil) }
        let fields = ["Show Tracking": ReadingMedia.encodeTracking(.init(show: show, episodes: episodes, cast: [])), "Why Saved": "Keep this note"]
        repository.setSpecializedDetails(.init(fields: fields), for: item)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = WatchedEpisodeAction(taskID: item.id, metadataID: item.metadataID, showID: 10, episodeID: 1)
        try WatchedEpisodeActionStore.record(action, directory: directory)
        let overlaid = WatchedEpisodeActionStore.applying([action], fields: fields, taskID: item.id, metadataID: item.metadataID)
        XCTAssertEqual(ReadingMedia.tracking(overlaid)?.watched, [1])
        XCTAssertEqual(WatchedEpisodeActionStore.applying([action], fields: fields, taskID: "another", metadataID: "another"), fields)
        await repository.consumeWatchedEpisodeActions(directory: directory)
        XCTAssertTrue(WatchedEpisodeActionStore.pending(directory: directory).isEmpty)
        XCTAssertEqual(ReadingMedia.tracking(repository.specializedDetails(item).fields)?.watched, [1])
        XCTAssertEqual(repository.specializedDetails(item).fields["Why Saved"], "Keep this note")
        XCTAssertEqual(ReadingMedia.tracking(repository.taskUndo?.specializedPrevious[item.id]?.fields ?? [:])?.watched, [])
        await repository.consumeWatchedEpisodeActions(directory: directory)
        XCTAssertEqual(ReadingMedia.tracking(repository.specializedDetails(item).fields)?.next()?.id, 2)
        try WatchedEpisodeActionStore.record(.init(taskID: item.id, metadataID: item.metadataID, showID: 99, episodeID: 2), directory: directory)
        await repository.consumeWatchedEpisodeActions(directory: directory)
        XCTAssertTrue(WatchedEpisodeActionStore.pending(directory: directory).isEmpty)
        XCTAssertEqual(ReadingMedia.tracking(repository.specializedDetails(item).fields)?.watched, [1])
    }

    func testEpisodeNotificationActionsAndOneHourSnoozePreserveIdentityAndOptOut() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2030, month: 1, day: 2))!
        var alert = NotificationScheduler.DeadlineAlert(taskID: "task", listID: "list", taskTitle: "Show", label: "Episode Release", date: day, leadDays: 0, episodeShowID: 10, episodeID: 2, episodeLabel: "S1 E2", episodeRelease: day)
        let released = try XCTUnwrap(NotificationScheduler.requests(for: [], deadlines: [alert], now: day, calendar: calendar).first)
        XCTAssertEqual(released.content.categoryIdentifier, EpisodeNotificationActions.category)
        XCTAssertTrue(EpisodeNotificationActions.matches(released.content, taskID: "task", showID: 10, episodeID: 2))
        let snooze = try XCTUnwrap(EpisodeNotificationActions.snoozeRequest(content: released.content, canMarkWatched: true))
        XCTAssertEqual((snooze.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 3600)
        XCTAssertEqual(snooze.content.userInfo[TaskFlowNotificationPayload.listIDKey] as? String, "list")
        XCTAssertTrue(snooze.content.body.contains("S1 E2"))
        XCTAssertEqual(NotificationScheduler.activeEpisodeSnoozeIDs([snooze], deadlines: [alert]), [snooze.identifier])
        XCTAssertTrue(NotificationScheduler.activeEpisodeSnoozeIDs([snooze], deadlines: []).isEmpty)
        XCTAssertEqual(EpisodeNotificationActions.snoozeRequest(content: released.content, canMarkWatched: false)?.identifier, snooze.identifier)
        alert.episodeRelease = day.addingTimeInterval(20 * 3600)
        let early = try XCTUnwrap(NotificationScheduler.requests(for: [], deadlines: [alert], now: day, calendar: calendar).first)
        XCTAssertEqual(early.content.categoryIdentifier, EpisodeNotificationActions.upcomingCategory)
        let upcoming = try XCTUnwrap(EpisodeNotificationActions.categories.first { $0.identifier == EpisodeNotificationActions.upcomingCategory })
        XCTAssertEqual(upcoming.actions.map(\.identifier), [EpisodeNotificationActions.snooze])
        let normal = try XCTUnwrap(EpisodeNotificationActions.categories.first { $0.identifier == EpisodeNotificationActions.category })
        XCTAssertEqual(normal.actions.map(\.identifier), [EpisodeNotificationActions.watched, EpisodeNotificationActions.snooze])
        XCTAssertNil(EpisodeNotificationActions.snoozeRequest(content: UNMutableNotificationContent(), canMarkWatched: true))
    }

    func testAvailableTimeCountdownUsesSecondsAndSubtractsBusyTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        let now = day.addingTimeInterval(20 * 3600 + 5 * 60 + 7)
        XCTAssertEqual(TodayPlanning.countdownText(seconds: TodayPlanning.availableSeconds([], now: now, calendar: calendar)), "03h 54m 53s")
        XCTAssertEqual(TodayPlanning.availableSeconds([], now: now.addingTimeInterval(1), calendar: calendar), TodayPlanning.availableSeconds([], now: now, calendar: calendar) - 1)
        let busy = TodayPlanning.TimelineEntry(id: "busy", title: "Meeting", start: now, end: now.addingTimeInterval(600), task: nil, event: nil, estimated: false)
        XCTAssertEqual(TodayPlanning.availableSeconds([busy], now: now, calendar: calendar), TodayPlanning.availableSeconds([], now: now, calendar: calendar) - 600)
        // Available time stays steady during reserved time, then counts down in a free gap.
        XCTAssertEqual(TodayPlanning.availableSeconds([busy], now: now.addingTimeInterval(1), calendar: calendar), TodayPlanning.availableSeconds([busy], now: now, calendar: calendar))
        XCTAssertEqual(TodayPlanning.countdownText(seconds: -1), "00h 00m 00s")
        XCTAssertEqual(TodayPlanning.countdownText(seconds: 3600), "01h 00m 00s")
        XCTAssertEqual(TodayPlanning.availableSeconds([], now: day.addingTimeInterval(86399), calendar: calendar), 1)
        XCTAssertEqual(TodayPlanning.availableSeconds([], now: day.addingTimeInterval(86400), calendar: calendar), 86400)
    }

    func testWebNotesThreeWayMergePreservesConcurrentEdits() throws {
        let note = QuickNote(title: "Project", text: "Base")
        let base = try CloudWebNote(note: note)
        var native = note; native.text = "Native edit"
        var browser = note; browser.text = "Browser edit"
        let local = try CloudWebNote(note: native), remote = try CloudWebNote(note: browser)
        let unchangedLocal = try XCTUnwrap(CloudWebNote.resolve(local: base, remote: remote, base: base))
        XCTAssertEqual(unchangedLocal.primary, remote)
        XCTAssertNil(unchangedLocal.recovered)
        let conflict = try XCTUnwrap(CloudWebNote.resolve(local: local, remote: remote, base: base))
        XCTAssertEqual(conflict.primary, remote)
        XCTAssertEqual(conflict.recovered?.text, native.text)
        XCTAssertEqual(conflict.recovered?.folder, "Recovered Notes")
        XCTAssertNotEqual(conflict.recovered?.id, note.id)
        XCTAssertEqual(conflict.recovered?.id, try CloudWebNote.resolve(local: local, remote: remote, base: base)?.recovered?.id)
    }

    func testWebNotesDeleteVersusEditKeepsTheEditRecoverable() throws {
        let note = QuickNote(title: "Keep", text: "Base")
        let base = try CloudWebNote(note: note)
        var edited = note; edited.text = "Unsynced writing"
        let deletion = try CloudWebNote(note: note, isDeleted: true)
        let conflict = try XCTUnwrap(CloudWebNote.resolve(local: CloudWebNote(note: edited), remote: deletion, base: base))
        XCTAssertTrue(conflict.primary.isDeleted)
        XCTAssertEqual(conflict.recovered?.text, edited.text)
    }

    func testWebNoteRecordRoundTripAndIdentityValidation() throws {
        let note = QuickNote(title: "Mixed", text: "A **bold** word\n- [ ] A task")
        let value = try CloudWebNote(note: note)
        XCTAssertEqual(try CloudWebNote(record: value.writing()), value)
        let wrong = value.writing()
        wrong["noteID"] = UUID().uuidString as CKRecordValue
        XCTAssertThrowsError(try CloudWebNote(record: wrong))
    }

    func testBrowserEditsKeepNativeDrawingsAttachmentsAndHistory() throws {
        var original = QuickNote(title: "Native", text: "Original")
        original.drawingData = Data([1, 2, 3])
        original.attachments = [TaskAttachment(kind: .url, title: "Link", urlString: "https://example.com")]
        var browser = original; browser.text = "Browser update"
        let record = try CloudWebNote(note: browser)
        XCTAssertNil(try record.note().drawingData)
        XCTAssertTrue(record.hasDrawing)
        XCTAssertTrue(try CloudWebNote(record: record.writing()).hasDrawing)
        var snapshot = MetadataSnapshot(quickNotes: [original])
        CloudNotesSyncService.apply(record, to: &snapshot)
        let updated = try XCTUnwrap(snapshot.quickNotes.first)
        XCTAssertEqual(updated.text, browser.text)
        XCTAssertEqual(updated.drawingData, original.drawingData)
        XCTAssertEqual(updated.attachments, original.attachments)
        XCTAssertFalse(updated.versions.isEmpty)
        XCTAssertEqual(snapshot.taskMetadata, [:])
        let deletion = try CloudWebNote(note: browser, isDeleted: true)
        CloudNotesSyncService.apply(deletion, to: &snapshot)
        let once = snapshot
        CloudNotesSyncService.apply(deletion, to: &snapshot)
        XCTAssertEqual(snapshot, once, "Re-reading a tombstone must not create another sync mutation")
    }

    func testWebNoteRejectsOversizedPayloadAndUnknownSchema() throws {
        XCTAssertThrowsError(try CloudWebNote(note: QuickNote(text: String(repeating: "x", count: 600_001))))
        let record = try CloudWebNote(note: QuickNote(text: "Okay")).writing()
        record["schemaVersion"] = NSNumber(value: 2)
        XCTAssertThrowsError(try CloudWebNote(record: record))
    }

    func testRecoveredWebNoteKeepsNativeDrawingAndAttachmentData() throws {
        var recovered = QuickNote(title: "Recovered", text: "Concurrent edit")
        recovered.drawingData = Data([9, 8, 7])
        recovered.attachments = [TaskAttachment(kind: .url, title: "Reference", urlString: "https://example.com")]
        let projection = try CloudWebNote(note: recovered)
        var snapshot = MetadataSnapshot(quickNotes: [])
        CloudNotesSyncService.apply(projection, to: &snapshot, preserving: recovered)
        let saved = try XCTUnwrap(snapshot.quickNotes.first)
        XCTAssertEqual(saved.id, recovered.id)
        XCTAssertEqual(saved.drawingData, recovered.drawingData)
        XCTAssertEqual(saved.attachments, recovered.attachments)
        XCTAssertTrue(try CloudWebNote(note: saved).hasDrawing)
    }

    func testReadingPreviewDownsamplesLargeImagesAndRejectsInvalidData() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1024), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        }
        let data = try XCTUnwrap(original.jpegData(compressionQuality: 0.9))
        let thumbnail = try XCTUnwrap(ReadingThumbnailCache.thumbnail(data))
        let image = try XCTUnwrap(UIImage(data: thumbnail))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 640)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.01)
        XCTAssertNil(ReadingThumbnailCache.thumbnail(Data("Not an image".utf8)))
    }

    func testTextSharesDoNotOverwriteEarlierCaptures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TextShareCapture(text: "First", kind: "Task")
        let second = TextShareCapture(text: "Second", kind: "Event")
        try first.enqueue(directory: directory)
        try second.enqueue(directory: directory)
        XCTAssertEqual(Set(TextShareCapture.pending(directory: directory).map(\.text)), ["First", "Second"])
        first.acknowledge(directory: directory)
        XCTAssertEqual(TextShareCapture.pending(directory: directory).map(\.text), ["Second"])
    }

    func testFocusRankingBoundsOldOverdueDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var old = task("Old overdue")
        old.dueDate = now.addingTimeInterval(-10 * 365 * 86400)
        old.hasDueTime = true
        XCTAssertEqual(TodayPlanning.focusScore(old, pinned: false, availableMinutes: nil, now: now), 620)
        XCTAssertGreaterThan(TodayPlanning.focusScore(task("Pinned"), pinned: true, availableMinutes: nil, now: now), TodayPlanning.focusScore(old, pinned: false, availableMinutes: nil, now: now))
        old.dueDate = Date(timeIntervalSince1970: .infinity)
        XCTAssertEqual(TodayPlanning.focusScore(old, pinned: false, availableMinutes: nil, now: now), 200)
    }

    func testTodayTimelineMergesBusyTimeAndFocusRanking() {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        var timed = task("Timed task")
        timed.dueDate = now.addingTimeInterval(3600)
        timed.hasDueTime = true
        timed.durationMinutes = 60
        let event = CalendarEvent(id: "event", calendarID: "calendar", title: "Meeting", location: nil, notes: nil, url: nil, startDate: now.addingTimeInterval(5400), endDate: now.addingTimeInterval(9000), isAllDay: false)
        let entries = TodayPlanning.timeline(tasks: [timed, task("Untimed"), task("Finished", completed: true)], events: [event], now: now)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { TodayPlanning.conflicts($0, entries: entries) })
        let gaps = TodayPlanning.gaps(entries, now: now)
        XCTAssertEqual(gaps.first?.minutes, 60)
        XCTAssertEqual(gaps.last?.start, event.endDate)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(gaps.reduce(0) { $0 + $1.minutes }, Int(midnight.timeIntervalSince(now) / 60) - 90)
        var short = task("Short task"); short.durationMinutes = 20
        var long = task("Long task"); long.durationMinutes = 90
        XCTAssertGreaterThan(TodayPlanning.focusScore(short, pinned: false, availableMinutes: 30, now: now), TodayPlanning.focusScore(long, pinned: false, availableMinutes: 30, now: now))
        XCTAssertGreaterThan(TodayPlanning.focusScore(long, pinned: true, availableMinutes: 30, now: now), TodayPlanning.focusScore(short, pinned: false, availableMinutes: 30, now: now))
        let (repository, _, _) = fixture()
        XCTAssertFalse(repository.visibleTodaySections.contains(.timeline))
        repository.setTodaySectionVisible(.timeline, true)
        XCTAssertTrue(repository.visibleTodaySections.contains(.timeline))
    }

    func testClearTaskFiltersRestoresTasksWithoutChangingScope() {
        let (repository, _, _) = fixture()
        repository.accessState = .granted
        repository.tasks = [task("Plan the launch")]
        repository.selectedScope = .all
        repository.searchQuery = "no match"
        repository.selectedTagFilter = .tag("missing")
        repository.quickStatusFilter = .blocked
        repository.quickPriorityFilter = .high
        repository.quickTagFilter = .noTags
        repository.quickDueFilter = .today
        repository.dueFilter = .overdue
        XCTAssertTrue(repository.rootTasks.isEmpty)
        repository.clearTaskFilters()
        XCTAssertEqual(repository.rootTasks.count, 1)
        XCTAssertEqual(repository.selectedScope, .all)
        XCTAssertFalse(repository.isSearchActive)
        XCTAssertNil(repository.selectedTagFilter)
        XCTAssertNil(repository.quickStatusFilter)
        XCTAssertNil(repository.quickPriorityFilter)
        XCTAssertNil(repository.quickTagFilter)
        XCTAssertEqual(repository.quickDueFilter, .any)
        XCTAssertEqual(repository.dueFilter, .any)
    }

    func testTodaySectionPreferencesNormalizePersistAndReset() {
        let (repository, store, preferences) = fixture()
        preferences.set(["tomorrow", "tomorrow", "unknown", "tasks"], forKey: "TaskFlow.todaySectionOrder")
        XCTAssertEqual(repository.todaySectionOrder.prefix(2), [.tomorrow, .tasks])
        XCTAssertEqual(Set(repository.todaySectionOrder).count, TodayDashboardSection.allCases.count)
        repository.setTodaySectionVisible(.tomorrow, false)
        XCTAssertFalse(repository.visibleTodaySections.contains(.tomorrow))
        repository.moveTodaySections(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let relaunched = TaskRepository(preferences: preferences, metadataStore: store)
        XCTAssertEqual(relaunched.todaySectionOrder.first, .tasks)
        XCTAssertFalse(relaunched.visibleTodaySections.contains(.tomorrow))
        relaunched.resetTodaySections()
        XCTAssertEqual(relaunched.visibleTodaySections, TodayDashboardSection.allCases.filter { $0 != .timeline })
    }

    func testTodaySuggestionsExcludeUnfinishedOrUnknownDependencies() {
        let (repository, _, _) = fixture()
        let blocker = task("Get approval"), done = task("done", completed: true)
        let blocked = task("Launch", dependencies: [blocker.id])
        let ready = task("Ready", dependencies: [done.id])
        let missing = task("Missing", dependencies: ["not-loaded"])
        var manual = task("Manual"), waiting = task("Waiting")
        manual.status = .blocked; waiting.status = .waiting
        repository.tasks = [blocker, done, blocked, ready, missing, manual, waiting]
        XCTAssertFalse(repository.isActionableToday(blocked))
        XCTAssertFalse(repository.isActionableToday(missing))
        XCTAssertFalse(repository.isActionableToday(manual))
        XCTAssertFalse(repository.isActionableToday(waiting))
        XCTAssertFalse(repository.isActionableToday(done))
        XCTAssertTrue(repository.isActionableToday(ready))
        XCTAssertEqual(repository.waitingOnDescription(blocked), "Waiting On: Get approval")
        XCTAssertEqual(repository.waitingOnDescription(missing), "Waiting On: Unavailable task")
        XCTAssertNil(repository.waitingOnDescription(ready))
        repository.tasks[0].isCompleted = true
        XCTAssertTrue(repository.isActionableToday(blocked))
        XCTAssertNil(repository.waitingOnDescription(blocked))
    }

    func testTodayPrioritiesPersistReorderAndLeaveDueDatesAlone() {
        let (repository, store, preferences) = fixture()
        var first = task("one"), second = task("two"), third = task("three"), fourth = task("four")
        first.dueDate = Calendar.current.date(byAdding: .day, value: 4, to: Date())
        repository.tasks = [first, second, third, fourth]
        repository.toggleTodayPriority(first); repository.toggleTodayPriority(second); repository.toggleTodayPriority(third)
        repository.toggleTodayPriority(fourth)
        XCTAssertEqual(repository.todayPriorityTasks.map(\.id), ["one", "two", "three"])
        XCTAssertEqual(repository.tasks.first?.dueDate, first.dueDate)
        repository.moveTodayPriorities(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(repository.todayPriorityTasks.map(\.id), ["three", "one", "two"])
        let relaunched = TaskRepository(preferences: preferences, metadataStore: store)
        relaunched.tasks = repository.tasks
        XCTAssertEqual(relaunched.todayPriorityTasks.map(\.id), ["three", "one", "two"])
        relaunched.tasks.removeAll { $0.id == "three" }
        XCTAssertEqual(relaunched.todayPriorityTasks.map(\.id), ["one", "two"])
        preferences.set("old-day", forKey: "TaskFlow.todayPriorityDay")
        XCTAssertTrue(relaunched.todayPriorityTasks.isEmpty)
    }

    func testTodayEmptyStateDoesNotClaimPastDueWorkIsFinished() {
        let now = Calendar.current.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 12))!
        var overdue = task("late"), completed = task("done", completed: true)
        overdue.dueDate = now.addingTimeInterval(-60); overdue.hasDueTime = true
        completed.dueDate = now
        XCTAssertEqual(TodayPlanning.emptyTaskMessage([overdue, completed], now: now), "Today’s remaining tasks are in Overdue")
        XCTAssertEqual(TodayPlanning.emptyTaskMessage([completed], now: now), "Today’s scheduled tasks are finished")
        XCTAssertEqual(TodayPlanning.emptyTaskMessage([], now: now), "No tasks due today")
    }

    func testTodaySpotlightHandlesEventBoundariesAndAllDaySeparately() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = CalendarEvent(id: "ended", calendarID: "cal", title: "Ended", startDate: now.addingTimeInterval(-3600), endDate: now, isAllDay: false)
        let current = CalendarEvent(id: "now", calendarID: "cal", title: "Now", startDate: now, endDate: now.addingTimeInterval(1800), isAllDay: false)
        let next = CalendarEvent(id: "next", calendarID: "cal", title: "Next", startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200), isAllDay: false)
        let allDay = CalendarEvent(id: "day", calendarID: "cal", title: "All Day", startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(10000), isAllDay: true)
        if case .now(let event) = TodayPlanning.spotlight([next, ended, current, allDay], now: now) { XCTAssertEqual(event.id, "now") } else { XCTFail("Expected the active event") }
        if case .next(let event) = TodayPlanning.spotlight([ended, next, allDay], now: now) { XCTAssertEqual(event.id, "next") } else { XCTFail("Expected the upcoming event") }
        if case .allDay = TodayPlanning.spotlight([ended, allDay], now: now) {} else { XCTFail("All-day events need a separate status") }
        if case .finished = TodayPlanning.spotlight([ended], now: now) {} else { XCTFail("An event ending exactly now is finished") }
        if case .empty = TodayPlanning.spotlight([], now: now) {} else { XCTFail("Expected an empty day") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNotEqual(TodayPlanning.dayKey(now, calendar: calendar), TodayPlanning.dayKey(now.addingTimeInterval(86400), calendar: calendar))
    }

    func testListOrderingPersistsAndRemapsAcrossDevices() throws {
        let (repository, _, preferences) = fixture()
        let lists = [TaskList(id: "a", title: "A", color: .blue), TaskList(id: "b", title: "B", color: .red), TaskList(id: "c", title: "C", color: .green)]
        XCTAssertEqual(TaskRepository.orderedLists(lists, order: ["missing", "b", "b"]).map(\.id), ["b", "a", "c"])
        repository.lists = lists
        repository.moveLists(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(repository.lists.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(preferences.stringArray(forKey: "TaskFlow.listOrder"), ["c", "a", "b"])
        var snapshot = MetadataSnapshot()
        snapshot.syncedSettings["TaskFlow.listOrder"] = try PropertyListSerialization.data(fromPropertyList: ["value": ["c", "a", "b"]], format: .xml, options: 0)
        let remapped = snapshot.remappingListIDs(["a": "other-a", "b": "other-b", "c": "other-c"])
        let data = try XCTUnwrap(remapped.syncedSettings["TaskFlow.listOrder"])
        let wrapper = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(wrapper["value"] as? [String], ["other-c", "other-a", "other-b"])
    }

    func testExpandedListIconsHaveValidSymbols() {
        XCTAssertEqual(Set(TaskRepository.listIconChoices).count, TaskRepository.listIconChoices.count)
        for icon in TaskRepository.listIconChoices { XCTAssertNotNil(UIImage(systemName: icon), icon) }
    }

    func testDependencyPickerRejectsSelfAndIndirectCycles() {
        let (repository, _, _) = fixture()
        let a = task("a"), b = task("b", dependencies: ["c"]), c = task("c", dependencies: ["a"]), d = task("d")
        repository.tasks = [a, b, c, d]
        XCTAssertFalse(repository.canAddDependency(a, to: a))
        XCTAssertFalse(repository.canAddDependency(b, to: a))
        XCTAssertTrue(repository.canAddDependency(d, to: a))
        XCTAssertFalse(repository.canAddDependency(task("finished", completed: true), to: a))
    }

    func testMixedNoteFormattingTargetsSelectionAndSurvivesReopening() {
        let source = NoteRichText.decode("Hello 🌎 world\nFirst item\nPlain paragraph")
        let range = (source.string as NSString).range(of: "world")
        let bold = NoteRichText.formatted(source, selection: range, command: .init(opening: "**", closing: "**"))
        XCTAssertEqual(NoteRichText.encode(bold.0), "Hello 🌎 **world**\nFirst item\nPlain paragraph")
        let itemRange = (bold.0.string as NSString).range(of: "First item")
        let bullet = NoteRichText.formatted(bold.0, selection: itemRange, command: .init(opening: "- ", wholeLine: true))
        let stored = NoteRichText.encode(bullet.0)
        XCTAssertEqual(stored, "Hello 🌎 **world**\n- First item\nPlain paragraph")
        let reopened = NoteRichText.decode(stored)
        XCTAssertEqual(reopened.string, "Hello 🌎 world\n• First item\nPlain paragraph")
        let traits = (reopened.attribute(.font, at: (reopened.string as NSString).range(of: "world").location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits
        XCTAssertTrue(traits?.contains(.traitBold) == true)
        let plainRange = (reopened.string as NSString).range(of: "Plain paragraph")
        XCTAssertFalse((reopened.attribute(.font, at: plainRange.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let normal = NoteRichText.formatted(reopened, selection: (reopened.string as NSString).range(of: "First item"), command: .init(opening: "", wholeLine: true))
        XCTAssertEqual(NoteRichText.encode(normal.0), "Hello 🌎 **world**\nFirst item\nPlain paragraph")
        let note = QuickNote(text: stored, format: .markdown)
        let persisted = try! JSONDecoder().decode(QuickNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(NoteRichText.decode(persisted.text).string, reopened.string)
    }

    func testRichEditorFormattingUndoAndAdjacentInlineRuns() {
        var stored = "word"
        let editor = NoteFormattingTextEditor(text: Binding(get: { stored }, set: { stored = $0 }), command: .constant(nil), focused: .constant(false))
        let coordinator = editor.makeCoordinator()
        let view = UITextView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let host = UIViewController(); window.rootViewController = host
        host.view.addSubview(view); window.makeKeyAndVisible(); view.becomeFirstResponder()
        view.attributedText = NoteRichText.decode(stored)
        let range = NSRange(location: 0, length: 4)
        view.selectedRange = range
        let bold = NoteRichText.formatted(view.attributedText, selection: range, command: .init(opening: "**", closing: "**"))
        coordinator.replace(view, text: bold.0, selection: bold.1)
        XCTAssertEqual(stored, "**word**")
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        XCTAssertEqual(stored, "word")
        view.undoManager?.redo()
        XCTAssertEqual(stored, "**word**")
        view.resignFirstResponder(); window.isHidden = true
        let split = NSMutableAttributedString(attributedString: NoteRichText.decode("**word**"))
        split.addAttribute(.foregroundColor, value: UIColor.red, range: NSRange(location: 0, length: 2))
        XCTAssertEqual(NoteRichText.encode(split), "**word**")
        let quote = NoteRichText.formatted(split, selection: range, command: .init(opening: "> ", wholeLine: true))
        XCTAssertEqual(NoteRichText.encode(quote.0), "> **word**")
    }

    func testRichNoteInlineToggleLinksAndLegacyFormats() {
        let decoded = NoteRichText.decode("**bold** and *italic*\n- [x] Finished\n> Quote\n# Heading")
        XCTAssertEqual(NoteRichText.encode(decoded), "**bold** and *italic*\n- [x] Finished\n> Quote\n# Heading")
        let normal = NoteRichText.formatted(decoded, selection: NSRange(location: 0, length: 4), command: .init(opening: "**", closing: "**"))
        XCTAssertTrue(NoteRichText.encode(normal.0).hasPrefix("bold and *italic*"))
        let linked = NoteRichText.formatted(NoteRichText.decode("Link label"), selection: NSRange(location: 0, length: 10), command: .init(opening: "[", closing: "](https://example.com)"))
        XCTAssertEqual(NoteRichText.encode(linked.0), "[Link label](https://example.com)")
        let literal = "**literal**\n- ordinary text\n1. ordinary number"
        XCTAssertEqual(NoteRichText.decode(NoteRichText.legacyText(literal, format: .plain)).string, literal)
        XCTAssertEqual(NoteRichText.legacyText("- [x] Done\n- [ ] Next", format: .checklist), "- [x] Done\n- [ ] Next")
        XCTAssertEqual(NoteRichText.decode(NoteRichText.legacyText("- First\n- Second", format: .bullets)).string, "• First\n• Second")
    }

    func testRichEditorContinuesListAndReturnExitsEmptyBullet() {
        var text = "- Item"
        let editor = NoteFormattingTextEditor(text: Binding(get: { text }, set: { text = $0 }), command: .constant(nil), focused: .constant(false))
        let coordinator = editor.makeCoordinator()
        let view = UITextView()
        view.attributedText = NoteRichText.decode(text)
        view.selectedRange = NSRange(location: view.attributedText.length, length: 0)
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "\n"))
        XCTAssertEqual(text, "- Item\n- ")
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "\n"))
        XCTAssertEqual(text, "- Item\n")
        XCTAssertEqual(view.typingAttributes[.notePrefix] as? String, nil)
    }

    func testNoteFormattingPreservesUnicodeAndFormatsSelectedLines() {
        let text = "Hello 💡 world"
        let range = (text as NSString).range(of: "💡 world")
        let result = NoteMarkupEditing.apply(NoteFormattingCommand(opening: "**", closing: "**"), to: text, selection: range)
        XCTAssertEqual(result.text, "Hello **💡 world**")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "💡 world")
        let numbered = NoteMarkupEditing.apply(NoteFormattingCommand(opening: "1. ", wholeLine: true), to: "One\nTwo\nTail", selection: NSRange(location: 0, length: 7))
        XCTAssertEqual(numbered.text, "1. One\n2. Two\nTail")
        let empty = NoteMarkupEditing.apply(NoteFormattingCommand(opening: "*", closing: "*", placeholder: "idea"), to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.text, "*idea*")
    }

    func testNetflixRetryRefinesGenericTypeAndPreservesPersonalDetails() {
        let source = "https://www.netflix.com/us/title/80237957?s=i"
        let initial = ["Source Link": source, "Format": "Video", "Progress": "In Progress", "Why Saved": "Recommended by a friend"]
        let retry = ReadingMedia.previewRetryFields(initial, title: "www.netflix.com")
        XCTAssertEqual(retry["Captured Format"], "Video")
        XCTAssertEqual(retry["Captured Title"], "www.netflix.com")
        let repaired = ReadingMedia.enrich(retry, with: ["Format": "TV Show", "Thumbnail URL": "https://example.com/poster.jpg"])
        XCTAssertEqual(repaired["Format"], "TV Show")
        XCTAssertEqual(repaired["Progress"], "In Progress")
        XCTAssertEqual(repaired["Why Saved"], "Recommended by a friend")
        XCTAssertEqual(ReadingMedia.previewRetryFields(["Source Link": source, "Format": "Movie"], title: "My title")["Format"], "Movie")
        XCTAssertNil(ReadingMedia.previewRetryFields(initial, title: "My title")["Captured Title"])
        XCTAssertEqual(ReadingMedia.previewRetryFields(["Source Link": "file:///tmp/no"], title: "Test"), ["Source Link": "file:///tmp/no"])
    }

    func testExactNetflixShareAndLateStructuredMetadata() throws {
        let raw = "https://www.netflix.com/us/title/80237957?s=i&trkid=13747225&shareType=Title&shareUuid=906E84D7-95FD-4631-A2F4-0CC7CCEFE674&trg=cp&unifiedEntityIdEncoded=Video%3A80237957&vlang=en"
        let url = try XCTUnwrap(ReadingMedia.webURL(in: raw))
        XCTAssertEqual(ReadingMedia.provider(for: url), "Netflix")
        XCTAssertEqual(ReadingMedia.canonicalURL(raw), "netflix:80237957")
        XCTAssertEqual(ReadingMedia.canonicalURL("https://www.netflix.com/watch/80237957"), ReadingMedia.canonicalURL(raw))
        XCTAssertEqual(ReadingMedia.preferredShareText(["Avatar: The Last Airbender", raw]), raw)
        XCTAssertEqual(ReadingMedia.action(for: ReadingMedia.format(for: url)), "Watch")
        XCTAssertEqual(ReadingMedia.cleanTitle("Watch Avatar: The Last Airbender | Netflix Official Site", url: url), "Avatar: The Last Airbender")
        XCTAssertEqual(ReadingMedia.cleanTitle("Watch Avatar: The Last Airbender | Netflix", url: url), "Avatar: The Last Airbender")
        let html = "<html><head><title>Watch Avatar: The Last Airbender | Netflix Official Site</title><style>" + String(repeating: " ", count: 1_200_000) + #"</style><script type="application/ld+json">{"@context":"http://schema.org","@type":"TVSeries","name":"Avatar: The Last Airbender","genre":"Action","image":"https://images.example.com/avatar.jpg","dateCreated":"2024-2-22","numberOfSeasons":2}</script></head>"#
        let metadata = try XCTUnwrap(ReadingLinkMetadata.parseResponse(data: Data(html.utf8), baseURL: url, isComplete: false))
        XCTAssertEqual(metadata.title, "Avatar: The Last Airbender")
        XCTAssertEqual(metadata.format, "TV Show")
        XCTAssertEqual(metadata.fields["Year"], "2024")
        XCTAssertEqual(metadata.fields["Saved From"], "Netflix")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://images.example.com/avatar.jpg")
        XCTAssertNil(metadata.estimatedMinutes)
        XCTAssertEqual(Set(ReadingMedia.suggestedTags(ReadingMedia.enrich(["Source Link": raw], with: metadata.fields), includeGenres: false)), ["tv-show", "netflix"])
        let ordinary = try XCTUnwrap(ReadingLinkMetadata.parseResponse(data: Data(html.utf8), baseURL: URL(string: "https://example.com/page")!, isComplete: true))
        XCTAssertNotEqual(ordinary.format, "TV Show") // Other sites keep their smaller response cap.
    }

    func testStreamingShareRepresentationsAndArtworkShapes() throws {
        let netflix = "https://www.netflix.com/title/80057281?s=i&trkid=13747225"
        XCTAssertEqual(ReadingMedia.sharedText(from: Data(netflix.utf8)), netflix)
        XCTAssertEqual(ReadingMedia.sharedText(from: NSAttributedString(string: netflix)), netflix)
        XCTAssertEqual(ReadingMedia.sharedText(from: URL(string: netflix)), netflix)
        XCTAssertNil(ReadingMedia.sharedText(from: Data([0xff])))
        XCTAssertEqual(ReadingMedia.preferredShareText(["Stranger Things", "https://example.com", netflix]), netflix)
        XCTAssertEqual(ReadingMedia.provider(for: ReadingMedia.webURL(in: "More: https://example.com Watch: " + netflix)!), "Netflix")
        let hbo = URL(string: "https://play.hbomax.com/show/8c11d041-6b71-4e54-8369-fdb310e063b8?utm_medium=sharebutton&utm_id=6E4B6615-1971-4D50-8FA1-CAEAE42C3350")!
        XCTAssertEqual(ReadingMedia.provider(for: hbo), "HBO Max")
        XCTAssertEqual(ReadingMedia.format(for: hbo), "TV Show")
        XCTAssertEqual(ReadingMedia.artworkAspect(width: 1600, height: 900, format: "TV Show"), 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(ReadingMedia.artworkAspect(width: 600, height: 900, format: "Video"), 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(ReadingMedia.artworkAspect(width: 0, height: 0, format: "TV Show"), 0.75)
        XCTAssertNil(ReadingMedia.enrich(["Suppress Preview": "true"], with: ["Local Preview": "file.jpg"])["Local Preview"])
        XCTAssertNil(ReadingMedia.enrich(["Thumbnail URL": "https://example.com/manual.jpg"], with: ["Local Preview": "file.jpg"])["Local Preview"])
    }

    func testShowArtworkSearchKeepsAmbiguousResultsForReview() throws {
        let data = Data(#"[{"show":{"id":1,"name":"Reacher","url":"https://www.tvmaze.com/shows/1/reacher","premiered":"2022-02-04","image":{"medium":"https://static.tvmaze.com/reacher.jpg","original":null}}},{"show":{"id":2,"name":"Reacher","url":"https://www.tvmaze.com/shows/2/reacher","premiered":"2030-01-01","image":{"medium":"https://static.tvmaze.com/reboot.jpg","original":null}}},{"show":{"id":3,"name":"Missing","url":"https://www.tvmaze.com/shows/3","premiered":null,"image":null}}]"#.utf8)
        XCTAssertEqual(try ReadingMedia.showArtworkResults(from: data).map(\.id), [1, 2])
        XCTAssertThrowsError(try ReadingMedia.showArtworkResults(from: Data("not json".utf8)))
    }

    func testMediaRoutingAndLinkExtraction() {
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://www.youtube.com/watch?v=123&t=42")!), "Video")
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://notyoutube.com/article")!), "Article")
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://podcasts.apple.com/us/podcast/episode")!), "Audio")
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://tv.apple.com/us/show/slow-horses/umc.example")!), "TV Show")
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://nottv.apple.com/news")!), "Article")
        XCTAssertEqual(ReadingMedia.format(for: URL(string: "https://open.spotify.com/episode/123")!), "Audio")
        XCTAssertEqual(ReadingMedia.displayFormat(["Format": "Article", "Source Link": "https://tv.apple.com/show/123"]), "TV Show")
        XCTAssertEqual(ReadingMedia.displayFormat(["Format": "Book", "Source Link": "https://tv.apple.com/show/123"]), "Book")
        XCTAssertEqual(ReadingMedia.watchLinks(["Source Link": "https://primevideo.com/detail/123", "Saved From": "Netflix"]).first?.provider, "Prime Video")
        XCTAssertNil(ReadingMedia.enrich(["Suppress Preview": "true"], with: ["Thumbnail URL": "https://images.example.com/poster.jpg"])["Thumbnail URL"])
        XCTAssertTrue(ReadingMedia.isPending(["Format": "Article", "Source Link": "https://tv.apple.com/show/123"], watch: true))
        XCTAssertFalse(ReadingMedia.isPending(["Format": "Video", "Progress": "Finished"], watch: true))
        XCTAssertFalse(ReadingMedia.isPending(["Format": "Video"], watch: false))
        XCTAssertTrue(ReadingMedia.isPending(["Format": "Audio", "Progress": "In Progress"], watch: false))
        XCTAssertEqual(ReadingMedia.action(for: "Podcast"), "Listen")
        XCTAssertEqual(ReadingMedia.action(for: "Video"), "Watch")
        XCTAssertEqual(ReadingMedia.action(for: "Article"), "Read")
        XCTAssertEqual(ReadingMedia.webURL(in: "Read this: https://example.com/news")?.absoluteString, "https://example.com/news")
        XCTAssertNil(ReadingMedia.webURL(in: "file:///private/document"))
        XCTAssertNil(ReadingMedia.webURL(in: "No link here"))
    }

    func testPreviewEnrichmentPreservesUserFields() {
        let initial = ["Creator": "My author", "Format": "Book", "Captured Format": "Article", "Source Link": "https://example.com"]
        let fetched = ["Creator": "Page author", "Format": "Video", "Thumbnail URL": "https://example.com/image.jpg"]
        let enriched = ReadingMedia.enrich(initial, with: fetched)
        XCTAssertEqual(enriched["Creator"], "My author")
        XCTAssertEqual(enriched["Format"], "Book")
        XCTAssertEqual(enriched["Source Link"], "https://example.com")
        XCTAssertEqual(enriched["Thumbnail URL"], fetched["Thumbnail URL"])
        XCTAssertEqual(ReadingMedia.enrich(["Format": "Article", "Captured Format": "Article"], with: fetched)["Format"], "Video")
    }

    func testAudioMetadataDoesNotEstimateReadingTime() {
        let html = "<meta property='og:type' content='music.song'><title>Episode</title><p>" + Array(repeating: "word", count: 460).joined(separator: " ") + "</p>"
        let metadata = ReadingLinkMetadata.parse(html: html, baseURL: URL(string: "https://example.com/audio")!)
        XCTAssertEqual(metadata.format, "Audio")
        XCTAssertNil(metadata.estimatedMinutes)
    }

    func testBillDeadlinesScheduleOnTheDayAndWithAdvanceNotice() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        let deadline = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let alert = NotificationScheduler.DeadlineAlert(taskID: "bill", listID: "bills", taskTitle: "Streaming", label: "Cancellation Deadline", date: deadline, leadDays: 3)
        let requests = NotificationScheduler.requests(for: [], deadlines: [alert], now: now, calendar: calendar)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.identifier.hasPrefix("taskflow-due-bill-cancellation-deadline-") })
        XCTAssertEqual(requests.map(\.content.title), ["Cancellation Deadline in 3 Days", "Cancellation Deadline Today"])
        let fireDates = requests.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents }.map { $0.day }
        XCTAssertEqual(fireDates, [17, 20])

        // Past days stay quiet; a deadline already reached produces nothing.
        let past = NotificationScheduler.DeadlineAlert(taskID: "old", listID: "bills", taskTitle: "Gym", label: "Notice Date", date: calendar.date(byAdding: .day, value: -1, to: now)!)
        XCTAssertTrue(NotificationScheduler.requests(for: [], deadlines: [past], now: now, calendar: calendar).isEmpty)
    }

    func testQuickAddParserRecognizesEveryPart() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8))!
        let text = "Pay rent tomorrow 9am #bills !high @Home remind me 30 min before"
        let parse = QuickAddParser.parse(text, lists: [(id: "home", title: "Home"), (id: "work", title: "Work")], now: now, calendar: calendar)
        XCTAssertEqual(parse.title, "Pay rent")
        XCTAssertEqual(parse.tags, ["bills"])
        XCTAssertEqual(parse.priority, .high)
        XCTAssertEqual(parse.listID, "home")
        XCTAssertEqual(parse.alarmMinutes, 30)
        XCTAssertTrue(parse.hasDueTime)
        XCTAssertEqual(parse.dueDate.map { calendar.component(.hour, from: $0) }, 9)
        XCTAssertEqual(Set(parse.tokens.map(\.kind)), [.date, .tag, .priority, .list, .alert])

        let plain = QuickAddParser.parse("Wow! great idea !! #a #A", now: now, calendar: calendar)
        XCTAssertEqual(plain.priority, .medium)          // "!!" alone, not the "!" inside "Wow!"
        XCTAssertEqual(plain.tags, ["a"])                // case-insensitive duplicates collapse
        XCTAssertEqual(plain.title, "Wow! great idea")
        XCTAssertTrue(QuickAddParser.parse("Email Sam !flag", now: now).isFlagged)
        XCTAssertNil(QuickAddParser.parse("Call @Nowhere", lists: [(id: "home", title: "Home")], now: now).listID)
    }

    func testReceiptParserReadsItemLinesAndSkipsTotals() {
        let lines = ReceiptParser.lines(from: ["GV WHL MLK GAL 3.48 F", "BANANAS 1.29", "SUBTOTAL 24.10", "TAX 1.20", "EGGS LG 12CT $4.99", "VISA TEND 25.30", "2 @ 1.00", "Bread 2,49 A"])
        XCTAssertEqual(lines, [
            ReceiptLine(name: "GV WHL MLK GAL", price: 3.48), ReceiptLine(name: "BANANAS", price: 1.29),
            ReceiptLine(name: "EGGS LG 12CT", price: 4.99), ReceiptLine(name: "Bread", price: 2.49)
        ])
        let matches = ReceiptParser.match(items: [(id: "milk", title: "Whole Milk"), (id: "banana", title: "Bananas"), (id: "eggs", title: "Eggs"), (id: "tea", title: "Green Tea")], lines: lines)
        XCTAssertEqual(matches["milk"]?.price, 3.48)
        XCTAssertEqual(matches["banana"]?.price, 1.29)
        XCTAssertEqual(matches["eggs"]?.price, 4.99)
        XCTAssertNil(matches["tea"])
    }

    func testShoppingTitleNormalizerIgnoresCaseAccentsAndPlurals() {
        XCTAssertEqual(ShoppingTitleNormalizer.normalize("Eggs"), ShoppingTitleNormalizer.normalize("egg"))
        XCTAssertEqual(ShoppingTitleNormalizer.normalize("Berries!"), "berry")
        XCTAssertEqual(ShoppingTitleNormalizer.normalize("Tomatoes"), ShoppingTitleNormalizer.normalize("tomato"))
        XCTAssertEqual(ShoppingTitleNormalizer.normalize("Crème Fraîche"), "creme fraiche")
        XCTAssertEqual(ShoppingTitleNormalizer.normalize("Glass"), "glass")
    }

    func testDueTodaySummaryReadsNaturally() {
        XCTAssertEqual(GetDueTodayIntent.summary(titles: [], overdue: 0), "Nothing is due today.")
        XCTAssertEqual(GetDueTodayIntent.summary(titles: ["Pay rent"], overdue: 1), "You have 1 thing due today: Pay rent. 1 is overdue.")
        XCTAssertEqual(GetDueTodayIntent.summary(titles: ["A", "B", "C", "D", "E"], overdue: 0), "You have 5 things due today: A, B, C, and 2 more.")
    }

    func testUpcomingGroupsTasksByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        func dated(_ id: String, days: Int) -> TaskItem {
            var item = task(id)
            item.dueDate = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
            return item
        }
        let groups = TaskRepository.upcomingGroups([dated("later", days: 40), dated("today", days: 0), dated("late", days: -2), dated("tomorrow", days: 1), dated("soon", days: 3)], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.id).prefix(4), ["overdue", "today", "tomorrow", "day-3"])
        XCTAssertTrue(groups.last?.id.hasPrefix("month-") == true)
        XCTAssertEqual(groups.first?.tasks.map(\.id), ["late"])
    }

    func testDiagnosticsMedianUsesBucketMidpoints() {
        XCTAssertNil(TaskFlowMetrics.medianMilliseconds([]))
        XCTAssertEqual(TaskFlowMetrics.medianMilliseconds([(midpoint: 250, count: 3), (midpoint: 750, count: 1)]), 250)
        XCTAssertEqual(TaskFlowMetrics.medianMilliseconds([(midpoint: 900, count: 5), (midpoint: 300, count: 1)]), 900)
    }

    func testCalendarPreferencesClampOutOfRangeSyncedValues() throws {
        let json = #"{"workStart":23,"workEnd":5,"focusStart":-4,"focusEnd":99,"weekdays":[0,2,9],"hourHeight":0,"bufferMinutes":500}"#
        let settings = try JSONDecoder().decode(CalendarWorkspaceSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.workStart, 22)
        XCTAssertEqual(settings.workEnd, 23)
        XCTAssertEqual(settings.focusStart, 0)
        XCTAssertEqual(settings.focusEnd, 23)
        XCTAssertEqual(settings.weekdays, [2])
        XCTAssertEqual(settings.hourHeight, 60)
        XCTAssertEqual(settings.bufferMinutes, 60)
        XCTAssertFalse(settings.compact)
    }

    func testCalendarContextsAndPreferencesRoundTrip() throws {
        var settings = CalendarWorkspaceSettings()
        settings.workStart = 7
        settings.weekdays = [2, 4, 6]
        settings.hourHeight = 100
        XCTAssertEqual(try JSONDecoder().decode(CalendarWorkspaceSettings.self, from: JSONEncoder().encode(settings)), settings)
        let context = SavedCalendarContext(name: "Focus", mode: "Week", calendarIDs: ["work"], listIDs: ["projects"], query: "Review", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let decoded = try JSONDecoder().decode(SavedCalendarContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(decoded.calendarIDs, context.calendarIDs)
        XCTAssertEqual(decoded.listIDs, context.listIDs)
        XCTAssertEqual(decoded.query, context.query)
        XCTAssertEqual(decoded.start, context.start)
    }

    func testReminderAlertsKeepZeroOffsetAbsoluteDatesAndAdditionalAlerts() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let locationAlarm = EKAlarm()
        locationAlarm.structuredLocation = EKStructuredLocation(title: "Home")
        let decoded = EventKitReminderService.decodeTimeAlarms([
            EKAlarm(relativeOffset: 0), EKAlarm(relativeOffset: -900),
            EKAlarm(absoluteDate: date), locationAlarm
        ])
        XCTAssertEqual(decoded.0, 0)
        XCTAssertEqual(decoded.1, [.relative(minutesBefore: 15), .absolute(date)])
        let absoluteOnly = EventKitReminderService.decodeTimeAlarms([EKAlarm(absoluteDate: date)])
        XCTAssertNil(absoluteOnly.0)
        XCTAssertEqual(absoluteOnly.1, [.absolute(date)])
        XCTAssertNil(EventKitReminderService.decodeTimeAlarms([]).0)
    }

    func testReminderLocationUsesAlarmCoordinatesRadiusAndDeparture() {
        let alarm = EKAlarm()
        let location = EKStructuredLocation(title: "Office")
        location.geoLocation = CLLocation(latitude: 40, longitude: -80)
        location.radius = 250
        alarm.structuredLocation = location
        alarm.proximity = .leave
        let decoded = EventKitReminderService.decodeLocation([alarm])
        XCTAssertEqual(decoded?.latitude, 40)
        XCTAssertEqual(decoded?.longitude, -80)
        XCTAssertEqual(decoded?.radius, 250)
        XCTAssertEqual(decoded?.proximity, .onDeparture)
    }

    func testReminderDraftPreservesNativeFields() {
        var original = task("native-fields")
        original.startDate = Date(timeIntervalSince1970: 1000)
        original.hasStartTime = true
        original.url = URL(string: "https://example.com/task")
        original.alarmOffsetMinutes = 0
        original.additionalAlerts = [.relative(minutesBefore: 60), .absolute(Date(timeIntervalSince1970: 2000))]
        let draft = TaskDraft(task: original)
        XCTAssertEqual(draft.startDate, original.startDate)
        XCTAssertEqual(draft.hasStartTime, true)
        XCTAssertEqual(draft.url, original.url)
        XCTAssertEqual(draft.additionalAlerts, original.additionalAlerts)
        XCTAssertEqual(draft.alarmOffsetMinutes, 0)
        var invalid = draft
        invalid.urlText = "example.com"
        XCTAssertFalse(invalid.hasValidURL)
        invalid.urlText = ""
        XCTAssertTrue(invalid.hasValidURL)
    }

    func testLegacyLocationMetadataDecodesWithoutNewFields() throws {
        let data = Data(#"{"title":"Home","address":"123 Main St"}"#.utf8)
        let location = try JSONDecoder().decode(TaskLocation.self, from: data)
        XCTAssertEqual(location.proximity, .onArrival)
        XCTAssertEqual(location.radius, 100)
    }

    func testEventDraftPreservesRecurrenceAndAllDayDuration() {
        let day = Calendar.current.startOfDay(for: Date())
        var event = CalendarEvent(id: "repeat", calendarID: "work", title: "Review", startDate: day, endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!, isAllDay: true)
        event.recurrence = RecurrenceRule(frequency: .weekly, weekdays: [2, 4], end: .afterOccurrences(10))
        let draft = EventDraft(event: event)
        XCTAssertEqual(draft.recurrence, event.recurrence)
        XCTAssertEqual(draft.endDate, day)
        XCTAssertEqual(EventKitReminderService.eventAlarmOffset([EKAlarm(absoluteDate: day.addingTimeInterval(-900))], start: day), 15)
    }

    func testCommentEditsAndDeletionPreserveNewerComments() async throws {
        let (repository, store, _) = fixture()
        let original = task("comments")
        repository.tasks = [original]
        await repository.addComment("  First  ", to: original)
        let first = try XCTUnwrap(repository.tasks.first?.comments.first)
        await repository.addComment("Second", to: original)
        await repository.editComment(first, text: " Updated ", on: original)
        var comments = try XCTUnwrap(repository.tasks.first?.comments)
        XCTAssertEqual(comments.map(\.text), ["Updated", "Second"])
        XCTAssertNotNil(comments[0].editedAt)
        XCTAssertEqual(comments[0].createdAt, first.createdAt)
        await repository.toggleComment(first, on: original)
        await repository.deleteComment(first, on: original)
        comments = try XCTUnwrap(repository.tasks.first?.comments)
        XCTAssertEqual(comments.map(\.text), ["Second"])
        XCTAssertEqual(store.metadata(for: original.id, cloudID: original.metadataID).comments, comments)
        await repository.addComment(" \n ", to: original)
        await repository.editComment(comments[0], text: " ", on: original)
        XCTAssertEqual(repository.tasks.first?.comments, comments)
    }

    func testOlderCommentsDecodeWithoutEditTimestamp() throws {
        let comment = TaskComment(text: "Existing comment")
        let data = try JSONEncoder().encode(comment)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "editedAt")
        let restored = try JSONDecoder().decode(TaskComment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.text, comment.text)
        XCTAssertNil(restored.editedAt)
    }

    func testMetadataSurvivesStoreAndRepositoryRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (_, _, preferences) = fixture()
        let store = MetadataStore(directory: directory)
        let repository = TaskRepository(preferences: preferences, metadataStore: store)
        let list = TaskList(id: "pinned", title: "Pinned", color: .blue)
        repository.lists = [list]
        repository.togglePinnedList(list)
        repository.saveTag("Important")
        repository.setTagColor(.red, for: "Important")
        let item = task("persisted")
        repository.tasks = [item]
        await repository.addComment("Keep this comment", to: item)
        var metadata = store.metadata(for: item.id, cloudID: item.metadataID)
        metadata.tags = ["Important"]
        store.setMetadata(metadata, for: item.metadataID)

        let reopenedStore = MetadataStore(directory: directory)
        let relaunched = TaskRepository(preferences: preferences, metadataStore: reopenedStore)
        XCTAssertEqual(relaunched.pinnedListIDs, ["pinned"])
        XCTAssertEqual(relaunched.savedTags.map(\.name), ["Important"])
        XCTAssertEqual(relaunched.savedTags.first?.color, .red)
        let restored = reopenedStore.metadata(for: item.id, cloudID: item.metadataID)
        XCTAssertEqual(restored.tags, ["Important"])
        XCTAssertEqual(restored.comments.map(\.text), ["Keep this comment"])

        // Pinning while a list is temporarily unavailable must not erase its saved pin.
        let second = TaskList(id: "second", title: "Second", color: .green)
        relaunched.lists = [second]
        relaunched.togglePinnedList(second)
        let persistedPins = Set(MetadataStore(directory: directory).pinnedListIDs)
        XCTAssertTrue(persistedPins.isSuperset(of: ["pinned", "second"]))
    }

    func testMetadataLoadsLegacyNumericDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let snapshot = MetadataSnapshot(pinnedListIDs: ["legacy"], cloudUpdatedAt: Date())
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("Metadata.json"))
        XCTAssertEqual(MetadataStore(directory: directory).pinnedListIDs, ["legacy"])
    }

    func testLaunchOpensTodayAndClearsStaleDetailSelection() {
        let (repository, _, _) = fixture()
        repository.selectedScope = .completed
        repository.selectedTaskID = "previous"
        repository.resetLaunchSelection()
        XCTAssertEqual(repository.selectedScope, .today)
        XCTAssertNil(repository.selectedTaskID)
    }

    func testTodayAttentionIgnoresTaskBrowserFilters() {
        let (repository, _, _) = fixture()
        var today = task("today")
        today.dueDate = Calendar.current.startOfDay(for: Date())
        var overdue = task("overdue")
        overdue.dueDate = Calendar.current.date(byAdding: .day, value: -1, to: today.dueDate!)
        repository.tasks = [today, overdue, task("no date")]
        repository.selectedScope = .completed
        repository.searchQuery = "unrelated search"
        repository.quickPriorityFilter = .high
        XCTAssertEqual(Set(repository.dueTodayTasks.map(\.id)), ["today", "overdue"])
        XCTAssertEqual(repository.overdueTasks.map(\.id), ["overdue"])
    }

    func testPrioritySortingPlacesUrgentWorkBeforeUnprioritizedTasks() {
        let (repository, _, _) = fixture()
        var high = task("high"); high.priority = .high
        var medium = task("medium"); medium.priority = .medium
        var low = task("low"); low.priority = .low
        repository.tasks = [task("none"), low, high, medium]
        repository.taskSortOption = .priority
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["high", "medium", "low", "none"])
        repository.taskSortDirection = .descending
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["none", "low", "medium", "high"])
    }

    func testCompletedScopeShowsCompletedTasksWithGlobalToggleOff() {
        let (repository, _, _) = fixture()
        repository.tasks = [task("open"), task("done", completed: true)]
        repository.selectedScope = .completed
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["done"])
        XCTAssertEqual(repository.taskCount(for: .completed), 1)
        repository.selectedScope = .all
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["open"])
    }

    func testCommentsUseStableMetadataIDAndPreserveConcurrentAdditions() async {
        let (repository, store, _) = fixture()
        let original = task("one")
        repository.tasks = [original]
        await repository.addComment("First", to: original)
        await repository.addComment("Second", to: original)
        let comments = store.metadata(for: original.id, cloudID: original.metadataID).comments
        XCTAssertEqual(comments.map(\.text), ["First", "Second"])
        await repository.toggleComment(comments[0], on: original)
        let updated = store.metadata(for: original.id, cloudID: original.metadataID).comments
        XCTAssertTrue(updated[0].isResolved)
        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(store.metadata(for: original.id).comments.isEmpty)
    }

    func testSearchMatchesCommentsListNamesAndCalendarNames() {
        let (repository, _, _) = fixture()
        var item = task("Draft", dependencies: [])
        item.comments = [TaskComment(text: "Quarterly review notes")]
        repository.tasks = [item]
        repository.lists = [TaskList(id: "list", title: "Research Projects", color: .blue)]

        repository.searchQuery = "Quarterly review"
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["Draft"])

        repository.searchQuery = "Research Projects"
        XCTAssertEqual(repository.filteredTasks.map(\.id), ["Draft"])

        repository.eventCalendars = [EventCalendar(id: "calendar", title: "Personal Events", color: .purple)]
        repository.calendarEvents = [CalendarEvent(
            id: "event", calendarID: "calendar", title: "Appointment", location: nil, notes: nil,
            url: nil, startDate: Date(), endDate: Date().addingTimeInterval(3600), isAllDay: false
        )]
        repository.searchQuery = "Personal Events"
        XCTAssertEqual(repository.filteredCalendarEvents.map(\.id), ["event"])
    }

    func testPreferencesSurviveRepositoryRecreation() {
        let (repository, store, defaults) = fixture()
        repository.appearanceMode = .light
        repository.appTheme = .slate
        repository.defaultListID = "chosen"
        repository.taskSortDirection = .descending
        repository.taskDensity = .compact
        repository.includeCompletedTasks = true
        let restored = TaskRepository(preferences: defaults, metadataStore: store)
        XCTAssertEqual(restored.appearanceMode, .light)
        XCTAssertEqual(restored.appTheme, .slate)
        XCTAssertEqual(restored.defaultListID, "chosen")
        XCTAssertEqual(restored.taskSortDirection, .descending)
        XCTAssertEqual(restored.taskDensity, .compact)
        XCTAssertTrue(restored.includeCompletedTasks)
    }

    func testDependencyCycleDoesNotIncludeRootOrDuplicateNodes() {
        let (repository, _, _) = fixture()
        let root = task("root", dependencies: ["a", "a"])
        repository.tasks = [root, task("a", dependencies: ["root", "b"]), task("b", dependencies: ["a"])]
        XCTAssertEqual(repository.dependencyChain(for: root).map(\.id), ["a", "b"])
    }

    func testDeepDependencyChainDoesNotRecurse() {
        let (repository, _, _) = fixture()
        repository.tasks = (0..<5000).map { task(String($0), dependencies: $0 < 4999 ? [String($0 + 1)] : []) }
        XCTAssertEqual(repository.dependencyChain(for: repository.tasks[0]).count, 4999)
    }

    func testTaskDraftUsesSelectedListAndFallsBackFromDeletedDefault() {
        let (repository, _, _) = fixture()
        repository.lists = [TaskList(id: "first", title: "First", color: .blue), TaskList(id: "second", title: "Second", color: .green)]
        repository.defaultListID = "deleted"
        repository.selectedScope = .list("second")
        XCTAssertEqual(repository.makeDraft().listID, "second")
        repository.selectedScope = .all
        XCTAssertEqual(repository.makeDraft().listID, "first")
    }

    func testEventDraftPreservesExplicitDatesAndUsesWritableCalendar() {
        let (repository, _, _) = fixture()
        repository.eventCalendars = [EventCalendar(id: "readonly", title: "Read Only", color: .blue), EventCalendar(id: "writable", title: "Writable", color: .green, allowsModifications: true)]
        repository.defaultEventCalendarID = "readonly"
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(7200)
        let draft = repository.makeEventDraft(startDate: start, endDate: end)
        XCTAssertEqual(draft.startDate, start)
        XCTAssertEqual(draft.endDate, end)
        XCTAssertEqual(draft.calendarID, "writable")
        XCTAssertEqual(repository.makeEventDraft(on: start).startDate, start)
    }

    func testEventDraftAvailabilityHandling() {
        let (repository, _, _) = fixture()
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let draft = repository.makeEventDraft(startDate: start, endDate: end)
        XCTAssertEqual(draft.availability, "Busy")

        var event = CalendarEvent(id: "evt1", calendarID: "cal1", title: "Meeting", startDate: start, endDate: end, isAllDay: false, availability: "Free")
        let draftFromEvent = EventDraft(event: event)
        XCTAssertEqual(draftFromEvent.availability, "Free")

        event.availability = "Tentative"
        XCTAssertEqual(EventDraft(event: event).availability, "Tentative")
    }

    func testEventKitAdvancedFeatures() {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let participant = EventParticipant(name: "Jane Doe", email: "jane@example.com", role: "Required", status: "Accepted", isCurrentUser: false)

        let event = CalendarEvent(
            id: "evt2",
            calendarID: "cal1",
            title: "Project Review",
            startDate: start,
            endDate: end,
            isAllDay: false,
            availability: "Busy",
            alarmOffsetMinutes: 15,
            timeZoneIdentifier: "America/New_York",
            organizerName: "John Smith",
            attendees: [participant]
        )

        let draft = EventDraft(event: event)
        XCTAssertEqual(draft.alarmOffsetMinutes, 15)
        XCTAssertEqual(draft.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(event.attendees.count, 1)
        XCTAssertEqual(event.attendees.first?.name, "Jane Doe")
        XCTAssertEqual(event.organizerName, "John Smith")
    }

    func testPerCalendarAvailabilitySupport() {
        let cal1 = EventCalendar(id: "cal1", title: "iCloud Work", color: .blue, allowsModifications: true, supportsAvailability: true)
        let cal2 = EventCalendar(id: "cal2", title: "Local Personal", color: .green, allowsModifications: true, supportsAvailability: false)

        XCTAssertTrue(cal1.supportsAvailability)
        XCTAssertFalse(cal2.supportsAvailability)
    }
}
