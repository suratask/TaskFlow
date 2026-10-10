# TaskFlow Notes on the web

Live at `https://modcaststudios.app/notes`.

A static browser client. Apple's private CloudKit database (container `iCloud.com.surratt.TaskFlow`) stores each signed-in user's notes; the page talks to it directly with CloudKit JS. There is no TaskFlow notes server, no Cloudflare database or analytics, and no separate TaskFlow account.

## How it fits together

- **Records:** one `TaskFlowWebNote` record per note. `payload` is the app's `QuickNote` JSON without drawing or history (`CloudWebNote` in `TaskFlow/Services/CloudNotesSyncService.swift`); `isDeleted` and `hasDrawing` are record fields. The app publishes `TaskFlowWebNotesReady` once it has synced, and the page waits for it.
- **The page is shared with Sebastian's web notes.** `shared/` (page code, HTML template, styles, editor, incremental listing, Quill and the build helper) is an identical copy of the Sebastian repo's `WebNotes/shared/`, which is the source of truth. Don't edit it here: change it in Sebastian's repo, run `python3 WebNotes/sync-shared.py` there, then test and deploy both pages. `tests/shared-copy.test.mjs` fails while the copies differ.
- **TaskFlow's own parts:** `core.mjs` maps TaskFlow's records to the shared note shape (`body`, `pinnedAt`, `deletedAt`, `modifiedAt`) and provides its badges; `profile.json` names the app and turns on folders (and off permanent delete); `theme.css` holds the blue colours; plus icons, manifest, `build.py` and `deploy/`.
- **Syncing:** each sync lists only each note's name and change tag, then downloads in full just the notes that are new or changed.
- **Text formats:** `text` + `format` (plain, bullets, checklist, quote, markdown) are shown as Markdown in the editor. A note whose text isn't edited keeps its `text` and `format` byte for byte; an edited text is saved as Markdown.
- **Folders, tags and pins** edit the payload directly. **Tag colours** match the app: the colours chosen in TaskFlow come from its metadata record (`TaskFlowMetadataSnapshot` → `savedTags`, read every ten minutes because the record holds all app metadata), others use the app's default (`MetadataSnapshot.defaultColor(for:)`).
- **Drawing notes** can be edited here (the app keeps the drawing), but not moved to Trash: trashing from the web would lose the drawing in the app.
- **No permanent delete on the web.** The app uploads its copy again when a record disappears from iCloud, so Empty Trash / Delete Permanently would not stick. Trash and Restore work.
- **Stability** (same as Sebastian's page): background sync never replaces the note being edited (a banner offers the newer version); saves never rewrite the editor; failed saves retry with backoff; hiding or closing the tab saves at once; unsaved changes are backed up in localStorage and recovered after a crash; an expired Apple session shows sign-in in place; idle tabs reload onto a new deploy (`/notes/version.json`).
- Not on the web: adding images or files, drawing, history, resolving notes and linking to tasks or events (shown as badges).

## One-time developer setup: CloudKit

Use the existing container `iCloud.com.surratt.TaskFlow`, DEVELOPMENT environment first. Configure the following record types in the default zone. All runtime operations use the PRIVATE database; do not grant public note access.

| Record type | Fields |
| --- | --- |
| `TaskFlowWebNote` | `noteID` STRING, `payload` STRING, `schemaVersion` INT64, `isDeleted` INT64, `hasDrawing` INT64 |
| `TaskFlowWebNotesState` | `schemaVersion` INT64 |

Make the system `recordName` field queryable for `TaskFlowWebNote`; the app and web editor fetch all note records with pagination. Validate the schema in development before deploying it to production.

Record IDs are `TaskFlowWebNote-<UPPERCASE-UUID>`. The readiness record is `TaskFlowWebNotesReady`, schema version 1. The app writes readiness only after the native merged note state is persisted. The browser refuses to open notes without that record.

Create a CloudKit web API token, restricting allowed origins to the actual staging domain and `https://modcaststudios.app`. Use Apple's CloudKit authentication, not a general Sign in with Apple token or a server-to-server key. Users never create or paste API tokens. Keep the token out of chat; packaging accepts a local file. The website's container API token identifies the client and is necessarily included in its JavaScript; authenticated private-database access still requires each user's Apple session.

Debug builds enable the native WebNotes bridge for DEVELOPMENT testing. Release builds still use `TaskFlowWebNotesEnabled` in `TaskFlow/Resources/Info.plist`, which is now true for the production rollout. `TaskFlowWebNotesURL` is already the intended final HTTPS page. Sign a Debug build with the app's existing CloudKit entitlements, verify its signed CloudKit environment is Development, open it using a test iCloud account, and run Sync Now. Verify per-note records and readiness before using the browser. The unsigned simulator unit suite tests pure reconciliation rather than live CloudKit operations.

The first bridge retains legacy snapshot syncing for compatibility; this is a staged migration, not removal of the legacy store. Account checkpoints are saved under Application Support/WebNoteSync/<environment> only after native persistence. Environment separation prevents development baselines from being reused in production. Older unscoped checkpoints are retained but not loaded; the first sync after this update can conservatively create recovered copies when local and remote notes differ. Older clients can continue writing legacy data; overlapping edits are recovered rather than automatically discarded. Live mixed-version testing is required before general release.

## Build and publish

The page is its own Cloudflare Worker, `taskflow-notes`, on the routes `modcaststudios.app/notes*` and `www.modcaststudios.app/notes*`. The rest of modcaststudios.app is the `modcast-studios` Worker, which another tool redeploys in full; a route runs ahead of the site's Worker, so those deploys can't replace or break this page.

```sh
python3 WebNotes/build.py --environment production --token-file "taskflow-notes-token Production.txt"
cd WebNotes/deploy && npx wrangler@4.40.0 deploy
```

- `build.py` writes `.build/WebNotes/site/notes.html` (the page, served at `/notes`) and `.build/WebNotes/site/notes/` (`core.mjs`, `theme.css`, icons, `config.js`, `version.json` and `shared/`, served at `/notes/...`). The page uses absolute asset paths.
- The token file lives next to the repository and is excluded in `.git/info/exclude`. Never commit it or paste it into chat.
- `deploy/worker.js` serves `/notes`, answers `/notes/` with a 301 to `/notes` (the direction browsers have long cached), returns 404 for anything else under the route (such as the old flat `/notes-*.mjs` files), sends `www` to `modcaststudios.app` (iCloud sign-in is registered for that origin only), and adds the CSP, no-store and noindex headers plus `X-Served-By: taskflow-notes`. Check with `curl -sI https://modcaststudios.app/notes`.
- `npx wrangler login` once per Mac. Right after a deploy some requests can return 500 for about a minute.

## Local preview

```sh
python3 WebNotes/build.py && python3 -m http.server 8765 --bind 127.0.0.1 --directory .build/WebNotes/site
```

Open `http://127.0.0.1:8765/notes.html` and choose **Try it with sample notes**.

## Automated checks

```sh
cd WebNotes && npm test
```

The tests in `tests/core.test.mjs` pin the record mapping against payloads as the app writes them: untouched text and formats, the app's projection (no drawing, history or edit stamp), the drawing rule, tag colours from the app's own formula, folders, conflicts and CloudKit errors. Native tests are in `TaskFlowTests/`.

References: [Apple CloudKit JS](https://developer.apple.com/documentation/cloudkitjs), [Quill](https://quilljs.com/docs/quickstart), [Cloudflare Workers routes](https://developers.cloudflare.com/workers/configuration/routing/routes/).
