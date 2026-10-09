export const recordType = 'TaskFlowWebNote';
export const MAX_BYTES = 600_000;
export class NoteConflict extends Error {
  constructor(remote) { super('This note changed elsewhere. Both versions are available.'); this.remote = remote; }
}
export function safeLink(raw) {
  try { const url = new URL(raw); return ['https:', 'http:', 'mailto:'].includes(url.protocol) ? url.href : null; } catch { return null; }
}
export function noteFromRecord(record) {
  if (record.recordType !== recordType || record.fields?.schemaVersion?.value !== 1) throw new Error('This note requires a newer TaskFlow editor.');
  const payload = record.fields.payload?.value;
  if (typeof payload !== 'string' || new TextEncoder().encode(payload).length > MAX_BYTES) throw new Error('This note cannot be opened safely.');
  const note = JSON.parse(payload);
  if (typeof note.id !== 'string' || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(note.id) || record.recordName !== `TaskFlowWebNote-${note.id.toUpperCase()}` || record.fields.noteID?.value?.toUpperCase() !== note.id.toUpperCase() || typeof note.text !== 'string') throw new Error('This note contains invalid data.');
  if ((note.title != null && typeof note.title !== 'string') || (note.folder != null && typeof note.folder !== 'string') ||
      !Array.isArray(note.tags ?? []) || (note.tags ?? []).some(tag => typeof tag !== 'string') ||
      !['plain', 'bullets', 'checklist', 'quote', 'markdown'].includes(note.format ?? 'plain') ||
      !['standard', 'compact', 'prominent'].includes(note.layout ?? 'standard') ||
      ![0, 1].includes(record.fields.isDeleted?.value)) throw new Error('This note contains unsupported formatting or invalid fields.');
  return {...note, title: note.title ?? '', tags: note.tags ?? [], folder: note.folder ?? '', isPinned: note.isPinned ?? false, isDeleted: record.fields.isDeleted?.value === 1, hasDrawing: record.fields.hasDrawing?.value === 1, record};
}
export function recordForNote(note, previous = note.record) {
  const {record, isDeleted, hasDrawing, ...payload} = note;
  if (previous?.fields?.hasDrawing?.value === 1 && Boolean(previous.fields.isDeleted?.value) !== Boolean(isDeleted)) throw new Error('Manage drawing notes in TaskFlow to preserve their original artwork.');
  delete payload.updatedAt;
  payload.versions = [];
  delete payload.drawingData;
  const text = JSON.stringify(payload);
  if (new TextEncoder().encode(text).length > MAX_BYTES) throw new Error('This note is too large to sync. Please split it into smaller notes.');
  return {...(previous ?? {}), recordType, recordName: `TaskFlowWebNote-${note.id.toUpperCase()}`, fields: {
    ...(previous?.fields ?? {}),
    schemaVersion: {value: 1}, hasDrawing: {value: hasDrawing ? 1 : 0}, noteID: {value: note.id.toUpperCase()}, payload: {value: text}, isDeleted: {value: isDeleted ? 1 : 0}
  }};
}
export function newNote() {
  return {id: crypto.randomUUID().toUpperCase(), title: '', text: '', createdAt: new Date().toISOString(), format: 'markdown', layout: 'standard', tags: [], folder: '', isPinned: false, isResolved: false, attachments: [], versions: [], isDeleted: false};
}
export function visibleNotes(notes, {query = '', folder = '', trash = false} = {}) {
  const search = query.trim().toLocaleLowerCase();
  return notes.filter(note => note.isDeleted === trash && (!folder || note.folder === folder) && (!search || `${note.title}\n${note.text}\n${note.tags.join(' ')}`.toLocaleLowerCase().includes(search)))
    .sort((a, b) => Number(b.isPinned) - Number(a.isPinned) || a.title.localeCompare(b.title) || a.id.localeCompare(b.id));
}
function check(response) {
  if (response.hasErrors || response.errors?.length) {
    const error = response.errors?.[0];
    const code = error?.ckErrorCode ?? error?.serverErrorCode;
    if (code === 'CONFLICT' || code === 'SERVER_RECORD_CHANGED') throw new NoteConflict(error?.serverRecord);
    throw new Error(code === 'AUTHENTICATION_REQUIRED' ? 'Your Apple session has expired. Sign in again to sync.' : code === 'QUOTA_EXCEEDED' ? 'Your iCloud storage is full. Your unsaved draft is still here.' : 'iCloud could not complete this request. Please try again.');
  }
  return response;
}
export class CloudNotesProvider {
  constructor(container) { this.container = container; this.database = container.privateCloudDatabase; }
  async connect() {
    const user = await this.container.setUpAuth();
    if (!user) throw new Error('Sign in with your Apple Account to open your notes.');
    const readiness = await this.database.fetchRecords('TaskFlowWebNotesReady');
    if (readiness.errors?.some(error => ['UNKNOWN_ITEM', 'NOT_FOUND'].includes(error.ckErrorCode ?? error.serverErrorCode))) {
      throw new Error('Open the updated TaskFlow app and sync your notes to enable browser access.');
    }
    const response = check(readiness);
    if (response.records?.[0]?.fields?.schemaVersion?.value !== 1) throw new Error('Open the updated TaskFlow app and sync your notes to enable browser access.');
    return user;
  }
  async list() {
    let response = check(await this.database.performQuery({recordType}));
    const records = [...(response.records ?? [])];
    const seen = new Set();
    while (response.moreComing) {
      if (!response.continuationMarker || seen.has(response.continuationMarker)) throw new Error('iCloud returned an incomplete notes list. Please refresh to try again.');
      seen.add(response.continuationMarker);
      response = check(await this.database.performQuery(response));
      records.push(...(response.records ?? []));
    }
    return records.map(noteFromRecord);
  }
  async save(note) {
    const response = check(await this.database.saveRecords(recordForNote(note)));
    if (!response.records?.[0]) throw new Error('iCloud did not confirm this save. Your draft is still here.');
    return noteFromRecord(response.records[0]);
  }
  async latest(id) {
    const response = check(await this.database.fetchRecords(`TaskFlowWebNote-${id.toUpperCase()}`));
    return noteFromRecord(response.records[0]);
  }
  async signOut() { await this.container.signOut(); }
}
export class DemoNotesProvider {
  constructor() { this.records = new Map(); this.counter = 0; }
  async connect() { return {userRecordName: 'local-preview'}; }
  async list() { return [...this.records.values()].map(noteFromRecord); }
  async save(note) {
    const existing = this.records.get(note.id);
    if (existing && existing.recordChangeTag !== note.record?.recordChangeTag) throw new NoteConflict(existing);
    const record = recordForNote(note);
    record.recordChangeTag = String(++this.counter);
    this.records.set(note.id, structuredClone(record));
    return noteFromRecord(record);
  }
  async latest(id) { return noteFromRecord(this.records.get(id)); }
  async signOut() { this.records.clear(); }
}
