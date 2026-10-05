# Specialized lists

Choose a type in Settings → Edit Reminder Lists → Edit List → List Type, or use the list's Edit List action.

Standard lists keep their existing behavior. Switching type never removes specialized details or templates. Existing reminders retain their native EventKit titles, dates, recurrence, locations, and completion. Optional TaskFlow profiles, fields, and templates live in the metadata snapshot used by the existing metadata sync service.

- Shopping: quantity/unit, category, store, substitute, price, favorites, shopping mode, store grouping, configurable aisle order, Buy Again, and reversible duplicate merging. Duplicate merging combines only equal normalized titles/stores/units with valid numeric quantities, preserving duplicates in completed history.
- Projects: custom sections with drag-and-drop columns, milestones and outcomes. Existing task estimates, priorities, dependencies, and linked calendar planning remain available through task details.
- Household: room grouping, instructions, templates, and repeat after completion. Repeat-after-completion creates a new dated reminder; native recurring reminders take precedence.
- Packing: trip details, categories, quantities, Prepared/Packed states, and reusable templates.
- Bills: amount/currency/provider/payment link, distinct Paid/Canceled states, open totals and current-month totals grouped by currency. Dates, advance alerts, and recurrence use the existing reminder editor.
- Reading: creator, format, source links, and Saved/In Progress/Finished stages.
- Errands: destination grouping and opening-hours notes. Location alerts use existing task location settings.
- Appointments: contacts, questions, preparation, linked events, follow-up date and a reviewable follow-up reminder draft.
- Routines: ordered steps, instructions, foreground countdown timers, and templates that create fresh reminders while retaining previous runs.

In an existing task's details, open the specialized details row to edit optional fields. Use a row's context menu for stages, links, Buy Again, timers, or follow-up actions. List Tools provides completed history, templates, project sections, and shopping duplicate merging.

Widgets keep their flat actionable layout, showing shopping quantities, store names, and available progress stages from shared metadata. Widget timeline refresh remains system controlled.

Limitations: Opening hours and travel dates are user-provided, not fetched. Native reminder sharing does not automatically share TaskFlow-specific fields with another person's account. Custom fields are not written into Apple Reminders' private grocery or assignment APIs. Physical-device verification is still needed for EventKit-backed creation, completion, undo, drag-and-drop, and widget interaction.


## Specialized list polish phases (October 4, 2026)

1. **Shared controls:** per-list List/Board preference, name sorting, shopping filters, collapsed sections and completed disclosure; optional-field visibility; list-details editor; visible Undo. Templates support preview, rename, item and note editing, ordering, deletion confirmation and starter sets. Starting a run records all created reminders for one undo and restores the prior current-run setting.
2. **Shopping:** remembers the last store, suggests categories by whole words, accepts pasted lines with optional leading quantities, previews before saving, retains unsaved lines on partial failure, reloads once per batch and supports batch Undo. Grocery-staple templates remain editable. Store selection and additional fields stay optional.
3. **Projects, home and travel:** projects show milestone counts, blocked reasons and next-action markers with matching section names in rows and boards; section moves are undoable. Household has seasonal starter checklists and last-completed dates. Packing has essentials, category progress, remaining items and trip templates.
4. **Bills, reading and errands:** bills separate payment due dates from optional renewal, notice and cancellation dates, with reviewable reminder creation and confirmation notes. Reading supports ratings, progress detail, estimated time, source links and optional HTTPS thumbnail URLs. Errands show destinations, opening hours, linked shopping lists, Maps actions and a saved preparation checklist.
5. **Appointments and routines:** appointment details group preparation, questions and outcomes into Before/During/After; saved preparation checkmarks reset when the checklist text changes. Routines show the next open step, required markers, ordered templates, existing foreground timers and checklist run history.

Fields remain app-managed metadata. (Superseded October 5, 2026: see below for page details, automatic deadline reminders, and background timers.) Cross-account task assignment and non-shopping TaskFlow metadata remain outside the private metadata model. Shopping item details now travel with their reminders as described below. Physical-device visual validation is still required.


## Shopping quantities, repeat purchases, and shared activity

