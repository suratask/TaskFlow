// Web notes — the page, shared by Sebastian Notes and TaskFlow Notes.
// Source of truth: Sebastian repo, WebNotes/shared/ (TaskFlow keeps a copy;
// see WebNotes/README.md). Each app's core.mjs provides the records and
// iCloud provider behind the same exports, and its profile.json (served in
// config.js) names the app and turns features on: folders, permanent delete,
// and the lock on text formatted in the app.
//
// Stability rules:
// - Background sync never replaces the open note while it is being edited.
//   If it changed on another device, a banner offers the newer version.
// - A save never rewrites the editor; it only records what iCloud stored.
// - Unsaved text is backed up in the browser (localStorage) until iCloud
//   confirms it, so even a crash or a closed tab doesn't lose it, and a failed
//   save is retried until it lands. Hiding or closing the tab saves at once.
// - The list holds its order while a note is being edited.
import {CloudNotesProvider, DemoNotesProvider, NoteConflict, newNote, visibleNotes, isDeleted, isPinned, canTrash, plainPreview, safeLink, needsSignIn,
  isPurged, purgedNote, tagColor, tagStats, frequentTags, folderStats, noteBadges} from '../core.mjs';
import {markdownToDelta, deltaToMarkdown, URL_PATTERN, linkTarget} from './rich-text.mjs';
/// A tag's colour: the one chosen in the app, else the app's default for it.
const colorOf = tag => tagColor(tag, provider?.tagColors);
const profile = window.NOTES_CONFIG?.profile ?? {}, features = profile.features ?? {};
const APP = profile.appName ?? 'Notes', STORE = profile.storagePrefix ?? 'Notes.';

const $ = id => document.getElementById(id);
const SAVE_DELAY = 1000, REFRESH_INTERVAL = 45_000, EDITING_GRACE = 20_000;
let provider = null, account = '', notes = [], draft = null, dirty = false, revision = 0;
let saveTimer, savePromise = null, refreshing = false, conflict = null, resolving = false;
let session = 0, entering = null, renderFrame = null, lastInput = 0, unsavedNewID = null, pendingRemote = null;
let retryTimer, retryAttempt = 0, reauthing = false, signingOut = false;
let view = {kind: 'all', tag: '', folder: ''};
/// The list order as shown when editing began (id → position), so saving
/// doesn't move cards under the pointer. Released when the editing ends.
let orderLock = null, shownOrder = [];

// No uploader: images and files are added in the app (see the paste and drop handlers).
const rich = new Quill('#note-body', {modules: {toolbar: false, history: {userOnly: true}, uploader: {mimetypes: []}},
  formats: ['bold', 'italic', 'link', 'header', 'list', 'blockquote', 'indent'], placeholder: 'Start writing…'});
rich.root.setAttribute('role', 'textbox'); rich.root.setAttribute('aria-label', 'Note text'); rich.root.setAttribute('aria-multiline', 'true');

// MARK: - Status

const isDemo = () => provider instanceof DemoNotesProvider;
/// `text` fits the toolbar; `detail` (shown on hover) can say more.
function setSaveState(text, error = false, detail = text) {
  $('save-state').textContent = text; $('save-state').title = detail; $('save-state').classList.toggle('error', error);
  $('download-draft').hidden = !error || !draft;
}
function setSyncStatus(text, error = false) {
  $('sync-status').textContent = text; $('sync-status').classList.toggle('error', error);
}
const savedText = () => isDemo() ? 'Saved in this tab' : 'Saved';
const syncedText = () => isDemo() ? 'Sample notes · nothing is sent to iCloud' : 'Synced with iCloud';

// MARK: - Unsaved changes, backed up in the browser

/// Each backup records which tab wrote it. A tab marks itself alive every few
/// seconds, so a new tab leaves alone the backups of one still open (it will
/// save them itself) and recovers those of a tab that closed or crashed.
const prefix = STORE + 'backup.';
const TAB_ID = crypto.randomUUID(), TAB_PREFIX = STORE + 'tab.', TAB_ALIVE = 30_000, BACKUP_LIFETIME = 30 * 86_400_000;
const draftKey = id => prefix + encodeURIComponent(account) + '.' + id;
const storage = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(key, value); return true; } catch { return false; } },
  remove(key) { try { localStorage.removeItem(key); } catch { /* Nothing to remove. */ } },
  keys() { try { return Object.keys(localStorage); } catch { return []; } }
};
function stash() {
  if (!draft || !account) return;
  if (!storage.set(draftKey(draft.id), JSON.stringify({note: draft, tab: TAB_ID, savedAt: Date.now()}))) setSaveState('Keep this tab open until your note saves.', true);
}
function clearStash(id) { if (account) storage.remove(draftKey(id)); }
function markTabAlive() { storage.set(TAB_PREFIX + TAB_ID, String(Date.now())); }
markTabAlive(); setInterval(markTabAlive, 10_000);
const tabIsAlive = tab => tab === TAB_ID || Date.now() - Number(storage.get(TAB_PREFIX + tab) || 0) < TAB_ALIVE;
/// Backups this tab should recover: this account's, not owned by a live tab.
function orphanedBackups() {
  const found = [];
  for (const key of storage.keys()) {
    if (key.startsWith(TAB_PREFIX) && !tabIsAlive(key.slice(TAB_PREFIX.length))) { storage.remove(key); continue; }
    if (!key.startsWith(prefix + encodeURIComponent(account) + '.')) continue;
    try {
      const {note, tab, savedAt} = JSON.parse(storage.get(key));
      if (Date.now() - savedAt > BACKUP_LIFETIME) { storage.remove(key); continue; }
      if (tab !== TAB_ID && tabIsAlive(tab)) continue;
      if (note?.id && typeof note.body === 'string' && Array.isArray(note.tags)) found.push(note);
    } catch { storage.remove(key); /* Damaged backups never replace iCloud notes. */ }
  }
  return found;
}
const sameContent = (a, b) => a.title === b.title && a.body === b.body && JSON.stringify(a.tags) === JSON.stringify(b.tags) &&
  (a.pinnedAt ?? null) === (b.pinnedAt ?? null) && (a.deletedAt ?? null) === (b.deletedAt ?? null);
/// Saves what a closed or crashed tab didn't. A backup that matches iCloud is
/// just cleared; one that conflicts opens with the conflict dialog.
async function recoverBackups(currentSession) {
  let restored = 0, conflicted = null;
  for (const backup of orphanedBackups()) {
    const current = notes.find(note => note.id === backup.id);
    if (current && sameContent(current, backup)) { clearStash(backup.id); continue; }
    dropLegacySession();
    try {
      const saved = await provider.save(backup);
      if (session !== currentSession) return;
      upsert(saved); clearStash(backup.id); restored++;
    } catch (error) {
      if (session !== currentSession) return;
      if (error instanceof NoteConflict && !conflicted) conflicted = backup;
      else if (needsSignIn(error)) { showReauth(); break; }
    }
  }
  scheduleRender();
  if (restored) showToast(`Recovered unsaved changes in ${restored} ${restored === 1 ? 'note' : 'notes'}.`);
  if (conflicted) { upsert(conflicted); openNote(conflicted, {recovered: true}); flush(); }
}

// MARK: - Notes in memory

function upsert(note) { notes = notes.filter(item => item.id !== note.id); notes.push(note); }
/// A new note is only saved once something is typed in it.
function discardUnusedNewNote() {
  if (unsavedNewID && draft?.id === unsavedNewID && !dirty) notes = notes.filter(note => note.id !== unsavedNewID);
  unsavedNewID = null;
}
function liveTags() {
  const counts = new Map();
  for (const note of notes) if (!isDeleted(note)) for (const tag of note.tags) counts.set(tag, (counts.get(tag) || 0) + 1);
  return [...counts].sort(([a], [b]) => a.localeCompare(b, undefined, {sensitivity: 'base'}));
}
const sortKey = STORE + 'sort';
let sortBy = storage.get(sortKey) || 'modified';
$('sort-select').value = sortBy;
$('sort-select').onchange = () => { sortBy = $('sort-select').value; storage.set(sortKey, sortBy); orderLock = null; scheduleRender(); };
/// "#den" in the search box looks for tags starting with "den"; null otherwise.
function searchedTag() {
  const query = $('search').value.trim();
  return query.startsWith('#') ? query.slice(1).toLocaleLowerCase() : null;
}
function listedNotes() {
  const tagQuery = searchedTag();
  const listed = visibleNotes(notes, {query: tagQuery === null ? $('search').value : '', tag: view.kind === 'tag' ? view.tag : '',
    folder: view.kind === 'folder' ? view.folder : '', trash: view.kind === 'trash', sortBy});
  const tagged = tagQuery === null ? listed : listed.filter(note => note.tags.some(tag => tag.toLocaleLowerCase().startsWith(tagQuery)));
  return view.kind === 'untagged' ? tagged.filter(note => !note.tags.length) : tagged;
}

