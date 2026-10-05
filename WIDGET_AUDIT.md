# Widget audit

The gallery now offers four purposes: Today (date-only in small and Lock Screen sizes, agenda in larger sizes), Up Next, configurable Tasks, and Quick Capture. Live Activities and the Quick Capture control remain available.

Agenda, Day Flow, High Priority, and the old generic Tasks gallery entries were removed. Use Today/Up Next for agenda content and Tasks with selected reminder lists for focused tasks. Users with removed widget kinds may need to replace them.

Tasks, Today, and Up Next support multiple reminder lists, maximum items, and completed-task visibility. Empty list selection means all lists. Smart-list configuration was removed. Today and Up Next also offer calendar selection. Existing widgets may need their list selections reconfigured. Completion actions remain separate from links that open task details. Completed tasks have a checked, disabled completion control.

System backgrounds, semantic typography, simpler headers, and list/calendar accents keep layouts restrained. Family size caps prevent configured item counts from overfilling smaller layouts.

Date-only timelines skip EventKit and refresh at the next local midnight. Reminder metadata and specialized list types are loaded once per provider store. Scope filtering precedes result limits. Recurring events have distinct occurrence row identities. Failed completion attempts throw instead of recording a false completion.

Validation: app, widget extension, and share extension simulator builds plus app regression tests. Home Screen light/dark/tinted rendering and widget configuration/action flows still need interactive device verification.

## Shopping List widget

- Dedicated Shopping List gallery entry supports Large and XL, plus XL Portrait on iOS 27 and later.
- Picker searches only editable lists marked Shopping & Groceries. With no selection, it uses the first shopping list alphabetically; a deleted or retyped selection shows a configuration message instead of switching to another list.
- Shows incomplete shopping items with quantity/unit, category, and store; optional Store filter matches case-insensitively. Categories and titles sort alphabetically.
- Large shows up to 5 items, XL shows up to 10 in two columns, and XL Portrait shows up to 11 in a single column. Accessibility text sizes reduce the row count. The remaining count and +more footer include all matching items.
- Check-off buttons save completion through EventKit and reload widgets; item titles open task details, and Open List opens the configured shopping list.
- Distinct permission, missing-list, no-shopping-list, and shopping-complete states. Gallery sample data uses grocery items.
- Simulator build verified. Home Screen layout and widget taps still require device verification; the computer-use runtime in this session is unavailable.


## Shopping store picker

Shopping List widget configuration now uses dynamic store choices instead of a free-text field. Choices depend on the selected shopping list (or the first available shopping list when none is selected), include stores from completed items, and offer All Stores. Empty store names are omitted and capitalization variants are combined. Existing string-based store selections remain supported. App/widget builds and generated App Intents metadata were verified; live widget-configuration interaction still requires a device check.
