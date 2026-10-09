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
    func commentDraft(for taskID: String) -> String {
        preferences.string(forKey: "TaskFlow.commentDraft.\(taskID)") ?? ""
    }
    func saveCommentDraft(_ text: String, for taskID: String) {
        let key = "TaskFlow.commentDraft.\(taskID)"
        if text.isEmpty { preferences.removeObject(forKey: key) }
        else { preferences.set(text, forKey: key) }
    }
    func makeEventDraft(on date: Date? = nil, startDate: Date? = nil, endDate: Date? = nil) -> EventDraft {
        let start = startDate ?? date ?? Date()
        let end = endDate.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        let calendarID = writableEventCalendars.first(where: { $0.id == defaultEventCalendarID })?.id
            ?? writableEventCalendars.first?.id ?? ""
        return EventDraft(calendarID: calendarID, startDate: start, endDate: end)
    }
    func makeDraft(parentID: String? = nil) -> TaskDraft {
        let contextID: String?
        if let parentID, let parent = currentTask(id: parentID) {
            contextID = parent.listID
        } else if case .list(let id) = selectedScope {
            contextID = id
        } else {
            contextID = nil
        }
        let listID = lists.first(where: { $0.id == contextID })?.id
            ?? lists.first(where: { $0.id == defaultListID })?.id
            ?? lists.first?.id ?? ""
        var d = TaskDraft(listID: listID)
        d.parentID = parentID
        return d
    }
    func recordNoteUndo(_ note: QuickNote?, id: UUID, message: String) {
        noteUndo = NoteUndo(noteID: id, previous: note, message: message)
        noteRedo = nil
    }
    func restoreNote(_ action: NoteUndo, isRedo: Bool = false) {
        let inverse = NoteUndo(noteID: action.noteID, previous: quickNotes.first { $0.id == action.noteID }, message: action.message)
        quickNotes.removeAll { $0.id == action.noteID }
        if let previous = action.previous { quickNotes.insert(previous, at: 0) }
        metadataStore.quickNotes = quickNotes
        if isRedo { noteUndo = inverse; noteRedo = nil }
        else { noteRedo = inverse; noteUndo = nil }
    }
    func toggleNotePin(_ note: QuickNote) {
        guard let index = quickNotes.firstIndex(where: { $0.id == note.id }) else { return }
        recordNoteUndo(quickNotes[index], id: note.id, message: "Pin Note")
        quickNotes[index].isPinned.toggle()
        metadataStore.quickNotes = quickNotes
    }
    var noteFolders: [String] {
        Array(Set((quickNotes.map(\.folder) + noteDrafts.map { $0.note.folder })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    @discardableResult
    func moveNote(id: UUID, toFolder folder: String) -> Bool {
        guard var note = quickNotes.first(where: { $0.id == id }) else {
            errorMessage = "That note is no longer available."
            return false
        }
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        note.folder = noteFolders.first { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
        return saveNoteSnapshot(note)
    }
    @discardableResult
    func saveNoteSnapshot(_ note: QuickNote, forceCheckpoint: Bool = false) -> Bool {
        var notes = quickNotes
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var comparable = note
            comparable.versions = notes[index].versions
            comparable.updatedAt = notes[index].updatedAt
            guard comparable != notes[index] else { return true }
            recordNoteUndo(notes[index], id: note.id, message: "Edit Note")
            notes[index] = note.versioned(replacing: notes[index], forceCheckpoint: forceCheckpoint)
        } else {
            recordNoteUndo(nil, id: note.id, message: "Create Note")
            notes.insert(note, at: 0)
        }
        metadataStore.quickNotes = notes
        guard metadataStore.persistenceError == nil else { errorMessage = metadataStore.persistenceError; return false }
        quickNotes = metadataStore.quickNotes
        return true
    }
    /// Autosave uses the same ordering and history as explicit Save, with encoding
    /// and atomic file replacement performed by the serial persistence worker.
    func autosaveNoteSnapshot(_ note: QuickNote) async -> Bool {
        var notes = quickNotes
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return false }
        var comparable = note
        comparable.versions = notes[index].versions
        comparable.updatedAt = notes[index].updatedAt
        guard comparable != notes[index] else { return true }
        recordNoteUndo(notes[index], id: note.id, message: "Edit Note")
        notes[index] = note.versioned(replacing: notes[index])
        let saved = await metadataStore.saveQuickNotesAsync(notes)
        if saved { quickNotes = metadataStore.quickNotes }
        else { errorMessage = metadataStore.persistenceError }
        return saved
    }
    func saveNoteDraft(_ draft: NoteEditorRecovery) -> Bool {
        draftWriteGeneration &+= 1
        var drafts = noteDrafts.filter { $0.id != draft.id }
        drafts.insert(draft, at: 0)
        do { try metadataStore.writeNoteDrafts(drafts); noteDrafts = drafts; return true }
        catch { errorMessage = "Could not recoverably save this draft: " + FriendlyError.message(for: error); return false }
    }
    func discardNoteDraft(id: UUID) {
        draftWriteGeneration &+= 1
        let drafts = noteDrafts.filter { $0.id != id }
        do { try metadataStore.writeNoteDrafts(drafts); noteDrafts = drafts }
        catch { errorMessage = FriendlyError.message(for: error) }
    }
    func restoreNoteVersion(noteID: UUID, revision: NoteRevision) {
        guard let current = quickNotes.first(where: { $0.id == noteID }) else { return }
        var restored = revision.snapshot
        restored.id = noteID
        restored.isPinned = current.isPinned
        _ = saveNoteSnapshot(restored, forceCheckpoint: true)
    }
    func addQuickNote(title: String, text: String, tags: [String], linkedTaskID: String?, linkedEventID: String? = nil, format: QuickNoteFormat = .plain, layout: QuickNoteLayout = .standard, drawingData: Data? = nil, attachments: [TaskAttachment] = []) async {
        let note = QuickNote(title: title, text: text, tags: tags, linkedTaskID: linkedTaskID, linkedEventID: linkedEventID, format: format, layout: layout, drawingData: drawingData, attachments: attachments)
        recordNoteUndo(nil, id: note.id, message: "Create Note")
        var current = quickNotes
        current.insert(note, at: 0)
        quickNotes = current
        metadataStore.quickNotes = current
    }
    func updateQuickNote(_ note: QuickNote, title: String, text: String, tags: [String], linkedTaskID: String?, linkedEventID: String?, format: QuickNoteFormat, layout: QuickNoteLayout, drawingData: Data?, attachments: [TaskAttachment]) async {
        var current = quickNotes
        if let idx = current.firstIndex(where: { $0.id == note.id }) {
            recordNoteUndo(current[idx], id: note.id, message: "Edit Note")
            var updated = current[idx]
            updated.title = title
            updated.text = text
            updated.tags = tags
            updated.linkedTaskID = linkedTaskID
            updated.linkedEventID = linkedEventID
            updated.format = format
            updated.layout = layout
            updated.drawingData = drawingData
            updated.attachments = attachments
            current[idx] = updated.versioned(replacing: current[idx])
            quickNotes = current
            metadataStore.quickNotes = current
        }
    }
    func setNoteChecklistItem(noteID: UUID, itemID: Int, checked: Bool) {
        guard var note = quickNotes.first(where: { $0.id == noteID }), [.checklist, .markdown].contains(note.format) else { return }
        note.text = NoteChecklist.replacing(note.text, itemID: itemID, checked: checked)
        _ = saveNoteSnapshot(note)
    }
    func deleteQuickNote(_ note: QuickNote) async {
        guard let existing = quickNotes.first(where: { $0.id == note.id }) else { return }
        recordNoteUndo(existing, id: note.id, message: "Delete Note")
        var current = quickNotes
        current.removeAll { $0.id == note.id }
        quickNotes = current
        metadataStore.quickNotes = current
    }
    func addComment(_ text: String, to task: TaskItem) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let comment = TaskComment(text: text)
        var updated = currentTask(id: task.id) ?? task
        updated.comments.append(comment)
        updateTaskInMemory(updated)
        var meta = metadataStore.metadata(for: task.id, cloudID: task.metadataID)
        meta.comments = updated.comments
        metadataStore.setMetadata(meta, for: task.metadataID)
    }
    func toggleComment(_ comment: TaskComment, on task: TaskItem) async {
        var updated = currentTask(id: task.id) ?? task
        if let idx = updated.comments.firstIndex(where: { $0.id == comment.id }) {
            updated.comments[idx].isResolved.toggle()
            updateTaskInMemory(updated)
            var meta = metadataStore.metadata(for: task.id, cloudID: task.metadataID)
            meta.comments = updated.comments
            metadataStore.setMetadata(meta, for: task.metadataID)
        }
    }
    func editComment(_ comment: TaskComment, text: String, on task: TaskItem) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = currentTask(id: task.id) ?? task
        guard let index = updated.comments.firstIndex(where: { $0.id == comment.id }),
              updated.comments[index].text != text else { return }
        updated.comments[index].text = text
        updated.comments[index].editedAt = Date()
        saveComments(on: updated)
    }
    func deleteComment(_ comment: TaskComment, on task: TaskItem) async {
        var updated = currentTask(id: task.id) ?? task
        updated.comments.removeAll { $0.id == comment.id }
        saveComments(on: updated)
    }
    func saveComments(on task: TaskItem) {
        updateTaskInMemory(task)
        var meta = metadataStore.metadata(for: task.id, cloudID: task.metadataID)
        meta.comments = task.comments
        metadataStore.setMetadata(meta, for: task.metadataID)
    }
}