// MARK: - Sidebar and list

function scheduleRender() {
  if (!renderFrame) renderFrame = setTimeout(() => { renderFrame = null; renderSidebar(); renderList(); });
}
function navButton(label, count, current, onClick) {
  const button = document.createElement('button'); button.className = 'nav-item'; button.type = 'button';
  const icon = document.createElement('span'); icon.className = 'nav-icon tag-dot'; icon.setAttribute('aria-hidden', 'true');
  icon.style.setProperty('--tag', colorOf(label));
  const name = document.createElement('span'); name.className = 'nav-label'; name.textContent = label;
  const badge = document.createElement('span'); badge.className = 'count'; badge.textContent = count;
  button.append(icon, name, badge);
  if (current) button.setAttribute('aria-current', 'true');
  button.addEventListener('click', onClick);
  return button;
}
function renderSidebar() {
  const live = notes.filter(note => !isDeleted(note));
  $('count-all').textContent = live.length;
  $('count-trash').textContent = notes.filter(note => isDeleted(note) && !isPurged(note)).length || '';
  $('count-untagged').textContent = live.filter(note => !note.tags.length).length;
  for (const item of document.querySelectorAll('.nav-item[data-view]')) {
    if (item.dataset.view === view.kind) item.setAttribute('aria-current', 'true'); else item.removeAttribute('aria-current');
  }
  renderFolders(); renderTags();
}

// MARK: - Folders in the sidebar (profile feature "folders")

const folderButton = ({folder, count}) => {
  const button = navButton(folder, count, view.kind === 'folder' && view.folder === folder, () => showView({kind: 'folder', tag: '', folder}));
  const icon = button.querySelector('.nav-icon'); icon.className = 'nav-icon'; icon.textContent = '▱';
  return button;
};
function renderFolders() {
  const stats = features.folders ? folderStats(notes) : [];
  $('folders-section').hidden = !stats.length;
  $('folder-suggestions').replaceChildren(...stats.map(({folder}) => new Option(folder)));
  const open = !sidebarState.foldersClosed;
  $('folders-toggle').setAttribute('aria-expanded', String(open)); $('folders-body').hidden = !open;
  $('folder-nav').replaceChildren(...stats.map(folderButton));
}
$('folders-toggle').onclick = () => { sidebarState.foldersClosed = !sidebarState.foldersClosed; saveSidebarState(); renderFolders(); };

// MARK: - Tags in the sidebar

/// Up to eight tags are simply listed. Past that, the most used and recently
/// used stay in view and the rest fold into "All Tags", which has a filter.
const FOLD_AFTER = 8, FREQUENT = 6, sidebarKey = STORE + 'sidebar';
let sidebarState = {};
try { sidebarState = JSON.parse(storage.get(sidebarKey)) ?? {}; } catch { /* Defaults: tags open, All Tags closed. */ }
function saveSidebarState() { storage.set(sidebarKey, JSON.stringify(sidebarState)); }
const tagButton = ({tag, count}) => navButton(tag, count, view.kind === 'tag' && view.tag === tag, () => showView({kind: 'tag', tag}));
function renderTags() {
  const stats = tagStats(notes);
  $('tags-section').hidden = !stats.length;
  $('tag-suggestions').replaceChildren(...stats.map(({tag}) => new Option(tag)));
  const open = !sidebarState.tagsClosed;
  $('tags-toggle').setAttribute('aria-expanded', String(open)); $('tags-body').hidden = !open;
  const folding = stats.length > FOLD_AFTER;
  $('all-tags').hidden = !folding;
  if (!folding) { $('tag-nav').replaceChildren(...stats.map(tagButton)); return; }
  let shown = frequentTags(stats, FREQUENT);
  // The tag being viewed stays in sight.
  const current = view.kind === 'tag' && !shown.some(entry => entry.tag === view.tag) && stats.find(entry => entry.tag === view.tag);
  if (current) shown = [...shown, current];
  $('tag-nav').replaceChildren(...shown.map(tagButton));
  $('count-tags').textContent = stats.length;
  $('all-tags-toggle').setAttribute('aria-expanded', String(Boolean(sidebarState.allOpen)));
  $('all-tags-body').hidden = !sidebarState.allOpen;
  renderAllTags(stats);
}
function matchingTags(stats) {
  const filter = $('tag-filter').value.trim().replace(/^#+/, '').toLocaleLowerCase();
  return filter ? stats.filter(({tag}) => tag.toLocaleLowerCase().includes(filter)) : stats;
}
function renderAllTags(stats = tagStats(notes)) {
  const matches = matchingTags(stats);
  const empty = document.createElement('p'); empty.className = 'tag-filter-empty'; empty.textContent = 'No tags match.';
  $('all-tag-nav').replaceChildren(...(matches.length ? matches.map(tagButton) : [empty]));
}
$('tags-toggle').onclick = () => { sidebarState.tagsClosed = !sidebarState.tagsClosed; saveSidebarState(); renderTags(); };
$('all-tags-toggle').onclick = () => {
  sidebarState.allOpen = !sidebarState.allOpen; saveSidebarState(); renderTags();
  if (sidebarState.allOpen && matchMedia('(hover: hover)').matches) $('tag-filter').focus();
};
$('tag-filter').addEventListener('input', () => renderAllTags());
$('tag-filter').addEventListener('keydown', event => {
  if (event.key === 'Enter') { const [first] = matchingTags(tagStats(notes)); if (first) showView({kind: 'tag', tag: first.tag}); }
  else if (event.key === 'Escape' && $('tag-filter').value) { event.stopPropagation(); $('tag-filter').value = ''; renderAllTags(); }
});

// MARK: - "#" in the search box

let suggestions = [], suggestionIndex = 0;
function renderSuggestions() {
  const query = searchedTag(), box = $('tag-suggest');
  if (query === null || document.activeElement !== $('search')) { box.hidden = true; $('search').setAttribute('aria-expanded', 'false'); return; }
  // Tags starting with the text first, then those containing it; busier first.
  suggestions = tagStats(notes).filter(({tag}) => tag.toLocaleLowerCase().includes(query))
    .sort((a, b) => Number(b.tag.toLocaleLowerCase().startsWith(query)) - Number(a.tag.toLocaleLowerCase().startsWith(query)) || b.count - a.count)
    .slice(0, 8);
  suggestionIndex = Math.min(suggestionIndex, Math.max(0, suggestions.length - 1));
  const rows = suggestions.map((entry, index) => {
    const row = navButton(entry.tag, entry.count, false, () => pickTag(entry.tag));
    row.setAttribute('role', 'option'); row.setAttribute('aria-selected', String(index === suggestionIndex));
    row.addEventListener('mousedown', event => event.preventDefault());
    return row;
  });
  const hint = document.createElement('p'); hint.className = 'hint-row';
  hint.textContent = suggestions.length ? 'Enter shows notes with this tag' : 'No tags match';
  box.replaceChildren(...rows, hint);
  box.hidden = false; $('search').setAttribute('aria-expanded', 'true');
}
function pickTag(tag) {
  $('search').value = ''; suggestionIndex = 0;
  $('search').blur(); renderSuggestions();
  showView({kind: 'tag', tag});
}
$('search').addEventListener('focus', renderSuggestions);
$('search').addEventListener('blur', () => { $('tag-suggest').hidden = true; $('search').setAttribute('aria-expanded', 'false'); });
$('search').addEventListener('keydown', event => {
  if ($('tag-suggest').hidden) return;
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    suggestionIndex = (suggestionIndex + (event.key === 'ArrowDown' ? 1 : -1) + suggestions.length) % Math.max(1, suggestions.length);
    renderSuggestions();
  } else if (event.key === 'Enter' && suggestions[suggestionIndex]) { event.preventDefault(); pickTag(suggestions[suggestionIndex].tag); }
  else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); $('search').value = ''; suggestionIndex = 0; renderSuggestions(); scheduleRender(); }
});
function relativeDate(value) {
  const date = new Date(value);
  if (isNaN(date)) return '';
  const day = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const days = Math.round((day(new Date()) - day(date)) / 86_400_000);
  if (days <= 0) return date.toLocaleTimeString(undefined, {hour: 'numeric', minute: '2-digit'});
  if (days === 1) return 'Yesterday';
  if (days < 7) return date.toLocaleDateString(undefined, {weekday: 'long'});
  return date.toLocaleDateString(undefined, date.getFullYear() === new Date().getFullYear() ? {month: 'short', day: 'numeric'} : {month: 'short', day: 'numeric', year: 'numeric'});
}
/// The title the app shows: the note's title, else its first line.
function cardText(note) {
  if (note.title.trim()) return {title: note.title.trim(), preview: plainPreview(note.body)};
  const lines = note.body.split('\n'), first = lines.findIndex(line => line.trim());
  if (first < 0) return {title: 'New Note', preview: ''};
  return {title: plainPreview(lines[first], 80) || 'New Note', preview: plainPreview(lines.slice(first + 1).join('\n'))};
}
function renderList() {
  const listed = listedNotes();
  // Notes missing from the lock (none, normally) keep their usual order after it.
  if (orderLock) listed.sort((a, b) => (orderLock.get(a.id) ?? Infinity) - (orderLock.get(b.id) ?? Infinity));
  shownOrder = listed.map(note => note.id);
  const names = {all: 'All Notes', trash: 'Trash', untagged: 'Untagged Notes', tag: '#' + view.tag, folder: view.folder};
  $('list-title').textContent = `${names[view.kind]} · ${listed.length} ${listed.length === 1 ? 'note' : 'notes'}`;
  $('empty-trash').hidden = view.kind !== 'trash' || !listed.length || !features.permanentDelete;
  const list = $('note-list'), scroll = list.scrollTop;
  list.replaceChildren(...listed.map(note => {
    const {title, preview} = cardText(note);
    const card = document.createElement('button'); card.type = 'button';
    card.className = 'note-card' + (note.id === draft?.id ? ' selected' : '');
    const heading = document.createElement('span'); heading.className = 'note-card-title';
    if (isPinned(note)) { const pin = document.createElement('span'); pin.className = 'pin'; pin.textContent = '★'; pin.setAttribute('aria-label', 'Pinned'); heading.append(pin); }
    heading.append(title);
    const body = document.createElement('span'); body.className = 'note-card-preview'; body.textContent = preview || ' ';
    const date = document.createElement('span'); date.className = 'note-card-date'; date.textContent = relativeDate(note.modifiedAt ?? note.createdAt);
    card.append(heading, body);
    if (note.tags.length || (features.folders && note.folder)) card.append(cardTags(note.tags, features.folders ? note.folder : ''));
    card.append(date);
    card.addEventListener('click', () => selectNote(note.id));
    return card;
  }));
  if (!listed.length) {
    const empty = document.createElement('p'); empty.className = 'empty-list';
    empty.textContent = $('search').value ? 'No matching notes.' : view.kind === 'trash' ? 'Trash is empty.' : 'No notes here yet.';
    list.append(empty);
  }
  list.scrollTop = scroll;
}
/// Up to three tags on a card, each with its colour; the rest as "+2".
function cardTags(tags, folder) {
  const row = document.createElement('span'); row.className = 'note-card-tags';
  if (folder) { const label = document.createElement('span'); label.className = 'folder-chip'; label.textContent = folder; row.append(label); }
  for (const tag of tags.slice(0, 3)) row.append(tagChip(tag, 'tag-chip'));
  if (tags.length > 3) { const more = document.createElement('span'); more.className = 'tag-more'; more.textContent = `+${tags.length - 3}`; row.append(more); }
  return row;
}
function tagChip(tag, className) {
  const chip = document.createElement('span'); chip.className = className; chip.textContent = tag;
  chip.style.setProperty('--tag', colorOf(tag));
  return chip;
}
function showView(next) { view = next; orderLock = null; closeSidebar(); scheduleRender(); }

