// TaskFlow Notes on the web — records, validation and the iCloud provider.
//
// Each note is one `TaskFlowWebNote` record in the signed-in user's PRIVATE
// CloudKit database (container iCloud.com.surratt.TaskFlow). `payload` is the
// app's `QuickNote` JSON without its drawing and history (see CloudWebNote in
// CloudNotesSyncService.swift); `isDeleted` and `hasDrawing` are record fields.
//
// The page itself (shared/) is shared with Sebastian's web notes; each app's
// core.mjs provides the same exports, mapping its records to one note shape:
//   body       the text as Markdown for the editor (from `text` + `format`)
//   pinnedAt   set when `isPinned`
//   deletedAt  set when the record's `isDeleted` is 1
//   modifiedAt the record's last save
// recordForNote() maps them back. A note whose text wasn't edited keeps its
// original `text` and `format` byte for byte.
import {queryAll} from './shared/records.mjs';

export const recordType = 'TaskFlowWebNote';
export const readinessRecordName = 'TaskFlowWebNotesReady';
export const MAX_BYTES = 600_000;
const UUID_PATTERN = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const FORMATS = ['plain', 'bullets', 'checklist', 'quote', 'markdown'];
const LAYOUTS = ['standard', 'compact', 'prominent'];
const NOT_READY = 'Open the updated TaskFlow app and sync your notes to enable browser access.';

/// An error with CloudKit's code (or this page's own, such as TOO_LARGE), so
/// the page can tell an expired session or a note that can never save from a
/// failure worth retrying.
export class SyncError extends Error {
  constructor(message, code) { super(message); this.code = code; }
}
const authCodes = ['AUTHENTICATION_REQUIRED', 'AUTHENTICATION_FAILED'];
/// Whether an error (from check() or a rejected CloudKit call) means signing in again.
export const needsSignIn = error => authCodes.includes(error?.code ?? error?.ckErrorCode ?? error?.serverErrorCode);

export class NoteConflict extends Error {
  constructor(remote) { super('This note changed elsewhere. Both versions are available.'); this.remote = remote; }
}

export function safeLink(raw) {
  try { const url = new URL(raw); return ['https:', 'http:', 'mailto:'].includes(url.protocol) ? url.href : null; } catch { return null; }
}

/// The app's tag colours (`TaskTagColor`, gray left out) and how it picks one
/// for a tag nobody has coloured (`MetadataSnapshot.defaultColor(for:)`: the
/// sum of the tag's Unicode scalars). Colours chosen in the app arrive in
/// `custom` (see tagColorsFromMetadata).
export const TAG_PALETTE = [
  '#5E5CE6', // indigo
  '#0A84FF', // blue
  '#40C8E0', // teal
  '#63E6E2', // mint
  '#64D2FF', // cyan
  '#30D158', // green
  '#73B824', // lime
  '#FFD60A', // yellow
  '#FF9F0A', // orange
  '#F56152', // coral
  '#FF453A', // red
  '#FF375F', // pink
  '#BF5AF2', // purple
  '#9E75EB', // lavender
  '#2C4F8F', // navy (lightened so it shows on dark backgrounds)
  '#AC8E68', // brown
  '#636366'  // black (a dark gray, so it shows on dark backgrounds)
];
const TAG_COLOR_NAMES = ['indigo', 'blue', 'teal', 'mint', 'cyan', 'green', 'lime', 'yellow', 'orange', 'coral', 'red', 'pink', 'purple', 'lavender', 'navy', 'brown', 'black'];
export function tagColor(tag, custom = {}) {
  const chosen = custom[tag.toLowerCase()];
  if (chosen) return chosen;
  let total = 0;
  for (const character of tag) total += character.codePointAt(0);
  return TAG_PALETTE[total % TAG_PALETTE.length];
}

/// The app keeps the colours chosen for tags in its metadata snapshot (record
/// `TaskFlowMetadataSnapshot`, a JSON `payload` of bytes, `savedTags` inside).
/// Lowercased tag → hex; anything unreadable is left out.
export const METADATA_RECORD = 'TaskFlowMetadataSnapshot';
export function tagColorsFromMetadata(record) {
  try {
    const bytes = Uint8Array.from(atob(record?.fields?.payload?.value ?? ''), character => character.charCodeAt(0));
    const saved = JSON.parse(new TextDecoder().decode(bytes)).savedTags ?? [];
    return Object.fromEntries(saved.flatMap(({name, color} = {}) => {
      const index = TAG_COLOR_NAMES.indexOf(color);
      if (typeof name !== 'string' || !name) return [];
      // Gray isn't offered as a default but can be chosen.
      return color === 'gray' ? [[name.toLowerCase(), '#8E8E93']] : index < 0 ? [] : [[name.toLowerCase(), TAG_PALETTE[index]]];
    }));
  } catch { return {}; }
}

