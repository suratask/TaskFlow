# Performance improvements

## Phase 1: Refresh and persistence

- Foreground and EventKit reloads reconcile external data without reassigning local notes, tags, pinned order, and settings. Explicit refresh retains the full reload path.
- Read-only reminder requests share an in-flight fetch. Mutations request fresh data; generation checks prevent slower older fetches from publishing over newer results.
- Completion, flag, and status changes publish an immediate row update after a successful EventKit save, then reconcile with Reminders.
- Note autosave and draft recovery submit ordered writes on the main actor; JSON encoding and atomic replacement run on a serial utility queue. Explicit Save and lifecycle flushes use the same queue and wait for durability.
- Note-only metadata changes compare note records directly instead of encoding the entire metadata snapshot twice to calculate cloud revisions. Record edits and deletion timestamps are preserved.
- Metadata JSON retains compatible dates and sorted keys while omitting pretty-print whitespace.

## Phase 2: Lists, search, and rendering

- Filtered/sorted task results and grouped task lists cache their latest result, invalidating on data, scope, search, settings, and relevant time changes.
- Notes and comments cache filtered/sorted results using data revisions and all active filters.
- Linked-note URLs and parent-to-child task relationships are indexed, avoiding repeated scans for each note or visible task row.
- Parsed Markdown/checklists, rendered plain text, and in-note search results use bounded NSCache storage keyed by source content. Edited text, format, titles, and queries invalidate results naturally.

## Phase 3: Calendar, widgets, attachments, and memory

- Calendar navigation reuses month-sized fetches in a bounded 18-month cache. External reloads, calendar selection changes, and event mutations invalidate cached events. The existing window around today remains available for other app features.
- Notes widget serialization runs on a serial utility queue. Unchanged shared projections are skipped; note-only saves avoid rebuilding unrelated task widget metadata.
- Notification request construction reuses results until relevant task fields, available slots, time zone, or the next expiry change. Pending system requests are still inspected and reconciled.
- Unchanged Today Live Activity publications are skipped, with day and enabled-state changes included in invalidation.
- Drawing thumbnails use a memory-pressure-aware cache and a maximum 720-pixel longest edge.
- File and photo imports run through the background writer. File copies avoid loading the whole source into RAM; security-scoped access covers the copy. Save controls wait while imports are pending.
- Note history retains up to 50 checkpoints and an approximately 4 MiB retained payload budget. The newest checkpoint is retained even when a single drawing exceeds that budget.

## Validation

App and widget builds succeeded. All 108 repository tests passed on the iOS simulator. New regression coverage includes draft discard/write ordering, newer explicit saves superseding autosave, failed draft write retries, cloud note edit/deletion revisions, cache invalidation, attachment byte preservation, and subtask reparenting/deletion.

The simulator benchmark averages below measure repeated operations, not before/after app launch speed. Uncached search changes only the title between iterations to invalidate the match cache while keeping the same searchable body. Warm benchmarks are short enough that timing variance is substantial; do not treat ratios as device-wide speedups.

| Workload | Average measured batch |
| --- | --- |
| 20 uncached searches in a 2,000-item note | 414.960 ms |
| 20 cached searches in the same 2,000-item note | 0.060 ms |
| 100 cached filter/sort lookups in a 10,000-task list | 0.169 ms |

## Device profiling still required

Points of Interest intervals are available for repository reloads, calendar fetching, and task filtering. Use Instruments on a physical device with identical datasets and repeat cold launch, foreground resume, scrolling, long-note typing/dictation, and calendar navigation. Record time to usable content, main-thread stalls, peak memory, and energy consumption before establishing device performance budgets. No physical-device launch, scrolling, or battery improvement percentages have been measured in this session.
