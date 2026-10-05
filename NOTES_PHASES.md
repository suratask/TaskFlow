# Notes implementation phases

All four phases are implemented. Each phase passed the repository test suite before proceeding.

1. Reliability — autosave for existing notes, recoverable drafts including dictation, and version history with restore. Validated with 89 passing tests.
2. Actionable checklists — create tasks with reminder list, due date, priority, and a source-note link; drag ordering, nesting, completed-item controls, and collapsible sections. Validated with 91 passing tests.
3. Navigation and content — folders, tag and smart-collection filters, highlighted in-note search with previous/next matches, and Markdown formatting with mixed paragraphs and nested checklists. Validated with 94 passing tests.
4. System integration — configurable pinned-note/checklist widgets with interactive checkboxes; Create Note, Find Notes, Append to Note, and Open Note Shortcuts. Validated with 96 passing tests and generated App Intents metadata.

## Behavior

- Existing notes autosave after a short debounce. New notes remain recoverable drafts until Save; closing keeps the draft, while Discard Draft removes it.
- Draft recovery is stored locally on the device, independently of cloud note metadata.
- Version history retains up to 50 snapshots, coalescing ordinary edits into approximately one-minute checkpoints. Restoring a version first preserves the current note.
- Creating a task copies the checklist item and includes a link back to its source note. Task completion and note checkmarks remain independently editable.
- Rich Text uses Markdown editing and formatted previews, including headings, bold, links, and nested checklists.
- Checklist visibility, section collapse, and completed-item ordering are presentation controls; they do not delete source content.
- Widget checkbox actions validate the original source line before applying changes, preventing stale widgets from checking a different item after edits or reordering.
- Old saved notes continue decoding with defaults for the new fields.

## Remaining verification

Simulator automated tests and app/widget builds passed. Hands-on checks of Control Center, Shortcuts execution, dictation interruptions, widget interaction, drag gestures, and visual layout on physical devices remain outstanding.


## URL saving and attachment previews

- Save and Close commit a valid URL entered in the attachment field even when the plus button has not been tapped. Keyboard Submit also adds the link, with duplicate detection and inline validation errors.
- Unfinished URL input is retained in local draft recovery. URL-only notes can be saved. Older recovery drafts remain decodable.
- URL attachments resolve their web address rather than requiring a local file path. Bare web URLs in note content are tappable alongside Markdown links.
- Metadata sync publishes merged notes before binary file transfers, so an unavailable file does not hide synced text or links.
- Editor and full-note attachment cards show website titles/images where available, photo/document thumbnails, and full Quick Look or in-app Safari previews. Missing local files expose Retry Sync.
- Preview caches are bounded and concurrent preview generation is limited to four requests. Metadata fetch failures retain the original actionable link.
- Validation: 114 tests pass, including URL relaunch persistence, metadata merge between stores, pending URL recovery, older draft decoding, and link detection. Actual iCloud transport across signed devices and visual interaction checks remain unverified.


## iPad note editor

New notes, recovered drafts, dictation capture, and editing an existing note now present the editor as a full-screen page on iPad, including compact Split View windows. Save and Close remain in the navigation toolbar. iPhone retains sheet presentation.


## Folder picker and moving notes

The note editor uses a navigation picker for existing note/draft folders and Unfiled, with a New Folder action. A new folder is retained when the note is saved or moved. Existing notes can be moved from a list swipe action, a long-press menu, or the full note’s folder toolbar button. Moves read the latest saved note, preserve its content and attachments, and use the normal save, history, undo, and cloud-sync path. Folder names are trimmed and existing names are reused regardless of capitalization.
