# Reminder integration

TaskFlow uses Apple's public EventKit framework. The installed SDK does not expose native Reminders parent/subtask relationships, tags, flags, comments, or attachments. These remain TaskFlow metadata; they are not presented as native Reminders synchronization features.

## Available in the app

- Native reminder titles, notes, links, completion, priorities, list assignment, start dates, and due dates.
- Primary relative alerts and additional date/time alerts; existing additional relative alerts remain editable by removal and replacement.
- Location search with native arrival/departure alarms and radius selection.
- Daily, weekly, monthly, and yearly recurrence with intervals, selected weekdays/month days/months, and date/count endings.
- Existing advanced recurrence rules and custom alerts remain intact during unrelated edits.
- Reminder list creation, default list selection, and list name/color editing in Settings.
- External EventKit change notifications refresh the app.
- Batch saves stage metadata until EventKit commits successfully; failed pending writes reset the event store.
- Calendar permissions distinguish full access from write-only access, including widgets.

Reminder options are in task editing (More Options for new tasks). Task details display the imported native fields. TaskFlow's optional due-date notifications are a separate setting from Apple Reminders alerts.

## Framework limits and validation

Native subtasks, native tags/flags, participant invitations, and native reminder attachments are not exposed for editing by these public APIs. Calendar attendees and organizer information are read-only. TaskFlow attachments and comments are managed separately.

Simulator builds and unit tests cover compilation, models, alert decoding, geofence decoding, and compatibility with existing metadata. Delivery of location alerts and synchronization through an actual Reminders account require device/account verification.