export const isDeleted = note => Boolean(note.deletedAt);
export const isPinned = note => Boolean(note.pinnedAt);
/// The app drops a note's drawing along with the note when it's trashed from
/// the web, so drawing notes are moved to Trash in the app only.
export const canTrash = note => !note.hasDrawing;
/// No permanent delete on this page: the app uploads its copy again when a
/// record disappears, so a deleted note would come back. (profile.json turns
/// the page's permanent-delete feature off; these keep the shared exports.)
export const isPurged = () => false;
export function purgedNote() { throw new SyncError('Delete notes permanently in the TaskFlow app.', 'UNSUPPORTED'); }

/// Labels above the title for what the page can't show or change.
export function noteBadges(note) {
  const badges = [];
  if (note.hasDrawing) badges.push(['✎ Drawing', 'This note has a drawing. It stays in the TaskFlow app, and edits here keep it.']);
  if (note.isResolved) badges.push(['✓ Resolved', 'Marked resolved in the TaskFlow app.']);
  if (note.linkedTaskID) badges.push(['Linked to a task', 'This note is linked to a task in the TaskFlow app.']);
  if (note.linkedEventID) badges.push(['Linked to an event', 'This note is linked to a calendar event in the TaskFlow app.']);
  return badges;
}

/// A note's text as it reads, for the list: Markdown markers gone, checkboxes
/// as boxes, lines run together.
export function plainPreview(body, limit = 240) {
  return body.split('\n').map(line => line
    .replace(/^\s*[-*+]\s+\[[xX]\]\s*/, '☑ ').replace(/^\s*[-*+]\s+\[ \]\s*/, '☐ ')
    .replace(/^\s*#{1,6}\s+/, '').replace(/^\s*>\s?/, '').replace(/^\s*[-*+]\s+/, '• ')
    .replace(/\*\*([^*]+)\*\*/g, '$1').replace(/\*([^*]+)\*/g, '$1').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').trim())
    .filter(Boolean).join(' ').slice(0, limit);
}

/// The note's text as Markdown, the way the app shows it for its format.
/// Checklist notes keep `- [ ]` / `- [x]` markers (see `NoteChecklist` in the
/// app); a line without one is an unchecked item. Headings and blank lines
/// pass through in every format.
export function markdownBody(text, format) {
  if (format === 'markdown' || format === 'plain' || !FORMATS.includes(format)) return text;
  return text.split('\n').map(line => {
    const indent = line.match(/^\s*/)[0], rest = line.slice(indent.length);
    if (!rest || /^#{1,3} /.test(rest)) return line;
    if (format === 'checklist') {
      const marker = rest.match(/^(?:- )?\[([ xX])\]\s?/);
      if (marker) return `${indent}- [${marker[1] === ' ' ? ' ' : 'x'}] ${rest.slice(marker[0].length)}`;
      return `${indent}- [ ] ${rest.replace(/^(?:- |> )/, '')}`;
    }
    if (format === 'bullets') return /^[-*] /.test(rest) ? line : `${indent}- ${rest}`;
    return /^>/.test(rest) ? line : `${indent}> ${rest}`; // quote
  }).join('\n');
}

export function recordName(id) { return `TaskFlowWebNote-${id.toUpperCase()}`; }
const timestamp = value => typeof value === 'number' && Number.isFinite(value) ? new Date(value).toISOString() : null;

export function noteFromRecord(record) {
  if (record?.recordType !== recordType || record.fields?.schemaVersion?.value !== 1) throw new Error('This note requires a newer TaskFlow editor.');
  const payload = record.fields.payload?.value;
  if (typeof payload !== 'string' || new TextEncoder().encode(payload).length > MAX_BYTES) throw new Error('This note cannot be opened safely.');
  const note = JSON.parse(payload);
  if (typeof note.id !== 'string' || !UUID_PATTERN.test(note.id) || record.recordName !== recordName(note.id) ||
      record.fields.noteID?.value?.toUpperCase() !== note.id.toUpperCase() || typeof note.text !== 'string') throw new Error('This note contains invalid data.');
  if ((note.title != null && typeof note.title !== 'string') || (note.folder != null && typeof note.folder !== 'string') ||
      !Array.isArray(note.tags ?? []) || (note.tags ?? []).some(tag => typeof tag !== 'string') ||
      !FORMATS.includes(note.format ?? 'plain') || !LAYOUTS.includes(note.layout ?? 'standard') ||
      (note.attachments != null && !Array.isArray(note.attachments)) ||
      ![0, 1].includes(record.fields.isDeleted?.value)) throw new Error('This note contains unsupported formatting or invalid fields.');
  const modifiedAt = timestamp(record.modified?.timestamp) ?? timestamp(record.created?.timestamp) ?? note.createdAt ?? null;
  const body = markdownBody(note.text, note.format ?? 'plain');
  return {
    ...note,
    title: note.title ?? '', tags: note.tags ?? [], folder: note.folder ?? '', attachments: note.attachments ?? [],
    body, originalBody: body, hasRichText: false,
    pinnedAt: note.isPinned ? modifiedAt ?? new Date(0).toISOString() : null,
    deletedAt: record.fields.isDeleted.value === 1 ? modifiedAt ?? new Date(0).toISOString() : null,
    modifiedAt,
    hasDrawing: record.fields.hasDrawing?.value === 1,
    record
  };
}

export function recordForNote(note, previous = note.record) {
  const {record, body, originalBody, hasRichText, pinnedAt, deletedAt, modifiedAt, hasDrawing, isDeleted: _isDeleted, ...payload} = note;
  const drawing = previous?.fields?.hasDrawing?.value === 1 || Boolean(hasDrawing);
  if (drawing && Boolean(previous?.fields?.isDeleted?.value) !== Boolean(deletedAt)) {
    throw new SyncError('Move drawing notes to Trash in the TaskFlow app, so the drawing isn’t lost.', 'DRAWING');
  }
  payload.id = payload.id.toUpperCase();
  payload.isPinned = Boolean(pinnedAt);
  // Only an edited text is rewritten, as Markdown; otherwise text and format
  // stay exactly as the app saved them.
  if (body !== undefined && body !== originalBody) { payload.text = body; payload.format = 'markdown'; }
  payload.text ??= '';
  payload.title ??= ''; payload.tags ??= []; payload.folder ??= ''; payload.attachments ??= [];
  // As the app projects a note for the web: no drawing, history or edit stamp.
  payload.versions = [];
  delete payload.drawingData; delete payload.updatedAt;
  const text = JSON.stringify(payload);
  if (new TextEncoder().encode(text).length > MAX_BYTES) throw new SyncError('This note is too large to sync. Please split it into smaller notes.', 'TOO_LARGE');
  return {...(previous ?? {}), recordType, recordName: recordName(payload.id), fields: {
    ...(previous?.fields ?? {}),
    schemaVersion: {value: 1},
    noteID: {value: payload.id},
    payload: {value: text},
    isDeleted: {value: deletedAt ? 1 : 0},
    hasDrawing: {value: drawing ? 1 : 0}
  }};
}

export function newNote() {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID().toUpperCase(), title: '', text: '', body: '', originalBody: '',
    createdAt: now, modifiedAt: now, format: 'markdown', layout: 'standard',
    tags: [], folder: '', isResolved: false, attachments: [], versions: [],
    pinnedAt: null, deletedAt: null, hasDrawing: false, hasRichText: false
  };
}

/// Every tag on a live note: how many notes use it and when it was last used.
export function tagStats(notes) {
  const stats = new Map();
  for (const note of notes) {
    if (isDeleted(note)) continue;
    for (const tag of note.tags) {
      const entry = stats.get(tag) ?? {tag, count: 0, last: 0};
      entry.count++; entry.last = Math.max(entry.last, Date.parse(note.modifiedAt ?? note.createdAt ?? 0) || 0);
      stats.set(tag, entry);
    }
  }
  return [...stats.values()].sort((a, b) => a.tag.localeCompare(b.tag, undefined, {sensitivity: 'base'}));
}
/// The tags worth keeping in view: the most used, nudged up by recent use
/// (+3 within a week, +1 within a month), most recent first on a tie.
export function frequentTags(stats, limit = 6, now = Date.now()) {
  const score = ({count, last}) => count + (now - last < 7 * 86_400_000 ? 3 : now - last < 30 * 86_400_000 ? 1 : 0);
  return [...stats].sort((a, b) => score(b) - score(a) || b.last - a.last || a.tag.localeCompare(b.tag)).slice(0, limit);
}
/// Folders on live notes, alphabetically, with how many notes each holds.
export function folderStats(notes) {
  const counts = new Map();
  for (const note of notes) if (!isDeleted(note) && note.folder) counts.set(note.folder, (counts.get(note.folder) ?? 0) + 1);
  return [...counts].map(([folder, count]) => ({folder, count})).sort((a, b) => a.folder.localeCompare(b.folder, undefined, {sensitivity: 'base'}));
}

const time = value => Date.parse(value ?? 0) || 0;
const orders = {
  modified: (a, b) => time(b.modifiedAt) - time(a.modifiedAt),
  created: (a, b) => time(b.createdAt) - time(a.createdAt),
  title: (a, b) => (a.title || 'Untitled Note').localeCompare(b.title || 'Untitled Note')
};

/// Pinned first, then by the chosen order (most recently edited by default).
export function visibleNotes(notes, {query = '', tag = '', folder = '', trash = false, sortBy = 'modified'} = {}) {
  const search = query.trim().toLocaleLowerCase();
  const order = orders[sortBy] ?? orders.modified;
  return notes.filter(note => isDeleted(note) === trash && (!tag || note.tags.includes(tag)) && (!folder || note.folder === folder) &&
      (!search || `${note.title}\n${note.body}\n${note.tags.join(' ')}\n${note.folder}`.toLocaleLowerCase().includes(search)))
    .sort((a, b) => Number(isPinned(b)) - Number(isPinned(a)) || order(a, b) || a.id.localeCompare(b.id));
}

/// CloudKit reports per-record failures inside an HTTP 200, so every response
/// is checked. Unexpected errors keep CloudKit's code and reason in the
/// message (and the console): a generic "try again" hides the cause.
export function check(response) {
  if (response.hasErrors || response.errors?.length) {
    const error = response.errors?.[0];
    const code = error?.ckErrorCode ?? error?.serverErrorCode;
    if (code === 'CONFLICT' || code === 'SERVER_RECORD_CHANGED') throw new NoteConflict(error?.serverRecord);
    if (authCodes.includes(code)) throw new SyncError('Your Apple session has expired. Sign in again to sync.', code);
    if (code === 'QUOTA_EXCEEDED') throw new SyncError('Your iCloud storage is full. Your unsaved draft is still here.', code);
    console.error('CloudKit error', error);
    const detail = [code, error?.reason].filter(Boolean).join(': ');
    throw new SyncError(`iCloud could not complete this request${detail ? ` (${detail})` : ''}. Your draft is still here.`, code);
  }
  return response;
}

const TAG_COLORS_INTERVAL = 10 * 60_000;
export class CloudNotesProvider {
  constructor(container) { this.container = container; this.database = container.privateCloudDatabase; this.tagColors = {}; this.tagColorsAt = 0; this.cache = new Map(); }
  /// The app publishes the readiness record once it has synced its notes.
  async connect() {
    const user = await this.container.setUpAuth();
    if (!user) throw new Error('Sign in with your Apple Account to open your notes.');
    const readiness = await this.database.fetchRecords(readinessRecordName);
    if (readiness.errors?.some(error => ['UNKNOWN_ITEM', 'NOT_FOUND'].includes(error.ckErrorCode ?? error.serverErrorCode))) throw new Error(NOT_READY);
    const response = check(readiness);
    if (response.records?.[0]?.fields?.schemaVersion?.value !== 1) throw new Error(NOT_READY);
    return user;
  }
  /// Only notes that are new or changed since the last sync are downloaded
  /// in full (see shared/records.mjs).
  async list() {
    const records = await queryAll(this.database, recordType, this.cache, check);
    await this.refreshTagColors();
    // One unreadable record must not hide every other note.
    return records.flatMap(record => { try { return [noteFromRecord(record)]; } catch { return []; } });
  }
  /// The metadata record holds all of the app's metadata, so it's read every
  /// ten minutes rather than on every sync. Colours are a nicety: a failure
  /// keeps the last ones.
  async refreshTagColors({force = false} = {}) {
    if (!force && Date.now() - this.tagColorsAt < TAG_COLORS_INTERVAL) return;
    this.tagColorsAt = Date.now();
    try {
      const response = await this.database.fetchRecords(METADATA_RECORD, {desiredKeys: ['payload']});
      if (response.records?.[0]) this.tagColors = tagColorsFromMetadata(response.records[0]);
    } catch { /* Keep the colours already shown. */ }
  }
  async save(note) {
    const response = check(await this.database.saveRecords(recordForNote(note)));
    if (!response.records?.[0]) throw new Error('iCloud did not confirm this save. Your draft is still here.');
    this.cache.set(response.records[0].recordName, response.records[0]);
    return noteFromRecord(response.records[0]);
  }
  async latest(id) {
    const response = check(await this.database.fetchRecords(recordName(id)));
    return noteFromRecord(response.records[0]);
  }
  async signOut() { this.cache.clear(); await this.container.signOut(); }
}

/// Sample notes held in this tab only, for trying the page without iCloud.
export class DemoNotesProvider {
  constructor() { this.records = new Map(); this.counter = 0; this.tagColors = {}; }
  async connect() { return {userRecordName: 'local-preview'}; }
  async list() { return [...this.records.values()].map(noteFromRecord); }
  async save(note) {
    const existing = this.records.get(note.id);
    if (existing && existing.recordChangeTag !== note.record?.recordChangeTag) throw new NoteConflict(existing);
    const record = recordForNote(note);
    record.recordChangeTag = String(++this.counter);
    record.modified = {timestamp: Date.now()};
    this.records.set(note.id, structuredClone(record));
    return noteFromRecord(record);
  }
  async latest(id) { return noteFromRecord(this.records.get(id)); }
  async signOut() { this.records.clear(); }
}
