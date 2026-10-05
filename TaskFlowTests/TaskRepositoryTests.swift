import XCTest
import EventKit
import CoreLocation
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