// MARK: - Editor

function renderTagPills() {
  $('tag-pills').replaceChildren(...(draft?.tags ?? []).map(tag => {
    const pill = tagChip(tag, 'tag-pill'); pill.textContent = '';
    const name = document.createElement('span'); name.textContent = tag;
    const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'remove'; remove.textContent = '×';
    remove.setAttribute('aria-label', `Remove tag ${tag}`);
    remove.addEventListener('click', () => removeTag(tag));
    pill.append(name, remove);
    return pill;
  }));
}
/// Notes whose text was unlocked with "Edit Text Here" in this tab.
const unlockedFormatting = new Set();
/// The app's formatting lives on the device. Editing the text here saves it as
/// Markdown, which the app then shows in place of it, so the text of such a
/// note stays locked until asked. The title, tags, pin and Trash keep it.
/// Whether the open note still has the app's formatting, unedited here.
const keepsAppFormatting = () => Boolean(features.formattingLock) && Boolean(draft) && !isDeleted(draft) && draft.hasRichText && draft.body === draft.originalBody;
const bodyLocked = () => keepsAppFormatting() && !unlockedFormatting.has(draft.id);
$('unlock-format').onclick = () => {
  if (!draft) return;
  unlockedFormatting.add(draft.id); renderNoteState();
  rich.focus();
};
// Clicking or tapping the text unlocks it too, with the caret where it landed:
// the editor turns editable before the browser handles the press. Only an
// actual change replaces the app's formatting, so a stray click costs nothing.
$('note-body').addEventListener('pointerdown', () => {
  if (!bodyLocked()) return;
  unlockedFormatting.add(draft.id); renderNoteState();
}, true);
function renderNoteState() {
  if (!draft) return;
  const trashed = isDeleted(draft), locked = bodyLocked();
  $('pin-note').setAttribute('aria-pressed', String(isPinned(draft)));
  $('pin-note').textContent = isPinned(draft) ? '★' : '☆';
  $('pin-note').title = isPinned(draft) ? 'Unpin' : 'Pin to top';
  // A note in Trash is read-only until it's restored.
  document.querySelector('.editor-pane').classList.toggle('in-trash', trashed);
  $('restore-note').hidden = !trashed;
  $('purge-note').hidden = !trashed || !features.permanentDelete;
  // TaskFlow: trashing a drawing note from the web would lose the drawing.
  $('trash-note').disabled = !canTrash(draft);
  $('trash-note').title = canTrash(draft) ? 'Move to Trash' : `Move drawing notes to Trash in the ${APP} app, so the drawing isn’t lost`;
  document.querySelector('.editor-pane').classList.toggle('body-locked', locked);
  // The notice stays until the text is changed, so a click-to-edit still sees it.
  $('format-lock').hidden = !keepsAppFormatting(); $('unlock-format').hidden = !locked;
  if (rich.isEnabled() === (trashed || locked)) rich.enable(!(trashed || locked));
  $('note-title').readOnly = trashed; $('note-folder').disabled = trashed;
  renderBadges(); renderInfo(); renderDone();
}
/// Small labels above the title for what the page can't show or change.
function renderBadges() {
  const badges = [];
  if (isDeleted(draft)) badges.push(['In Trash', 'Restore this note to edit it.', 'trash']);
  badges.push(...noteBadges(draft, {locked: keepsAppFormatting()}));
  const files = draft.attachments?.length ?? 0;
  if (files) badges.push([`📎 ${files} ${files === 1 ? 'attachment' : 'attachments'}`, `Attachments stay in the ${APP} app, and edits here keep them.`]);
  $('note-badges').replaceChildren(...badges.map(([text, title, kind]) => {
    const badge = document.createElement('span'); badge.className = 'badge' + (kind ? ' ' + kind : '');
    badge.textContent = text; badge.title = title; badge.tabIndex = 0; badge.setAttribute('aria-label', `${text}. ${title}`);
    return badge;
  }));
  $('note-badges').hidden = !badges.length;
}

// MARK: - Info

