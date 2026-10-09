# TaskFlow code review — October 7, 2026

Scope: app models and repository, EventKit integration, persistence and CloudKit merge paths, notification/background execution, shared intents and widget actions, share extension, Today planning, media previews, and note/editor code. Existing uncommitted feature work was preserved. This is a source review and simulator validation, not a guarantee that every possible defect has been discovered.

## Findings fixed

| Issue | Impact | Fix |
| --- | --- | --- |
| All-day upcoming episode drafts used an exclusive end date | EventKit's inclusive-draft conversion added another day, making releases span two days | Keep the release draft's start and end on the same day; retain 30 minutes for timed releases |
| Share type changed before attachment loading completed | Save could remain disabled despite valid content | Refresh Save availability after loading independently of automatic type selection |
| Text captures ignored optional title and note | User-entered review text was discarded for Task, Event, and Note | Include reviewed title, shared content, and note in the saved text |
| Task/Event shares used one pending dictionary; Notes used a shared mutable array | Later shares could overwrite pending captures or race imports | Store new text shares in separate atomic JSON files; retain legacy import support; stable IDs and successful persistence govern Note acknowledgements |
| Focus Next's overdue bonus grew without a limit | Old tasks could outrank pinned priorities; non-finite dates could trap in numeric conversion | Cap timed urgency at 120 points and reject non-finite intervals before conversion |
| Event alarm offsets multiplied integers before conversion | Extreme offsets could overflow and crash | Convert to floating-point seconds before multiplication |
| List previews downloaded and decoded full-resolution images | Oversized responses and artwork caused avoidable memory pressure | Stream downloads with an 8 MB limit, cancellation checks, HTTPS response validation, and ImageIO downsampling to 640 pixels; cache resized JPEGs |
| Schedule sorting repeatedly decoded episode JSON; alerts repeatedly sorted/searched it | Avoidable CPU work on large watch lists | Decode eligible shows once before sorting; group ordered episodes once and reuse each group's first episode |

## Regression coverage

Added tests for bounded overdue ranking including a non-finite date, thumbnail downsampling and malformed-image rejection, and independent text-share files with selective acknowledgement. Existing tests exercise repository mutations, Undo, metadata merge/persistence, notes, scheduling, media matching, and widget/notification episode actions.

Final validation: **190 tests executed, one skipped, zero failures**; app, widget, and share-extension targets compiled successfully. `git diff --check` passed. ImageIO emits diagnostics for the deliberately malformed-image regression fixture; that test passed by rejecting the data.

Validation logs are in `.build/validation/app-review-tests.log` and `.build/validation/app-review-final-tests.log`.

## Verification limits

Live CloudKit accounts, real provider share sheets, physical-device memory profiling, native widget interaction, and discretionary iOS background delivery were not exercised by the simulator unit suite. Text Task/Event captures continue to open Quick Capture for review when the app next imports pending shares. Standard user cancellation after a capture is presented retains the existing review-flow behavior.
