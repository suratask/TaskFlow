# WebNotes code review — October 7, 2026

Scope: static editor, CloudKit provider, native per-note bridge, authentication lifecycle, checkpoints, and related regression tests. Changes are in the workspace; the live site and installed iPhone app have not been updated by this review.

## Findings fixed

- High: refresh results could replace edits typed while the CloudKit list request was in flight. Refresh now checks session and editor revision before applying results.
- High: late save/list/conflict requests could update UI after account sign-out. Session generations invalidate old requests; sign-out clears editor, filters, preview, drafts, and pending rendering. Switching between CloudKit and sample mode also invalidates old initialization.
- Medium: sign-in notification and explicit connection both initialized the workspace, duplicating authentication, list requests, and draft recovery. They now share one authentication promise and one workspace initializer.
- Medium: selecting a stale sidebar item after flushing its draft could reopen the pre-save version. Selection resolves the item against the current notes list after save.
- Medium: repeated conflict-resolution clicks could create duplicate recovered copies. Resolution is guarded; Keep Mine also retains the remote drawing-presence flag.
- Medium: missing readiness yielded an unhelpful generic error. UNKNOWN_ITEM/NOT_FOUND now instruct the user to sync the updated native app.
- Medium: broken continuation metadata could silently truncate the list or repeatedly fetch the same page. Invalid or repeated pagination markers now fail explicitly.
- Medium: native development and production used the same account checkpoint path. Checkpoints now include the environment. Old unscoped files are retained but unused; the first new sync can conservatively create recovered notes where local and remote versions differ.
- Medium: native recovered copies could lose drawing data stripped from the web projection. Native drawing/history data is now retained from the local source when applying the recovered copy.
- Performance: hidden previews were rebuilt on every keystroke, sidebar snippets contained whole note bodies, and UI rendering was repeated within a frame. Hidden previews are skipped, snippets are capped at 240 characters, and editing renders are coalesced by animation frame.
- Performance: native note sync decoded the same remote projections twice, constructed date formatters for each date field, and rescanned/decoded unchanged notes. Remote projections and per-decode date formatters are reused; unchanged live notes bypass apply.

## Validation

- 14 Node core tests passed, including readiness and malformed-pagination regressions.
- Browser editor suite passed: formatting, safe preview, pin, trash/restore, search, mobile layout, sign-out clearing.
- Fake-CloudKit reliability suite passed: conflicts, Keep Both, edits during save, typing during refresh, failed-save retention, reload recovery, and account expiry during an in-flight save.
- Six native WebNotes tests passed on the iPhone simulator, including concurrent edits, deletion conflicts, record validation, drawing/attachment retention, and recovered drawing retention.
- Browser update ZIP is verified and matches the deployed root names notes-app.mjs and notes-core.mjs. The production configuration token is not changed or included.

Automated browser tests use a fake CloudKit database; these checks do not independently validate live account isolation or Apple authentication. Performance changes remove specific redundant work; no production-library benchmark was run.