function formatDate(value) {
  const date = value ? new Date(value) : null;
  return date && !isNaN(date) ? date.toLocaleString(undefined, {dateStyle: 'medium', timeStyle: 'short'}) : '—';
}
/// Which device last saved the note to iCloud. Edits made on an iPad or Mac
/// reach the web through the iPhone that syncs them, so they show its name.
function savedFrom(note) {
  if (isDemo()) return 'This tab';
  const device = note.record?.modified?.deviceID;
  if (!note.record) return 'Not saved yet';
  return device === 'iCloud' ? 'The web' : device || '—';
}
function renderInfo() {
  if ($('info-panel').hidden || !draft) return;
  const text = rich.getText().trim(), title = draft.title.trim();
  const words = `${title} ${text}`.trim().split(/\s+/).filter(Boolean).length;
  const rows = [
    ['Created', formatDate(draft.createdAt)],
    ['Modified', formatDate(draft.modifiedAt)],
    ['Saved from', savedFrom(draft)],
    ['Words', words.toLocaleString()],
    ['Characters', (title.length + text.length).toLocaleString()],
    ...(features.folders ? [['Folder', draft.folder || 'None']] : []),
    ['Tags', draft.tags.length ? draft.tags.join(', ') : 'None']
  ];
  if (draft.attachments?.length) rows.push(['Attachments', String(draft.attachments.length)]);
  if (isPinned(draft)) rows.push(['Pinned', formatDate(draft.pinnedAt)]);
  if (isDeleted(draft)) rows.push(['In Trash since', formatDate(draft.deletedAt)]);
  $('info-list').replaceChildren(...rows.flatMap(([term, value]) => {
    const dt = document.createElement('dt'); dt.textContent = term;
    const dd = document.createElement('dd'); dd.textContent = value;
    return [dt, dd];
  }));
}
function setInfoOpen(open) {
  $('info-panel').hidden = !open; $('info-button').setAttribute('aria-expanded', String(open));
  renderInfo();
}
$('info-button').onclick = () => setInfoOpen($('info-panel').hidden);
document.addEventListener('mousedown', event => {
  if (!$('info-panel').hidden && !$('info-panel').contains(event.target) && !$('info-button').contains(event.target)) setInfoOpen(false);
});
function openNote(note, {recovered = false} = {}) {
  draft = structuredClone(note); revision++; pendingRemote = null; orderLock = null; closeLinkBar(false); setInfoOpen(false);
  dirty = recovered;
  try { sessionStorage.setItem(reopenKey, note.id); } catch { /* Only used to reopen after an update. */ }
  $('remote-change').hidden = true;
  $('empty-selection').hidden = true; $('editor').hidden = false; document.querySelector('.editor-pane').classList.add('has-note');
  $('workspace').classList.add('show-editor');
  $('note-title').value = draft.title; fitTitle();
  $('note-folder').value = draft.folder ?? '';
  rich.setContents(markdownToDelta(draft.body), 'silent'); rich.getModule('history').clear();
  $('tag-input').value = '';
  renderTagPills(); renderNoteState(); updateFormatState();
  $('editor').scrollTop = 0;
  setSaveState(dirty ? 'Recovered unsaved changes' : '');
  scheduleRender();
}
function closeEditor() {
  draft = null; dirty = false; pendingRemote = null; orderLock = null; closeLinkBar(false); setInfoOpen(false);
  document.querySelector('.editor-pane').classList.remove('in-trash', 'body-locked'); $('format-lock').hidden = true;
  $('editor').hidden = true; $('empty-selection').hidden = false; $('remote-change').hidden = true;
  document.querySelector('.editor-pane').classList.remove('has-note');
  $('workspace').classList.remove('show-editor');
  try { sessionStorage.removeItem(reopenKey); } catch { /* Only used to reopen after an update. */ }
  setSaveState('');
  scheduleRender();
}
async function selectNote(id) {
  if (id === draft?.id) { $('workspace').classList.add('show-editor'); return; }
  const currentSession = session;
  if (dirty && !await flush()) return;
  if (session !== currentSession || !provider) return;
  discardUnusedNewNote();
  const note = notes.find(item => item.id === id);
  if (note) openNote(note);
}
function changed() {
  if (!draft) return;
  dirty = true; revision++; lastInput = Date.now(); unsavedNewID = null;
  if (!orderLock) orderLock = new Map(shownOrder.map((id, index) => [id, index]));
  stash(); upsert(draft); renderNoteState(); setSaveState('Edited');
  scheduleRender();
  clearTimeout(retryTimer); clearTimeout(saveTimer); saveTimer = setTimeout(flush, SAVE_DELAY);
}
rich.on('text-change', (_, __, source) => { if (source === 'user' && draft) { draft.body = deltaToMarkdown(rich.getContents()); changed(); } });
/// The title is one line that wraps: it grows to fit, and pasted line breaks become spaces.
function fitTitle() {
  const title = $('note-title'); title.style.height = 'auto';
  if (title.scrollHeight) title.style.height = title.scrollHeight + 'px';
}
$('note-title').addEventListener('input', () => {
  const title = $('note-title');
  if (/[\r\n]/.test(title.value)) title.value = title.value.replace(/\s*[\r\n]+\s*/g, ' ');
  fitTitle();
  if (draft) { draft.title = title.value; changed(); }
});
window.addEventListener('resize', () => { if (draft) fitTitle(); });
$('note-title').addEventListener('keydown', event => {
  if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); rich.focus(); rich.setSelection(0, 0, 'silent'); }
});

// MARK: - Folder (profile feature "folders")

/// Typing or choosing a folder files the note there; clearing it unfiles it.
function commitFolder() {
  if (!features.folders || !draft || isDeleted(draft)) return;
  const folder = $('note-folder').value.replace(/\s+/g, ' ').trim().slice(0, 60);
  $('note-folder').value = folder;
  if (folder === (draft.folder ?? '')) return;
  draft.folder = folder; changed(); orderLock = null;
}
$('note-folder').addEventListener('change', commitFolder);
$('note-folder').addEventListener('keydown', event => { if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); commitFolder(); rich.focus(); } });

// MARK: - Tags

function cleanTag(raw) { return raw.replace(/^#+/, '').replace(/\s+/g, ' ').trim().slice(0, 60); }
function addTag(raw) {
  const tag = cleanTag(raw);
  if (!draft || !tag) return;
  // Reuse an existing tag's spelling so "Work" and "work" stay one tag.
  const existing = liveTags().map(([name]) => name).find(name => name.toLocaleLowerCase() === tag.toLocaleLowerCase()) ?? tag;
  if (draft.tags.some(name => name.toLocaleLowerCase() === existing.toLocaleLowerCase())) return;
  draft.tags = [...draft.tags, existing]; renderTagPills(); changed();
}
function removeTag(tag) {
  if (!draft) return;
  draft.tags = draft.tags.filter(name => name !== tag); renderTagPills(); changed();
  $('tag-input').focus();
}
$('tag-input').addEventListener('keydown', event => {
  const input = $('tag-input');
  if ((event.key === 'Enter' || event.key === ',' || event.key === 'Tab') && input.value.trim() && !event.isComposing) {
    event.preventDefault(); addTag(input.value); input.value = '';
  } else if (event.key === 'Backspace' && !input.value && draft?.tags.length) {
    removeTag(draft.tags[draft.tags.length - 1]);
  }
});
// Choosing a suggestion fills the field without a key press.
$('tag-input').addEventListener('input', event => {
  const input = $('tag-input');
  if (event.inputType === 'insertReplacementText' || (!event.inputType && input.value)) { addTag(input.value); input.value = ''; }
});
$('tag-input').addEventListener('blur', () => { const input = $('tag-input'); if (input.value.trim()) { addTag(input.value); input.value = ''; } });

// MARK: - Managing tags

/// Rename, merge or remove a tag on every note. Renaming to a tag that already
/// exists (ignoring capitals) merges into that spelling. Each note is saved on
/// its own through the provider, so a conflict or failure affects only that
/// note and is reported.
let tagWork = false;
function tagCounts() {
  const counts = new Map();
  for (const note of notes) if (!isPurged(note)) for (const tag of note.tags) counts.set(tag, (counts.get(tag) ?? 0) + 1);
  return [...counts].sort(([a], [b]) => a.localeCompare(b, undefined, {sensitivity: 'base'}));
}
function renderTagManager() {
  const rows = tagCounts().map(([tag, count]) => {
    const row = document.createElement('div'); row.className = 'tag-row';
    const dot = document.createElement('span'); dot.className = 'tag-dot'; dot.style.setProperty('--tag', colorOf(tag)); dot.setAttribute('aria-hidden', 'true');
    const input = document.createElement('input'); input.value = tag; input.setAttribute('aria-label', `Rename tag ${tag}`); input.disabled = tagWork; input.autocomplete = 'off';
    const commit = () => { if (cleanTag(input.value) !== tag) renameTagEverywhere(tag, input.value); else input.value = tag; };
    input.addEventListener('keydown', event => {
      if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); commit(); }
      else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); input.value = tag; }
    });
    input.addEventListener('blur', commit);
    const used = document.createElement('span'); used.className = 'count'; used.textContent = `${count} ${count === 1 ? 'note' : 'notes'}`;
    const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'text-button danger'; remove.textContent = 'Remove'; remove.disabled = tagWork;
    // A second press confirms, so a stray click can't strip a tag from every note.
    remove.onclick = () => {
      if (remove.dataset.armed) { removeTagEverywhere(tag); return; }
      remove.dataset.armed = '1'; remove.textContent = `Remove from ${count} ${count === 1 ? 'note' : 'notes'}?`;
      setTimeout(() => { if (remove.isConnected) { delete remove.dataset.armed; remove.textContent = 'Remove'; } }, 4000);
    };
    row.append(dot, input, used, remove);
    return row;
  });
  const empty = document.createElement('p'); empty.className = 'muted'; empty.textContent = 'No tags yet.';
  $('tag-manager').replaceChildren(...(rows.length ? rows : [empty]));
}
function openTagManager() {
  if (!provider) return;
  $('tag-dialog-status').textContent = ''; $('tag-dialog-status').classList.remove('error');
  renderTagManager(); $('tag-dialog').showModal();
}
$('tags-edit').onclick = openTagManager;
$('tag-dialog-done').onclick = () => $('tag-dialog').close();
async function renameTagEverywhere(from, raw) {
  const wanted = cleanTag(raw);
  if (!wanted) { renderTagManager(); return; }
  const into = tagCounts().map(([tag]) => tag).find(tag => tag !== from && tag.toLocaleLowerCase() === wanted.toLocaleLowerCase()) ?? wanted;
  const merging = into !== wanted || tagCounts().some(([tag]) => tag === into && tag !== from);
  await retagNotes(from, tags => [...new Set(tags.map(tag => tag === from ? into : tag))],
    merging ? `Merged #${from} into #${into} on` : `Renamed #${from} to #${into} on`, into);
}
async function removeTagEverywhere(from) {
  await retagNotes(from, tags => tags.filter(tag => tag !== from), `Removed #${from} from`, null);
}
async function retagNotes(from, transform, doneText, renamedTo) {
  if (!provider || tagWork) return;
  if (conflict || (dirty && !await flush())) { $('tag-dialog-status').textContent = 'Save or resolve the open note first.'; return; }
  const currentSession = session;
  const targets = notes.filter(note => !isPurged(note) && note.tags.includes(from));
  tagWork = true; renderTagManager();
  $('tag-dialog-status').classList.remove('error');
  let done = 0, failed = 0;
  for (const note of targets) {
    $('tag-dialog-status').textContent = `${doneText.split(' ')[0].replace(/ed$/, 'ing')}… ${done + failed + 1} of ${targets.length}`;
    dropLegacySession();
    try {
      const saved = await provider.save({...note, tags: transform(note.tags)});
      if (session !== currentSession) return;
      upsert(saved); done++;
      // The open note takes the new tags and the version just saved.
      if (draft?.id === note.id && !dirty) { draft.tags = saved.tags; draft.record = saved.record; draft.modifiedAt = saved.modifiedAt; renderTagPills(); }
    } catch (error) {
      if (session !== currentSession) return;
      failed++;
      if (needsSignIn(error)) { showReauth(); break; }
    }
  }
  tagWork = false;
  if (view.kind === 'tag' && view.tag === from) view = renamedTo ? {kind: 'tag', tag: renamedTo, folder: ''} : {kind: 'all', tag: '', folder: ''};
  scheduleRender(); renderTagManager();
  $('tag-dialog-status').textContent = failed
    ? `${doneText} ${done} ${done === 1 ? 'note' : 'notes'}; ${failed} couldn’t be saved (sync and try again).`
    : `${doneText} ${done} ${done === 1 ? 'note' : 'notes'}.`;
  $('tag-dialog-status').classList.toggle('error', failed > 0);
}