- Shopping rows show quantity/unit capsules beside the title, accent quantities greater than one, and expose accessible +/− controls. Missing quantity means one; fractions are retained, and invalid custom quantities must be edited before using numeric controls. Quantities never decrease to zero. Edits retain row identity, update in place, and invalidate older pending fetches rather than rebuilding the list.
- Capture and bulk paste offer to increase existing quantities or keep separate items. Matching uses normalized title, store, and unit, considers only open root items in the same list, and recognizes repeated entries within a pasted batch. Merged quantities preserve the existing item’s details. Both additions and quantity merges can be undone.
- Buy Again suggestions rank completed purchases by frequency and recency and choose the most common quantity for each title/store/unit combination. They retain notes, units, prices, and stores, while clearing previous trip/activity markers. An explicitly selected capture store overrides suggestions; None retains their original stores. Clearing completed reminders removes those reminders from the available suggestion history.
- Estimated prices are per unit. The store-filtered summary shows total, purchased, remaining, and number of unpriced items. Customize Fields → Shopping Budget sets an optional budget. Estimates use the device currency and exclude tax; missing, negative, invalid, and overflowing prices/quantities are omitted.
- Purchased items are collapsed into Purchased (count); empty lists offer Add Item, Paste Items, and Buy Again. The current store scope is labeled explicitly.
- Settings → Shopping → Your shopper name supplies addition and purchase attribution, including widget purchases. Shared details and activity are stored in a versioned, encoded terminal block in the reminder’s notes, preserving user note text in TaskFlow. That block is visible in other reminder clients; TaskFlow strips only valid blocks from its editor. It is not encrypted beyond the reminder account’s normal protection. Specialized details are imported from the reminder ahead of private-account metadata and mirrored for widget compatibility.
- Apple Reminders account sync and the existing EventKit change observer deliver incoming changes. Shared lists must already be shared through Reminders. Sync latency and simultaneous-edit conflicts remain controlled by that account. Actions taken outside TaskFlow do not expose a reliable actor; stale attribution is suppressed when completion timestamps differ. This is user-entered attribution, not authenticated identity.

Validation: regression tests cover valid/malformed notes envelopes, deterministic re-encoding, quantity formatting, budget calculation and invalid values, store/unit/list-aware duplicates, repeated pasted entries, usual purchase suggestions, shared-data precedence, and shopper-name persistence. Physical-device checks remain necessary for compact layouts, scrolling while checking items, and synchronization between two different reminder accounts.

Shopper names: Settings → Shopping uses a picker with Not Set, saved names, and names found in shared item activity. Add Shopper Name trims and selects a new name. Previously used names are retained locally across launches; names are deduplicated without regard to capitalization. Selected names remain available after shared items are removed.

Shopping Item now exposes a per-item Shopper picker and Add Shopper Name in its main section, along with Estimated Price per Unit. Shopper defaults to the active name for items without a saved selection, is saved with shared item details, and appears in list subtitles. Changing the item shopper does not change the active identity in Settings. Prices use the device currency formatter in the editor and retain canonical numeric strings for budget calculations.

Shopping items support trailing-swipe Delete and a Delete Item context-menu action for both open and purchased rows. Deletion requires confirmation, disables repeat actions while pending, shows failure feedback, and uses the existing task undo flow. Successful deletion invalidates older pending fetches so they cannot reinsert a removed row.


## Expanded categories and store layouts

Shopping adds Deli & Prepared Foods, Breakfast & Cereal, Baking Supplies, Condiments & Spices, Canned & Jarred Goods, Cleaning Supplies, Paper & Disposable Goods, Health & Pharmacy, Baby & Kids, Pet Supplies, Home Improvement, Garden & Outdoor, and Clothing & Accessories. Frozen and Snacks are displayed as Frozen Foods and Snacks & Candy without destructively rewriting older records. New item and bulk-paste suggestions recognize representative words and phrases for the expanded categories.

Shopping Item → Add Category saves and selects a custom category. List Tools → Categories & Aisle Order (also available under Customize Fields) manages saved custom categories and provides drag handles to arrange categories. Store Layout selects All Stores (Default), No Store, or a named store. Named layouts inherit All Stores until reordered, and Use Default Order removes a store override. Reset Default Order also clears the old comma-separated aisle configuration. Preferences use list profile metadata and the existing private iCloud sync. Custom labels arriving on shared reminders are available in the picker; removing a saved custom category preserves labels on existing items. Category layouts apply when grouping by category; Group by Store continues grouping by store.

