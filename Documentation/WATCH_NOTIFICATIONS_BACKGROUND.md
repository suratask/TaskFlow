# Watch Later notifications and background refresh

## Saved viewing links

The app uses provider links captured from sharing or added manually. These links identify the saved service; they do not establish current regional availability. TVmaze provides show metadata and episode schedules through its free public API without an API token. The app has no token configuration or regional availability lookup.

## Episode notification controls

In **Show & Episodes**, enable release notifications and choose a release-day time, an optional 15/30/60-minute advance reminder, and whether alerts play a sound. An advance reminder uses a known exact air timestamp. If only a day is known, the chosen release-day time is used. Full-season batches generate one notification per show/day. Watched episodes, dropped shows, merged items, and completed items do not generate new release alerts. Notifications open the saved item.

## Background updates

The app registers `com.surratt.TaskFlow.watchRefresh` for BGAppRefresh and requests another opportunity no earlier than six hours later when leaving the app with tracked shows. Each run loads saved reminders, prioritizes the oldest refreshed shows, updates at most three catalogs, and updates cached widget data and local notifications. Expiration cancels the refresh; canceled responses cannot overwrite saved metadata.

iOS decides when background refresh runs. It is not continuous polling or a guaranteed release-time update. Force-quitting TaskFlow or disabling Background App Refresh can prevent background updates. Already scheduled local alerts can still arrive while the app is closed. Newly announced or changed releases are discovered on an allowed background run, a foreground refresh, or manual refresh.

On a physical device, verify Background App Refresh is enabled for TaskFlow, notification permission is granted, and cached results and schedules refresh across reopening. Simulator builds do not establish real background delivery reliability.

## Widget and notification actions

Episode widgets offer **Watched** or a checkmark button for the displayed released episode. **Coming Soon** does not mark future episodes watched. Tapping the title or artwork opens the saved show as before. Queued taps update widget progress without opening TaskFlow, then reconcile into saved show metadata on the next foreground/background load. Repeated taps target the same episode and do not skip ahead. The app retains an Undo snapshot when it applies an update.

Expand a release notification to access **Mark Watched** and **Remind Me Later**. Remind Me Later schedules one reminder **one hour later**. A full-season release alert marks its first unwatched episode, not the entire batch. An advance reminder offers only Remind Me Later until its episode is released. Marking an episode watched cancels its obsolete reminders; turning off show alerts or dropping/completing the saved item clears its pending snoozes when TaskFlow reschedules notifications.

Verify on a signed iPhone build: tap Watched with TaskFlow closed, confirm the widget advances to the next released episode, reopen the saved show to verify progress, and try Undo. Expand a release alert, test both actions, and verify one-hour reminder delivery and opt-out cleanup. Confirm an advance alert cannot mark a future episode watched. The app and widget extension must both have their existing `group.com.surratt.TaskFlow` entitlement.