// MARK: - Formatting

function updateFormatState() {
  const range = rich.getSelection();
  const format = range ? rich.getFormat(range) : {};
  const active = {bold: !!format.bold, italic: !!format.italic, heading: !!format.header,
    bullet: format.list === 'bullet', number: format.list === 'ordered', checklist: format.list === 'checked' || format.list === 'unchecked'};
  for (const button of document.querySelectorAll('[data-format]')) button.setAttribute('aria-pressed', String(!!active[button.dataset.format]));
  $('link-button').setAttribute('aria-pressed', String(!!format.link));
}
rich.on('selection-change', updateFormatState);
// Shortcuts are written for the Mac in the page; other systems use Ctrl.
if (!/Mac|iPhone|iPad/.test(navigator.platform)) for (const button of document.querySelectorAll('[data-keys]')) button.dataset.keys = button.dataset.keys.replace(/^⌘(\w)$/, 'Ctrl+$1');
for (const button of document.querySelectorAll('[data-format]')) {
  button.addEventListener('mousedown', event => event.preventDefault());
  button.addEventListener('click', () => {
    if (!draft) return;
    const range = rich.getSelection(true), format = rich.getFormat(range), action = button.dataset.format;
    if (action === 'bold' || action === 'italic') rich.format(action, !format[action], 'user');
    else if (action === 'heading') rich.formatLine(range.index, range.length, 'header', format.header ? false : 2, 'user');
    else {
      const value = {bullet: 'bullet', number: 'ordered', checklist: 'unchecked'}[action];
      const on = action === 'checklist' ? format.list === 'checked' || format.list === 'unchecked' : format.list === value;
      rich.formatLine(range.index, range.length, 'list', on ? false : value, 'user');
    }
    updateFormatState();
  });
}

// MARK: - Completed checklist items

/// Checked items can be hidden while reading or working through a list. The
/// choice is this browser's, for every note; the text itself is untouched.
const hideDoneKey = STORE + 'hideDone';
let hideDone = storage.get(hideDoneKey) === '1';
function renderDone() {
  if (!draft) return;
  const done = (draft.body.match(/^\s*[-*+]\s+\[[xX]\]/gm) ?? []).length;
  const hiding = hideDone && done > 0;
  $('hide-done').hidden = !done;
  $('hide-done').setAttribute('aria-pressed', String(hiding));
  $('hide-done').title = $('hide-done').ariaLabel = hiding ? 'Show completed items' : `Hide ${done} completed ${done === 1 ? 'item' : 'items'}`;
  $('editor').classList.toggle('hide-done', hiding);
  $('done-hidden').hidden = !hiding;
  $('done-hidden-text').textContent = `${done} completed ${done === 1 ? 'item' : 'items'} hidden.`;
}
function setHideDone(value) { hideDone = value; storage.set(hideDoneKey, value ? '1' : '0'); renderDone(); }
$('hide-done').onclick = () => setHideDone(!hideDone);
$('done-show').onclick = () => setHideDone(false);

// MARK: - Links

/// The link run around a position, so a cursor inside a link edits all of it.
function linkExtent(index) {
  let position = 0;
  for (const op of rich.getContents().ops) {
    const length = typeof op.insert === 'string' ? op.insert.length : 1;
    if (op.attributes?.link && index >= position && index <= position + length) return {index: position, length};
    position += length;
  }
  return null;
}
let linkRange = null;
function openLinkBar() {
  if (!draft || isDeleted(draft) || bodyLocked()) return;
  const range = rich.getSelection(true);
  linkRange = range.length ? range : linkExtent(range.index) ?? range;
  const current = linkRange.length ? rich.getFormat(linkRange).link : null;
  $('link-input').value = current || ''; $('link-input').classList.remove('error');
  $('link-remove').hidden = !current;
  $('link-form').hidden = false; $('link-input').focus(); $('link-input').select();
}
function closeLinkBar(refocus = true) {
  if ($('link-form').hidden) return;
  $('link-form').hidden = true;
  if (refocus && linkRange) { rich.focus(); rich.setSelection(linkRange.index + linkRange.length, 0, 'silent'); }
  linkRange = null;
}
$('link-button').addEventListener('mousedown', event => event.preventDefault());
$('link-button').onclick = () => $('link-form').hidden ? openLinkBar() : closeLinkBar();
$('link-form').addEventListener('submit', event => {
  event.preventDefault();
  if (!draft || !linkRange) return;
  const raw = $('link-input').value.trim();
  const href = linkTarget(raw) ?? (/^[^\s:/]+\.[^\s]+$/.test(raw) ? linkTarget('https://' + raw) : null);
  if (!href) { $('link-input').classList.add('error'); return; }
  if (linkRange.length) rich.formatText(linkRange.index, linkRange.length, 'link', href, 'user');
  else { rich.insertText(linkRange.index, raw, {link: href}, 'user'); linkRange = {index: linkRange.index, length: raw.length}; }
  closeLinkBar();
});
$('link-remove').onclick = () => { if (linkRange?.length) rich.formatText(linkRange.index, linkRange.length, 'link', false, 'user'); closeLinkBar(); };
$('link-input').addEventListener('keydown', event => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeLinkBar(); } });
/// Addresses typed as text become links once the cursor has moved past them.
/// They are saved as plain text, so the app sees exactly what was typed.
let autolinkTimer;
function autolink() {
  if (!draft) return;
  const text = rich.getText(), cursor = rich.getSelection()?.index ?? -1;
  for (const match of text.matchAll(URL_PATTERN)) {
    const start = match.index, end = start + match[0].length;
    if (cursor >= start && cursor <= end) continue;
    const href = linkTarget(match[0]);
    if (href && rich.getFormat(start, match[0].length).link !== href) rich.formatText(start, match[0].length, 'link', href, 'silent');
  }
}
rich.on('text-change', (_, __, source) => { if (source === 'user') { clearTimeout(autolinkTimer); autolinkTimer = setTimeout(autolink, 400); } });
const openKey = /Mac|iPhone|iPad/.test(navigator.platform) ? '⌘' : 'Ctrl';
rich.root.addEventListener('click', event => {
  const anchor = event.target.closest('a');
  if (!anchor || !(event.metaKey || event.ctrlKey || matchMedia('(hover: none)').matches)) return;
  event.preventDefault();
  const href = safeLink(anchor.getAttribute('href'));
  if (href) window.open(href, '_blank', 'noopener,noreferrer');
});
rich.root.addEventListener('mouseover', event => {
  const anchor = event.target.closest('a');
  if (anchor) anchor.title = `${anchor.getAttribute('href')}\n${openKey}-click to open`;
});
for (const type of ['keydown', 'keyup']) document.addEventListener(type, event => document.body.classList.toggle('open-links', event.metaKey || event.ctrlKey));
window.addEventListener('blur', () => document.body.classList.remove('open-links'));

