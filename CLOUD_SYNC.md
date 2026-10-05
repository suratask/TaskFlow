# Cloud metadata and settings sync

TaskFlow uses the signed-in user's private `iCloud.com.surratt.TaskFlow` database. Native events and reminders continue to sync through their calendar accounts; TaskFlow does not create duplicate native records in CloudKit.

## Coverage

The existing TaskFlowMetadata snapshot now includes per-record/per-setting revision dates, deletion markers and synced preferences. It carries task metadata (comments, tags, attachments and relationships), event tags, quick notes, saved tags and smart lists, pinned order, specialized list profiles and item details, shopping store history and list preferences, and reusable templates. Appearance, theme, task density, task view/sort/group/filter preferences, list icons, calendar working/focus hours and saved calendar contexts are included. Calendar availability exclusions are also synced, using unambiguous account/calendar names to map device-specific identifiers.

Onboarding, scroll positions, comment drafts, Focus activation, notification authorization, Live Activity consent and device-specific default calendar/list selections stay local. Widget themes and shared metadata refresh from the synchronized values; system-managed widget-instance configurations remain controlled by WidgetKit.

## Lifecycle and conflicts

Launch and foreground reloads request sync; changes are debounced for two seconds. Settings exposes status and Sync Now. Local data remains usable when iCloud is unavailable; the next launch/foreground or manual sync retries. Dictionary records, notes, tags, smart lists and templates merge independently. Deleted records retain revision markers. Simultaneous edits to the same record use its newest revision; pin ordering uses the latest complete ordering. Edits made during network requests are merged before applying the result. CloudKit server-record conflicts merge using the current server record before retrying.

Unambiguous reminder lists are mapped using account type, account display name and list name to accommodate differing local identifiers. Duplicate account/list names are not guessed. Renames, different account display names and duplicate list names require a two-device validation; unmatched records remain in the snapshot. Calendar context identifiers and linked native identifiers still require matching EventKit accounts/identifiers.

## Compatibility and release validation

No additional CloudKit record types or top-level fields were introduced: the existing `TaskFlowMetadata` (`payload`, `updatedAt`) and `TaskFlowAttachment` (`file`, `localPath`, `updatedAt`) schema is reused. Older JSON payloads remain decodable. Timestamp encoding now retains fractional seconds. The existing snapshot architecture remains subject to CloudKit record size limits; large attachments use CKAsset.

Local simulator tests cover merging, deletion markers, older JSON, setting conflicts, list identity remapping and initial smart-list seeding. They do not contact a live iCloud database. Before release, run signed builds on two devices on the same iCloud account, verify the existing schema is deployed to Production, and test offline edits, simultaneous edits, attachments, list names and account changes. Production schema deployment and live-device verification have not been performed by this change.