Regression coverage includes expanded suggestions and legacy aliases, custom-category persistence and deduplication, preserving assigned categories on removal, independent store layouts, default fallback, and resetting overrides. Device verification is still required for drag handles and sheet navigation.


## Fast price estimates and recall

Tap a row’s price or Add Price to open a compact currency-formatted price editor. Saving updates the current item’s latest details, budget totals, and a persistent estimate keyed by normalized item title, store, unit, and device currency. Saved estimates are local preferences, separate from reminders, so deleting purchased items or clearing a trip does not remove them. New capture, bulk paste, and shopping template runs recall missing prices without overwriting explicit estimates. The item editor previews remembered prices as its name/store/unit changes, while manually entered prices remain under user control. Existing records seed missing history in newest-first order; reloading old purchases does not overwrite corrected estimates. Tests cover persistence after item removal, store/unit separation, explicit estimate preservation, valid zero prices, invalid-value rejection, and history seeding without stale overwrite. Device checks remain for decimal keyboard and currency entry interaction.


Price-entry mode: use Estimate Missing Prices in the shopping header or List Tools. It captures a stable queue of the visible open unpriced items, shows item/store/unit and progress, and offers Save & Next with the decimal keyboard retained. The keyboard accessory provides Next; Skip leaves an item unchanged, and successful saves remain committed if the mode is closed early. Deleted/completed queued items are skipped. Invalid or negative values cannot be saved, and errors keep the current entry available for retry. Suggestions in Buy Again and Common Items show price per unit when an estimate exists. The selected store’s remembered price takes precedence, and the displayed suggestion estimate is also used when adding it. Regression tests cover localized decimal entry and matching-store suggestion pricing; physical-device keyboard and navigation checks remain.


## List type upgrades (October 5, 2026)

- **Readable dates and amounts:** stored `yyyy-MM-dd` fields display as "Today", "Tomorrow", or "Oct 20 · in 15 days". Past bill deadlines on open bills show in red; household "Last done" turns orange once older than its repeat interval; appointments show their follow-up date. Bill amounts and totals use the currency's own format when the Currency field is an ISO code.
- **Bill deadline reminders:** open bills alert at 9 AM on their Renewal, Notice, and Cancellation dates, plus an advance notice (default 3 days). Customize Fields → Reminders turns this off per list or changes the advance notice. Paid/Canceled bills and hidden fields stay quiet. These requests share the app's 64-notification budget and are ordered by date with task alerts.
- **Routine timers:** Start Timer (row menu, or beside the current step) keeps running after leaving the list or the app. The end time is stored per list, a local notification fires when it ends, and a Lock Screen/Dynamic Island Live Activity counts down. Stop Timer cancels all three; finished activities are cleaned up on next launch or foreground.
- **Errand places:** an errand's details include Place search. The chosen place is saved on the reminder as a location alert (arrive or leave, adjustable radius), so Reminders delivers the alert. Rows show the place, and Open in Maps / Get Directions use exact coordinates.
- **Reading link details:** Save a Link fetches the page and fills the title (unless typed), creator, format, HTTPS thumbnail, and an estimated reading time (230 words per minute, articles only). Share Sheet → TaskFlow → Read Later (pre-selected for shared web pages) saves into the selected Reading list, else the default list's Reading list, else the first one. Without a Reading list the link opens in Quick Capture instead. Pages that block the request, or http pages blocked by App Transport Security, simply save without details.
- **Next Actions:** Projects lists show a "Next Actions in All Projects" row (also in List Tools). It gathers open Next Action tasks from every Projects list, soonest due first, with section, milestone, and blocked reason. Tap to open, tap the circle to complete, swipe to clear. Row menus now offer Clear Next Action.

Validation: regression tests cover date/amount formatting, page metadata parsing (Open Graph, attribute order, entities, reading time, video hosts), and deadline notification timing/identifiers. Physical-device checks remain necessary for Live Activities, location alerts, the share extension, and network page fetches.