// MARK: - Images and files

const IMAGE_MESSAGE = `Images can’t be added on the web yet. Add them to this note in the ${APP} app.`;
let toastTimer;
/// A short message at the bottom; with `action`, a button such as Undo.
function showToast(text, action = null) {
  const message = document.createElement('span'); message.textContent = text;
  $('toast').replaceChildren(message);
  if (action) {
    const button = document.createElement('button'); button.type = 'button'; button.textContent = action.label;
    button.onclick = () => { $('toast').hidden = true; action.run(); };
    $('toast').append(button);
  }
  $('toast').hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, action ? 8000 : 5000);
}
const carriesImage = data => [...(data?.files ?? [])].some(file => file.type.startsWith('image/')) ||
  [...(data?.items ?? [])].some(item => item.kind === 'file' && item.type.startsWith('image/')) ||
  /<img[\s>]/i.test(data?.getData?.('text/html') ?? '');
// Text still pastes; only the images are left out, so say so.
rich.root.addEventListener('paste', event => { if (draft && carriesImage(event.clipboardData)) showToast(IMAGE_MESSAGE); }, true);
// A file dropped on the page would otherwise open in the tab, leaving it.
const carriesFiles = event => [...(event.dataTransfer?.types ?? [])].includes('Files');
document.addEventListener('dragover', event => { if (carriesFiles(event)) event.preventDefault(); });
document.addEventListener('drop', event => {
  if (!carriesFiles(event)) return;
  event.preventDefault(); event.stopPropagation();
  if (draft) showToast(carriesImage(event.dataTransfer) ? IMAGE_MESSAGE : `Files can’t be added on the web yet. Add them in the ${APP} app.`);
}, true);

// MARK: - Saving

async function flush() {
  clearTimeout(saveTimer);
  if (savePromise) return savePromise;
  if (!dirty || !draft) return true;
  if (conflict) { if (!$('conflict-dialog').open) $('conflict-dialog').showModal(); return false; }
  const currentSession = session, currentProvider = provider;
  const operation = (async () => {
    while (dirty && draft) {
      const captured = structuredClone(draft), capturedRevision = revision;
      setSaveState('Saving…');
      dropLegacySession();
      try {
        const saved = await currentProvider.save(captured);
        if (session !== currentSession) return false;
        if (draft?.id === captured.id) {
          // Only what iCloud stored is taken from the save: the editor keeps
          // whatever was typed while it was in flight.
          draft.record = saved.record; draft.modifiedAt = saved.modifiedAt;
          draft.hasRichText = saved.hasRichText; draft.originalBody = captured.body;
          if (revision === capturedRevision) { dirty = false; clearStash(captured.id); }
          upsert(draft); renderNoteState();
        } else { upsert(saved); clearStash(captured.id); }
        retryAttempt = 0; clearTimeout(retryTimer);
        scheduleRender();
        setSaveState(dirty ? 'Edited' : savedText());
        setSyncStatus(syncedText());
      } catch (error) {
        if (session !== currentSession) return false;
        stash();
        if (error instanceof NoteConflict) { setSaveState(error.message, true); await showConflict(captured.id, currentSession, currentProvider); }
        else if (needsSignIn(error)) { setSaveState('Not saved · signed out', true, 'Signed out of iCloud. Your changes are safe in this tab.'); showReauth(); }
        else if (error?.code === 'TOO_LARGE') setSaveState(error.message, true);
        else scheduleRetry(error);
        return false;
      }
    }
    return true;
  })();
  savePromise = operation;
  const succeeded = await operation;
  if (savePromise === operation) savePromise = null;
  return succeeded;
}
/// A failed save tries again after 2, 4, 8… seconds (at most 30), and at once
/// when the connection returns. Typing schedules its own save instead.
function scheduleRetry(error) {
  retryAttempt++;
  const delay = Math.min(30_000, 2000 * 2 ** (retryAttempt - 1));
  const reason = error?.message || 'iCloud didn’t accept the save.';
  if (navigator.onLine) setSaveState(`Not saved · retrying in ${Math.round(delay / 1000)}s`, true, reason);
  else setSaveState('Offline · saves when you reconnect', true, 'Your changes are kept in this tab and save when you reconnect.');
  clearTimeout(retryTimer); retryTimer = setTimeout(flush, delay);
}
async function showConflict(id, currentSession, currentProvider) {
  try {
    dropLegacySession();
    const remote = await currentProvider.latest(id);
    if (session !== currentSession) return;
    conflict = {local: structuredClone(draft), remote};
    $('conflict-local').textContent = [conflict.local.title, conflict.local.body].filter(Boolean).join('\n\n');
    $('conflict-remote').textContent = (isDeleted(remote) ? 'Moved to Trash elsewhere.\n\n' : '') + [remote.title, remote.body].filter(Boolean).join('\n\n');
    $('conflict-dialog').showModal();
  } catch { if (session === currentSession) setSaveState('Couldn’t get the other version. Your changes are still here.', true); }
}
async function resolveConflict(choice) {
  if (!conflict || resolving) return;
  resolving = true;
  const currentSession = session, currentProvider = provider, {local, remote} = conflict;
  try {
    if (choice === 'both') {
      const now = new Date().toISOString();
      const copy = {...local, id: crypto.randomUUID().toUpperCase(), title: (local.title || 'Untitled Note') + ' (My Edit)', record: undefined,
        deletedAt: null, pinnedAt: null, createdAt: now, hasRichText: false, originalBody: local.body, attachments: []};
      try { const saved = await currentProvider.save(copy); if (session !== currentSession) return; upsert(saved); }
      catch (error) { if (session === currentSession) setSaveState(error.message, true); return; }
    }
    clearStash(local.id); conflict = null; $('conflict-dialog').close();
    if (choice === 'mine') {
      draft = {...local, record: remote.record, hasRichText: remote.hasRichText, originalBody: remote.originalBody};
      dirty = true; revision++; stash(); await flush();
    } else { dirty = false; upsert(remote); openNote(remote); }
  } finally { if (session === currentSession) resolving = false; }
}
$('keep-both').onclick = () => resolveConflict('both');
$('keep-other').onclick = () => resolveConflict('other');
$('keep-mine').onclick = () => resolveConflict('mine');
$('conflict-cancel').onclick = () => $('conflict-dialog').close();

// MARK: - Updates

/// A tab left open keeps running the code it loaded. Each sync checks the
/// deployed version; an idle tab reloads (reopening its note), and a busy one
/// says so and reloads when asked.
const reopenKey = STORE + 'reopen';
let updateReady = false;
async function checkForUpdate() {
  const loaded = window.NOTES_CONFIG?.version;
  if (!loaded) return;
  if (!updateReady) {
    try {
      const response = await fetch((profile.base ?? '/') + 'version.json', {cache: 'no-store'});
      const {version} = response.ok ? await response.json() : {};
      updateReady = Boolean(version) && version !== loaded;
    } catch { return; }
  }
  if (!updateReady) return;
  if (!isDemo() && !dirty && !savePromise && !conflict && !isEditing()) location.reload();
  else $('update-banner').hidden = false;
}
$('update-reload').onclick = async () => { if (dirty && !await flush()) return; location.reload(); };

// MARK: - Background sync

