# Native iOS UI phases

## Phase 1 — Navigation and details
- Retain system tabs, toolbar materials, and the existing iPad split navigation.
- Present compact task details full screen with system dismissal controls.
- Notes open a reading page with native Back, Edit, Share, and Pin actions.
- Note details preserve formatted content, drawings, tags, and attachment links.

## Phase 2 — Editing and gestures
- Retain grouped editing forms, native Save/Cancel, and in-place reminder editing.
- Add task Reschedule swipe; label completion/reopening correctly.
- Add confirmation before bulk deletion, with batch undo.
- Retain task Select mode and its Complete, Move, Reschedule, and Tag actions.
- Add note Pin/Unpin swipe; disable destructive full swipes.

## Phase 3 — Search and reversibility
- Replace task-only Search tab with category-scoped Tasks, Events, Notes, Comments, Lists, and Tags search.
- Save recent searches and provide Clear Filter and no-results states.
- Link results to their task, event, note, comment, or list.
- Add reversible note creation, editing, pinning, and deletion.
- Add task redo for existing-task changes. Deleted-task restoration retains existing undo behavior; deletion redo is intentionally unavailable because EventKit may assign a new identifier.
- Search uses currently loaded reminder and calendar data; it does not fetch an unlimited calendar history.

## Phase 4 — Sharing, iPad, and accessibility
- Use native ShareLink for task, event, and note summaries.
- Enable dropping dragged task IDs onto reminder lists to move tasks.
- Preserve existing iPad sidebars, split details, and native text-editing shortcuts.
- Add note creation and undo/redo keyboard actions.
- Add VoiceOver completion/flag actions and visible pinned-note identity.
- Use semantic text styles and native controls; system materials respect platform accessibility settings.

## Verification
- Simulator build and regression tests required after integration.
- Manual device checks remain: compact and regular width, larger text, VoiceOver, hardware keyboard, and drag-and-drop.


## Event deletion workflow

- Event details now expose Delete Event for writable calendars, with confirmation, progress, and retryable errors.
- Recurring events offer This Event Only and This and Future Events. Exact occurrence resolution uses the original start date; past occurrences are preserved for future-only deletion.
- The system Calendar editor now reports Cancel, Save, and Delete separately. The outer TaskFlow editor closes after the system sheet finishes dismissing, including when deletion clears the native identifier.
- Confirmed deletion publishes occurrence identity, removes stale calendar content, clears split-view selection, dismisses presented details, and invalidates calendar caches.
- Countdown cleanup and stale event undo cleanup apply only to affected occurrences. Unrelated undo state remains available.
- Missing events already removed elsewhere are handled as completed deletion. Permission or storage failures leave the detail screen available for retry.
- Regression coverage checks deletion scopes, repository selection-cleanup signals, stale and unrelated undo state. The Calendar permission-denial test is conditional on simulator authorization. Live device modal dismissal and signed Calendar-account deletion still require hands-on verification.
