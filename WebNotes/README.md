# TaskFlow Notes — iCloud browser prototype

Target page: `https://modcaststudios.app/notes/`.

This is a static browser client. Cloudflare serves editor files; Apple's private CloudKit database stores authenticated users' notes. There is no TaskFlow notes server, Cloudflare database, analytics, or separate TaskFlow account. This code does not make TaskFlow notes appear in Apple's Notes app.

## Current state

Implemented and tested locally:

- Rich text: selected-word bold/italic, headings, bullet/numbered/check lists, quotes, links, normal paragraphs, and keyboard Undo/Redo. Quill 2.0.3 is bundled locally under its BSD license. Note content uses TaskFlow's Markdown-compatible storage.
- Create/edit, folders, search, tags, pinning, Trash/Restore, autosave, refresh, and explicit save indicators.
- Conditional CloudKit writes retain recordChangeTag. Stale saves open a choice of Keep Both, Keep Mine, or Keep Other Version. An edit made during a save is serialized after that save with its new change tag.
- Failed saves preserve a session draft and offer a Markdown download. Reload recovery retains the original version for conflict detection. Sign-out clears note content and account-specific session drafts; unsaved work requires an explicit discard decision.
- A local sample-notes mode exercises the interface without calling iCloud. It is clearly labelled and is cleared on sign-out.
- An opt-in native bridge mirrors one note per CloudKit record, with three-way comparisons against account-specific local checkpoints. Concurrent native edits are preserved as separate Recovered Notes. Deletion records prevent stale copies from silently reappearing.
- Native text updates keep existing drawings, attachment metadata, and version history. Drawing notes can be read and their text edited on the web; drawing creation, deletion, and restoration stay in TaskFlow for this prototype.

The site is deployed at https://modcaststudios.app/notes with production CloudKit configuration. The user reported successful live authentication and native/browser sync after deploying the production schema. Debug builds use Development; Release builds use Production and enable the bridge. Automated browser tests use a local fake CloudKit service, not authenticated accounts; automated tests do not independently establish account isolation or cross-browser release readiness. The checked-in browser config intentionally has a blank API token; configured deployment packages use a local token file.

## Local preview

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory WebNotes
```

Open `http://127.0.0.1:8765/` and choose **Explore with sample notes**. iCloud will show a preparation message until developer configuration is supplied.

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

## Cloudflare preparation

Package the preview assets:

```sh
python3 WebNotes/build.py
```

For a configured DEVELOPMENT staging package:

```sh
python3 WebNotes/build.py --environment development --token-file /absolute/path/to/local-token.txt
```

For production, AFTER the live validation checklist passes:

```sh
python3 WebNotes/build.py --environment production --token-file /absolute/path/to/local-token.txt
```

Output is `.build/WebNotes/notes/`, with `.build/WebNotes/_headers`. Merge the `notes` directory into the existing site's static build output. Merge the header rules with the site's existing `_headers`; do not replace existing site files or publish this directory as the entire existing Pages project. The site's build pipeline and project name still need to be identified in Cloudflare.

The supplied headers include CSP, no-referrer, no-sniff, no-store and noindex. Verify real Apple authentication under that CSP on staging. Cloudflare Pages applies `_headers` to static assets; a Worker or Pages Function that handles these routes must set equivalent response headers itself. Check existing global header/redirect rules for conflicts and ensure `/notes/` serves this editor rather than the site's SPA fallback. `.mjs` assets must be served with a JavaScript MIME type.

Cloudflare stores only these static files. No Cloudflare API endpoint receives note content. Do not add note analytics, HTML error reporting, or note bodies to server logs.

## Live validation before public release

1. Same account: native create → web read/edit → native read; web create → native read/edit → web read.
2. Different accounts: verify each user sees only their private notes.
3. Native and browser simultaneous edits, two browser tabs, edit versus delete, and retry after record-change conflicts.
4. Failed saves, expired sessions, full iCloud storage, offline draft recovery, signing out on a shared computer, and a reopened tab.
5. Existing notes migration, older installed TaskFlow versions, folders/tags/pins, mixed formatting, Unicode, large notes, and attachment/drawing retention.
6. Safari, Chrome and Edge on macOS/Windows, phone layout, keyboard controls and large text.
7. Privacy headers, static asset routing, schema deployment, and signed app entitlements.

Only after those checks: deploy the CloudKit schema to production, package with the production web token, preview the merged Cloudflare site, approve public deployment, and enable the app's release setting. The Notes menu then exposes **Open Notes in Browser**. Background delivery is not promised: app updates arrive through its existing sync/foreground flow, and an open browser refreshes on focus and periodically.

Future work after this milestone: incremental CloudKit change fetching for large libraries, broader Markdown compatibility, browser attachment uploads/drawing tools, native Trash UI aligned with browser Trash, and physical-device/background verification. These are deliberately outside the initial authentication-and-sync prototype.

## Automated checks

```sh
node --test WebNotes/tests/core.test.mjs
```

Browser tests in `tests/browser.cjs` and `tests/conflicts-browser.cjs` use Playwright and an isolated headless Chrome; their runtime package path is specific to this workspace and can be adapted to a locally installed Playwright. No real iCloud credentials are used.

Native regression tests are in `TaskFlowTests/TaskRepositoryTests.swift`. Validation logs and screenshots are in `.build/validation/web-notes-*`.

References: [Apple CloudKit JS](https://developer.apple.com/documentation/cloudkitjs), [Apple web authentication](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html), [Quill](https://quilljs.com/docs/quickstart), [Cloudflare static headers](https://developers.cloudflare.com/pages/configuration/headers/).