/// Whether the open note is in use: focused, recently typed in, or unsaved.
function isEditing() {
  return dirty || !!savePromise || $('editor').contains(document.activeElement) || Date.now() - lastInput < EDITING_GRACE;
}
async function refresh({manual = false} = {}) {
  if (!provider || refreshing || conflict) return;
  // Unsaved typing is saved by its own timer; background sync waits for it.
  if (dirty || savePromise) { if (!manual || !await flush()) return; }
  refreshing = true;
  const currentSession = session, currentProvider = provider, currentRevision = revision;
  if (manual) setSyncStatus('Syncing…');
  dropLegacySession();
  try {
    const fetched = await currentProvider.list();
    // Anything typed or opened while the request was out wins over its result.
    if (session !== currentSession || revision !== currentRevision || dirty || savePromise) return;
    notes = fetched;
    if (!isEditing()) orderLock = null;
    if (draft) {
      const remote = notes.find(note => note.id === draft.id);
      if (!remote) upsert(draft);
      else if (remote.record?.recordChangeTag !== draft.record?.recordChangeTag) {
        if (isPurged(remote) && !dirty) closeEditor();
        else if (isEditing()) { upsert(draft); pendingRemote = remote; $('remote-change').hidden = false; }
        else openNote(remote);
      }
    }
    scheduleRender();
    if (draft) renderTagPills(); // Tag colours may have changed in the app.
    setSyncStatus(syncedText());
    checkForUpdate();
  } catch (error) {
    if (session !== currentSession) return;
    if (needsSignIn(error)) showReauth();
    else setSyncStatus(error?.message || 'Couldn’t sync. Your notes are still here.', true);
  } finally { if (session === currentSession) refreshing = false; }
}
// The list holds the open draft, so the newer version comes from pendingRemote itself.
$('show-latest').onclick = () => { if (pendingRemote && !dirty) { const remote = pendingRemote; upsert(remote); openNote(remote); } };
$('refresh').onclick = () => refresh({manual: true});
window.addEventListener('online', async () => {
  if (!provider) return;
  retryAttempt = 0;
  if (dirty) await flush();
  refresh();
});
window.addEventListener('offline', () => { if (provider) setSyncStatus('Offline — changes save when you reconnect.', true); });
window.addEventListener('focus', () => refresh());
setInterval(() => { if (!document.hidden) refresh(); }, REFRESH_INTERVAL);

// MARK: - Note actions

$('new-note').onclick = async () => {
  if (dirty && !await flush()) return;
  discardUnusedNewNote();
  if (view.kind === 'trash' || view.kind === 'untagged') view = {kind: 'all', tag: '', folder: ''};
  const note = newNote();
  if (view.kind === 'tag') note.tags = [view.tag];
  if (view.kind === 'folder') note.folder = view.folder;
  $('search').value = '';
  upsert(note); openNote(note); unsavedNewID = note.id;
  $('note-title').focus();
};
// Pinning is a deliberate move, so the list re-sorts right away.
$('pin-note').onclick = () => { if (!draft) return; draft.pinnedAt = isPinned(draft) ? null : new Date().toISOString(); changed(); orderLock = null; scheduleRender(); };
$('trash-note').onclick = async () => {
  if (!draft || isDeleted(draft) || !canTrash(draft)) return;
  if (unsavedNewID === draft.id && !dirty) { discardUnusedNewNote(); closeEditor(); return; }
  const id = draft.id;
  draft.deletedAt = new Date().toISOString();
  changed();
  if (await flush()) { closeEditor(); showToast('Moved to Trash.', {label: 'Undo', run: () => undoTrash(id)}); }
};
async function undoTrash(id) {
  const note = notes.find(item => item.id === id);
  if (!provider || !note || !isDeleted(note) || isPurged(note)) return;
  if (dirty && !await flush()) return;
  dropLegacySession();
  try {
    const saved = await provider.save({...note, deletedAt: null});
    upsert(saved);
    if (view.kind === 'trash') view = {kind: 'all', tag: '', folder: ''};
    discardUnusedNewNote(); openNote(saved);
  } catch (error) {
    if (needsSignIn(error)) showReauth();
    else setSyncStatus(`${error?.message || 'Couldn’t undo.'} The note is in Trash.`, true);
  }
}
$('restore-note').onclick = async () => {
  if (!draft || !isDeleted(draft)) return;
  draft.deletedAt = null;
  changed(); renderNoteState();
  if (await flush()) showToast('Restored to All Notes.');
};
let purgeTargets = [];
function confirmPurge(targets) {
  if (!targets.length) return;
  purgeTargets = targets;
  const one = targets.length === 1;
  $('purge-title').textContent = one ? `Delete “${cardText(targets[0]).title}” permanently?` : `Delete ${targets.length} notes permanently?`;
  $('purge-text').textContent = `${one ? 'It’s' : 'They’re'} removed from ${APP} on all your devices and the web. This can’t be undone.`;
  $('purge-dialog').showModal();
}
$('purge-note').onclick = () => { if (draft && isDeleted(draft)) confirmPurge([notes.find(note => note.id === draft.id) ?? draft]); };
$('empty-trash').onclick = () => confirmPurge(notes.filter(note => isDeleted(note) && !isPurged(note)));
$('purge-cancel').onclick = () => $('purge-dialog').close();
$('purge-confirm').onclick = async () => { $('purge-dialog').close(); await purgeNotes(purgeTargets); purgeTargets = []; };
/// Saves each note as an empty, purged tombstone (see `purgedNote`). A note
/// that changed elsewhere in the meantime is left alone for this round.
async function purgeNotes(targets) {
  if (!provider || !targets.length) return;
  if (dirty && !await flush()) return;
  const currentSession = session;
  setSyncStatus('Deleting…');
  let deleted = 0, failed = 0;
  for (const note of targets) {
    dropLegacySession();
    try {
      const saved = await provider.save(purgedNote(note));
      if (session !== currentSession) return;
      upsert(saved); clearStash(note.id); deleted++;
      if (draft?.id === note.id) closeEditor();
    } catch (error) {
      if (session !== currentSession) return;
      failed++;
      if (needsSignIn(error)) { showReauth(); break; }
    }
  }
  scheduleRender();
  if (failed) setSyncStatus(`${failed} ${failed === 1 ? 'note' : 'notes'} couldn’t be deleted. Sync and try again.`, true);
  else setSyncStatus(syncedText());
  if (deleted) showToast(deleted === 1 ? 'Deleted permanently.' : `${deleted} notes deleted permanently.`);
}
$('download-draft').onclick = () => {
  if (!draft) return;
  const url = URL.createObjectURL(new Blob([(draft.title ? '# ' + draft.title + '\n\n' : '') + draft.body], {type: 'text/markdown'}));
  const anchor = document.createElement('a'); anchor.href = url; anchor.download = `${APP} note.md`; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
};
$('search').addEventListener('input', () => { orderLock = null; suggestionIndex = 0; scheduleRender(); renderSuggestions(); });
for (const item of document.querySelectorAll('.nav-item[data-view]')) item.addEventListener('click', () => showView({kind: item.dataset.view, tag: '', folder: ''}));
$('back').onclick = () => { if (dirty) flush(); $('workspace').classList.remove('show-editor'); };

// MARK: - Layout and appearance

function closeSidebar() { $('workspace').classList.remove('sidebar-open'); $('scrim').hidden = true; }
$('sidebar-toggle').onclick = () => { $('workspace').classList.add('sidebar-open'); $('scrim').hidden = false; };
$('scrim').onclick = closeSidebar;
const themeKey = STORE + 'theme';
function readTheme() { try { return localStorage.getItem(themeKey); } catch { return null; } }
const isDark = () => { const saved = readTheme(); return saved === 'dark' || (!saved && matchMedia('(prefers-color-scheme: dark)').matches); };
function applyTheme() {
  const saved = readTheme();
  if (saved) document.documentElement.dataset.theme = saved; else delete document.documentElement.dataset.theme;
  $('theme-toggle').textContent = isDark() ? '☀' : '◐';
  document.querySelector('meta[name="theme-color"]').content = isDark() ? profile.themeColors?.dark ?? '#1c1c1e' : profile.themeColors?.light ?? '#f6f6f7';
}
$('theme-toggle').onclick = () => {
  try { localStorage.setItem(themeKey, isDark() ? 'light' : 'dark'); } catch { /* Private browsing keeps the system look. */ }
  applyTheme();
};
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);
applyTheme();
document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 's') { event.preventDefault(); flush(); }
  else if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 'k' && rich.hasFocus()) { event.preventDefault(); openLinkBar(); }
  else if (event.key === 'Escape') { closeSidebar(); setInfoOpen(false); }
});
window.addEventListener('beforeunload', event => { if (dirty) { stash(); event.preventDefault(); event.returnValue = ''; } });
// Switching apps or tabs, locking the screen or closing the tab saves at once
// rather than after the usual pause; the backup covers a save cut short.
function saveNow() { if (dirty) { stash(); flush(); } }
document.addEventListener('visibilitychange', () => { if (document.hidden) saveNow(); else refresh(); });
window.addEventListener('pagehide', () => { saveNow(); storage.remove(TAB_PREFIX + TAB_ID); });

