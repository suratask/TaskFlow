# TaskFlow Studio Shortcuts

TaskFlow's actions work with Apple Reminders. On first use they request full Reminders access; denied access produces an error with recovery instructions instead of an empty result. Run permission setup while the device is unlocked before using unattended automations.

## Available actions

| Action | Inputs | Output |
| --- | --- | --- |
| Add Reminder | Title; optional list, due date, notes; named priority | Created reminder |
| Find Reminders | Search text (blank for all), optional list, completion filter, maximum results (1–1000) | Reminder collection |
| Complete Reminder | Reminder | Updated reminder |
| Reopen Reminder | Reminder | Updated reminder |
| Reschedule Reminder | Reminder, new date, Include Time | Updated reminder |
| Set Reminder Priority | Reminder, numeric EventKit priority (0–9) | Updated reminder |
| Set Reminder Priority Level | Reminder, None/Low/Medium/High | Updated reminder |
| Get Reminder Lists | None | List collection |
| Move Reminder to List | Reminder, destination list | Updated reminder |
| Rename Reminder | Reminder, new title | Updated reminder |
| Append Text to Reminder Notes | Reminder, text | Updated reminder |
| Remove Reminder Due Date | Reminder | Updated reminder |
| Open Reminder in TaskFlow Studio | Reminder | Opens reminder details |
| Open Reminder List in TaskFlow Studio | List | Opens that list |

Reminder outputs expose Title, List, Due Date, Completed, Priority, and Notes in Shortcuts. Picker searches include completed reminders. Find Reminders searches titles, notes, and list names, and matches every word in the search text. Results are ordered with incomplete reminders first, then by due date and title. Numeric priority remains available for existing saved Shortcuts.

Add Reminder uses TaskFlow's configured default list when available, otherwise Apple Reminders' default. Reschedule uses the chosen time when Include Time is enabled; disable it for an all-day reminder. Absolute time alerts move by the same interval as the due date, relative alerts keep their offsets, and location alerts are preserved. Clear Due Date removes time alerts while retaining location alerts.

## Example workflows

- Add Reminder → Append Text to Reminder Notes → Open Reminder in TaskFlow Studio. Select the preceding action's reminder output in each subsequent action.
- Find Reminders (List: Work, Completion: Incomplete) → Repeat with Each → Reschedule Reminder (Reminder: Repeat Item).
- Find Reminders (Completion: Completed) → Choose from List → Reopen Reminder.

The widget's internal completion action is hidden from the action catalog. Use TaskFlow's public Complete Reminder action for saved Shortcuts.

## Validation

Automated regression tests cover matching and result limits, completed-reminder suggestions, date-only and timed rescheduling, start-date consistency, absolute and relative alarm preservation across daylight saving changes, priority mapping, and encoded navigation identifiers with one-time route consumption. Xcode also validates extracted App Intents metadata.

Device acceptance checks still needed for Siri and Shortcuts system UI:

1. Grant access on a fresh installation; deny access and verify the actionable error.
2. Chain Add Reminder → Complete → Reopen using the returned reminder; verify Apple Reminders and TaskFlow reflect each change.
3. Search for a completed reminder by name in the picker and in Find Reminders.
4. Reschedule a date-only reminder to a chosen time; verify its alert moves too.
5. Run Open Reminder and Open List from a terminated app and from the Notes or Calendar tab, on iPhone and iPad.
6. Attempt an action on a deleted reminder or a read-only list; verify a clear error and no unintended mutation.

## Control Center (iOS 18 and later)

TaskFlow provides Quick Capture, New Note, and Dictate Note controls for Control Center, the Lock Screen, and the Action button.

- Quick Capture opens the existing capture sheet.
- New Note opens a blank note editor.
- Dictate Note opens a blank note with live transcription. Microphone and Speech Recognition permissions are requested in the app. Stop, review, Insert, and Save to keep the note.

All three use foreground App Intents compiled into both the app and widget extension. They persist their destination until the app has finished loading, and notify the app directly when it is already running. Quick Capture keeps its existing control identifier so installed controls continue to resolve. The controls no longer pass a custom URL scheme to OpenURLIntent.

Validation: build and 82 regression tests pass; generated App Intents metadata includes all three foreground intents in both targets. The simulator GUI check was blocked by the computer-use runtime's symlink configuration error; physical Control Center taps and microphone transcription remain to be checked on a device.