// MARK: - Signing in

async function enterWorkspace(user) {
  if (!$('workspace').hidden && account === user.userRecordName) return;
  if (entering) return entering;
  const operation = initializeWorkspace(user, session);
  entering = operation;
  try { return await operation; } finally { if (entering === operation) entering = null; }
}
async function initializeWorkspace(user, currentSession) {
  if (session !== currentSession || !provider) return;
  account = user.userRecordName;
  const fetched = await provider.list();
  if (session !== currentSession) return;
  notes = fetched;
  $('welcome').hidden = true; $('workspace').hidden = false;
  $('notice').hidden = !isDemo();
  $('notice').textContent = 'Sample notes in this tab only. Nothing is sent to iCloud.';
  setSyncStatus(syncedText());
  scheduleRender();
  // Backups first, so a note reopened below shows its recovered text.
  if (!isDemo()) await recoverBackups(currentSession);
  if (session !== currentSession) return;
  // After an update reload, the note that was open opens again.
  let reopen = null;
  try { reopen = sessionStorage.getItem(reopenKey); } catch { /* Nothing to reopen. */ }
  const previous = !draft && reopen && notes.find(note => note.id === reopen && !isPurged(note));
  if (previous) openNote(previous);
  checkForUpdate();
}
async function loadCloudKit() {
  if (window.CloudKit) return;
  await new Promise((resolve, reject) => {
    const script = document.createElement('script'); script.src = 'https://cdn.apple-cloudkit.com/ck/2/cloudkit.js';
    script.onload = resolve; script.onerror = () => reject(new Error('Apple sign-in couldn’t load. Check your connection and try again.'));
    document.head.append(script);
  });
}
/// A second copy of CloudKit's session cookie on another path makes every
/// request fail ("Could not read or write ckSession"). An older version of
/// Sebastian's page at /sebastian/notes kept its copy on /sebastian, and a tab
/// still open on it writes it back, so that copy (profile.legacyCookiePath) is
/// dropped before each sync.
function dropLegacySession() {
  const config = window.NOTES_CONFIG;
  if (config?.containerIdentifier && profile.legacyCookiePath) document.cookie = `${config.containerIdentifier}=; Max-Age=0; path=${profile.legacyCookiePath}`;
}
let cloudkitContainer = null;
/// The Apple session ended (it expires, or was signed out elsewhere). The
/// notes and any unsaved changes stay on screen; Apple's sign-in button is
/// shown in place, and syncing resumes once it's used.
async function showReauth() {
  if (reauthing || !cloudkitContainer || isDemo() || $('workspace').hidden) return;
  reauthing = true;
  $('reauth-text').textContent = 'Your Apple session ended. Your notes and changes are safe here — sign in again to keep syncing.';
  $('reauth-button').append($('apple-signin'));
  $('reauth').hidden = false;
  setSyncStatus('Signed out of iCloud', true);
  try { await cloudkitContainer.signOut(); } catch { /* Already signed out. */ }
  try {
    const user = await cloudkitContainer.setUpAuth();
    if (user) await finishReauth();
    else cloudkitContainer.whenUserSignsIn().then(finishReauth);
  } catch { $('reauth-text').textContent = 'Apple sign-in couldn’t load. Reload the page; unsaved changes in this tab come back.'; }
}
async function finishReauth() {
  if (!reauthing) return;
  try {
    const user = await provider.connect();
    reauthing = false; $('reauth').hidden = true; $('connect').after($('apple-signin'));
    if (user.userRecordName !== account) {
      // A different Apple Account: show its notes, not this one's.
      reset(); provider = new CloudNotesProvider(cloudkitContainer); await enterWorkspace(user); return;
    }
    retryAttempt = 0;
    if (dirty) await flush();
    refresh({manual: true});
  } catch (error) { $('reauth-text').textContent = error.message; }
}
async function ensureCloudKit() {
  const config = window.NOTES_CONFIG;
  if (!config?.apiToken) return null;
  // CloudKit scopes its session cookie to the page's folder. A page can be
  // reached at more than one URL (Sebastian's at /sebastian/notes and
  // /sebastian/notes/), so settle on the configured one before CloudKit writes.
  const home = new URL(config.websiteURL);
  if (location.pathname !== home.pathname) history.replaceState(history.state, '', home.pathname + location.search + location.hash);
  dropLegacySession();
  await loadCloudKit();
  if (!cloudkitContainer) {
    CloudKit.configure({containers: [{containerIdentifier: config.containerIdentifier, environment: config.environment,
      apiTokenAuth: {apiToken: config.apiToken, persist: true, signInButton: {id: 'apple-signin', theme: 'medium'}, signOutButton: {id: 'apple-signout'}}}]});
    cloudkitContainer = CloudKit.getDefaultContainer();
    cloudkitContainer.whenUserSignsIn().then(async () => {
      try { if (!provider) provider = new CloudNotesProvider(cloudkitContainer); await enterWorkspace(await provider.connect()); }
      catch (error) { $('welcome-error').textContent = error.message; }
    });
    // Only Sign Out clears the page. A session that ends on its own keeps
    // everything on screen and asks to sign in again.
    cloudkitContainer.whenUserSignsOut().then(() => { if (signingOut) reset(); else showReauth(); });
  }
  return cloudkitContainer;
}
$('connect').onclick = async () => {
  $('connect').disabled = true; $('welcome-error').textContent = '';
  try {
    const container = await ensureCloudKit();
    if (!container) { $('welcome-error').textContent = 'iCloud isn’t set up for this copy of the page. You can try the sample notes.'; return; }
    session++; entering = null; refreshing = false; account = '';
    provider = new CloudNotesProvider(container);
    await enterWorkspace(await provider.connect());
  } catch (error) { $('welcome-error').textContent = error.message; provider = null; }
  finally { $('connect').disabled = false; }
};
// A returning visitor is signed in again without a click.
(async () => {
  const currentSession = session;
  try {
    const container = await ensureCloudKit();
    if (!container || session !== currentSession || provider) return;
    provider = new CloudNotesProvider(container);
    await enterWorkspace(await provider.connect());
  } catch { if (session === currentSession && !account) provider = null; }
})();
$('try-demo').onclick = async () => {
  session++; entering = null; refreshing = false; account = '';
  provider = new DemoNotesProvider();
  for (const {title, body, tags = [], folder = ''} of profile.samples ?? []) await provider.save({...newNote(), title, body, tags, ...(features.folders ? {folder} : {})});
  await enterWorkspace(await provider.connect());
};
function reset() {
  session++; revision++; savePromise = null; entering = null; refreshing = false; resolving = false;
  clearTimeout(saveTimer); clearTimeout(retryTimer); clearTimeout(renderFrame); renderFrame = null; retryAttempt = 0;
  signingOut = false; reauthing = false; orderLock = null;
  $('reauth').hidden = true; $('connect').after($('apple-signin'));
  // Signing out leaves nothing of this account in the browser.
  for (const key of storage.keys()) if (key.startsWith(prefix + encodeURIComponent(account) + '.')) storage.remove(key);
  account = ''; notes = []; provider = null; conflict = null; unsavedNewID = null; view = {kind: 'all', tag: '', folder: ''};
  if ($('conflict-dialog').open) $('conflict-dialog').close();
  closeEditor(); closeSidebar();
  $('note-title').value = ''; rich.setText('', 'silent'); rich.getModule('history').clear();
  $('search').value = ''; $('note-list').replaceChildren(); $('tag-nav').replaceChildren(); $('all-tag-nav').replaceChildren(); $('folder-nav').replaceChildren(); $('tag-filter').value = '';
  $('workspace').hidden = true; $('welcome').hidden = false; $('notice').hidden = true;
  setSyncStatus('');
}
$('signout').onclick = async () => {
  if (dirty && !await flush() && !confirm('Your latest changes haven’t saved to iCloud. Sign out and lose them?')) return;
  signingOut = true;
  try { if (isDemo()) reset(); else { await provider.signOut(); reset(); } }
  catch { signingOut = false; setSyncStatus('Couldn’t sign out. Please try again.', true); }
};
