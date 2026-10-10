import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {CloudNotesProvider, DemoNotesProvider, NoteConflict, newNote, noteFromRecord, recordForNote, visibleNotes, safeLink, isDeleted, isPinned,
  canTrash, markdownBody, tagColor, tagColorsFromMetadata, folderStats, check, needsSignIn} from '../core.mjs';
import {markdownToDelta, deltaToMarkdown} from '../shared/rich-text.mjs';
if (!globalThis.crypto) globalThis.crypto = webcrypto;

const ID = '6F1C2B9E-6D7A-4E5B-9C3D-1A2B3C4D5E6F';
/// A record as the TaskFlow app writes it (CloudWebNote.writing): sorted keys,
/// whole-second dates, no drawing or history in the payload.
function appRecord(fields = {}, {isDeleted = 0, hasDrawing = 0, modified = 1_760_000_000_000} = {}) {
  const note = {attachments: [{createdAt: '2026-10-01T10:00:00Z', id: 'A1', kind: 'url', title: 'Spec', urlString: 'https://example.com'}],
    createdAt: '2026-10-01T10:00:00Z', folder: 'Work', format: 'checklist', id: ID, isPinned: false, isResolved: true, layout: 'compact',
    linkedTaskID: 'T1', tags: ['home'], text: '- [ ] milk\n- [x] eggs', title: 'Groceries', versions: [], ...fields};
  return {recordType: 'TaskFlowWebNote', recordName: `TaskFlowWebNote-${ID}`, recordChangeTag: 'tag1', modified: {timestamp: modified, deviceID: 'Mike’s iPhone'},
    fields: {schemaVersion: {value: 1}, noteID: {value: ID}, payload: {value: JSON.stringify(note)}, isDeleted: {value: isDeleted}, hasDrawing: {value: hasDrawing}}};
}
const payloadOf = record => JSON.parse(record.fields.payload.value);

test('app records open with the web note shape', () => {
  const note = noteFromRecord(appRecord());
  assert.equal(note.title, 'Groceries'); assert.equal(note.body, '- [ ] milk\n- [x] eggs'); assert.equal(note.folder, 'Work');
  assert.equal(isPinned(note), false); assert.equal(isDeleted(note), false);
  assert.equal(note.modifiedAt, new Date(1_760_000_000_000).toISOString());
  assert.equal(isPinned(noteFromRecord(appRecord({isPinned: true}))), true);
  assert.equal(isDeleted(noteFromRecord(appRecord({}, {isDeleted: 1}))), true);
});

test('a note whose text was not edited keeps its text and format exactly', () => {
  const original = appRecord({format: 'bullets', text: 'milk\neggs'});
  const note = noteFromRecord(original);
  assert.equal(note.body, '- milk\n- eggs', 'shown as a list');
  const saved = payloadOf(recordForNote({...note, tags: ['home', 'weekly'], folder: 'Errands', pinnedAt: new Date().toISOString()}));
  assert.equal(saved.text, 'milk\neggs'); assert.equal(saved.format, 'bullets');
  assert.deepEqual(saved.tags, ['home', 'weekly']); assert.equal(saved.folder, 'Errands'); assert.equal(saved.isPinned, true);
  // Everything the page doesn't edit comes back as the app wrote it.
  const before = payloadOf(original);
  for (const key of ['attachments', 'createdAt', 'id', 'isResolved', 'layout', 'linkedTaskID', 'title']) assert.deepEqual(saved[key], before[key], key);
});

test('an edited text is saved as Markdown', () => {
  const note = noteFromRecord(appRecord({format: 'plain', text: 'Call Ann'}));
  const saved = payloadOf(recordForNote({...note, body: 'Call **Ann** today'}));
  assert.equal(saved.text, 'Call **Ann** today'); assert.equal(saved.format, 'markdown');
});

test('saves match the app projection: no drawing, history or edit stamp, ids upper-case', () => {
  const note = noteFromRecord(appRecord({versions: [{id: 'V1'}], drawingData: 'AAAA', updatedAt: '2026-10-02T10:00:00Z'}, {hasDrawing: 1}));
  const record = recordForNote({...note, tags: []});
  const saved = payloadOf(record);
  assert.deepEqual(saved.versions, []); assert.equal('drawingData' in saved, false); assert.equal('updatedAt' in saved, false);
  for (const key of ['body', 'originalBody', 'record', 'pinnedAt', 'deletedAt', 'modifiedAt', 'hasDrawing', 'hasRichText']) assert.equal(key in saved, false, key);
  assert.equal(record.fields.hasDrawing.value, 1, 'the drawing flag is kept');
  assert.equal(record.recordChangeTag, 'tag1', 'saved against the fetched change tag');
  assert.equal(record.fields.noteID.value, ID);
});

test('trash is the record flag, and drawing notes are trashed in the app only', () => {
  const note = noteFromRecord(appRecord());
  const trashed = recordForNote({...note, deletedAt: new Date().toISOString()});
  assert.equal(trashed.fields.isDeleted.value, 1);
  assert.equal(recordForNote({...noteFromRecord(trashed), deletedAt: null}).fields.isDeleted.value, 0);
  const drawing = noteFromRecord(appRecord({}, {hasDrawing: 1}));
  assert.equal(canTrash(drawing), false); assert.equal(canTrash(note), true);
  assert.throws(() => recordForNote({...drawing, deletedAt: new Date().toISOString()}), {code: 'DRAWING'});
  assert.doesNotThrow(() => recordForNote({...drawing, title: 'Sketch'}), 'other edits to a drawing note are fine');
});

test('formats read as the app shows them', () => {
  assert.equal(markdownBody('- [ ] a\n[x] b\nplain\n- bullet\n# Section', 'checklist'), '- [ ] a\n- [x] b\n- [ ] plain\n- [ ] bullet\n# Section');
  assert.equal(markdownBody('a\n- b\n\n  c', 'bullets'), '- a\n- b\n\n  - c');
  assert.equal(markdownBody('a\n> b', 'quote'), '> a\n> b');
  assert.equal(markdownBody('**as typed**', 'plain'), '**as typed**');
  assert.equal(deltaToMarkdown(markdownToDelta(markdownBody('- [ ] a\n[x] b', 'checklist'))), '- [ ] a\n- [x] b');
});

test('new notes carry what the app needs to decode them', () => {
  const saved = payloadOf(recordForNote({...newNote(), title: 'Hello', body: 'World'}));
  for (const key of ['id', 'title', 'text', 'createdAt', 'format', 'layout', 'tags', 'folder', 'isPinned', 'isResolved', 'attachments', 'versions']) assert.ok(key in saved, key);
  assert.equal(saved.text, 'World'); assert.equal(saved.format, 'markdown'); assert.match(saved.id, /^[0-9A-F-]{36}$/);
});

test('malformed and mismatched records are rejected, and one bad record hides nothing else', async () => {
  const wrongName = appRecord(); wrongName.recordName = 'Wrong'; assert.throws(() => noteFromRecord(wrongName));
  const future = appRecord(); future.fields.schemaVersion.value = 2; assert.throws(() => noteFromRecord(future));
  assert.throws(() => noteFromRecord(appRecord({format: 'fancy'})));
  assert.throws(() => noteFromRecord(appRecord({text: 5})));
  assert.throws(() => recordForNote({...newNote(), body: 'x'.repeat(600_001)}), {code: 'TOO_LARGE'});
  const broken = appRecord(); broken.recordName = 'TaskFlowWebNote-BROKEN'; broken.fields.payload.value = '{';
  const records = [broken, appRecord()];
  const provider = new CloudNotesProvider({privateCloudDatabase: {performQuery: async () => ({records}),
    fetchRecords: async names => ({records: [names].flat().map(name => records.find(record => record.recordName === name)).filter(Boolean)})}});
  assert.equal((await provider.list()).length, 1);
});

test('tags get the app’s default colours, or the colours chosen in the app', () => {
  // Expected values from the app's own MetadataSnapshot.defaultColor(for:).
  const expected = {Development: '#636366', testing: '#0A84FF', Testing: '#63E6E2', Work: '#FF375F', project: '#FF375F', Clinical: '#5E5CE6', 'café ☕': '#FF453A'};
  for (const [tag, hex] of Object.entries(expected)) assert.equal(tagColor(tag), hex, tag);
  const snapshot = {savedTags: [{name: 'Development', color: 'cyan'}, {name: 'Errands', color: 'gray'}, {name: 'Odd', color: 'plaid'}], quickNotes: []};
  const bytes = new TextEncoder().encode(JSON.stringify(snapshot));
  const colours = tagColorsFromMetadata({fields: {payload: {value: btoa(String.fromCharCode(...bytes))}}});
  assert.deepEqual(colours, {development: '#64D2FF', errands: '#8E8E93'});
  assert.equal(tagColor('Development', colours), '#64D2FF');
  assert.deepEqual(tagColorsFromMetadata({fields: {payload: {value: 'not base64!'}}}), {});
});

test('folders: counts on live notes, filtering, and pinned-first ordering', () => {
  const a = noteFromRecord(appRecord()), b = {...newNote(), title: 'B', folder: 'Home', modifiedAt: '2026-10-09T00:00:00Z'};
  const c = {...newNote(), title: 'C', folder: 'Work', deletedAt: '2026-10-09T00:00:00Z'};
  assert.deepEqual(folderStats([a, b, c]), [{folder: 'Home', count: 1}, {folder: 'Work', count: 1}]);
  assert.deepEqual(visibleNotes([a, b, c], {folder: 'Work'}).map(note => note.title), ['Groceries']);
  assert.deepEqual(visibleNotes([a, b, c], {query: 'home'}).map(note => note.title).sort(), ['B', 'Groceries'], 'searches tags and folders');
  const pinned = {...b, pinnedAt: '2026-10-01T00:00:00Z'};
  assert.equal(visibleNotes([a, pinned])[0].title, 'B');
});

test('a stale browser save conflicts instead of replacing a newer edit', async () => {
  const provider = new DemoNotesProvider(); const first = await provider.save({...newNote(), body: 'Base'});
  const changed = await provider.save({...first, body: 'Newer writing'});
  await assert.rejects(provider.save({...first, body: 'Stale writing'}), NoteConflict);
  assert.equal((await provider.latest(first.id)).body, changed.body);
});

test('CloudKit errors say whether to sign in again, retry or stop', () => {
  const quiet = console.error; console.error = () => {};
  try {
    assert.throws(() => check({errors: [{ckErrorCode: 'BAD_REQUEST', reason: 'Field x not found'}]}), {message: /BAD_REQUEST: Field x not found/});
    const expired = (() => { try { check({errors: [{ckErrorCode: 'AUTHENTICATION_REQUIRED'}]}); } catch (error) { return error; } })();
    assert.equal(needsSignIn(expired), true); assert.equal(needsSignIn({ckErrorCode: 'NETWORK_ERROR'}), false);
    assert.throws(() => check({errors: [{ckErrorCode: 'CONFLICT'}]}), NoteConflict);
  } finally { console.error = quiet; }
});

test('the page waits for the app to enable browser access', async () => {
  const db = {fetchRecords: async () => ({errors: [{ckErrorCode: 'NOT_FOUND'}]})};
  const provider = new CloudNotesProvider({setUpAuth: async () => ({userRecordName: 'u'}), privateCloudDatabase: db});
  await assert.rejects(provider.connect(), /sync your notes/);
});

test('links in notes are limited to web and email addresses', () => {
  assert.equal(safeLink('javascript:alert(1)'), null); assert.equal(safeLink('https://example.com'), 'https://example.com/');
});

test('badges and the shared exports this page leaves unused', async () => {
  const {noteBadges, isPurged, purgedNote} = await import('../core.mjs');
  const texts = noteBadges(noteFromRecord(appRecord({}, {hasDrawing: 1}))).map(([text]) => text);
  assert.deepEqual(texts, ['✎ Drawing', '✓ Resolved', 'Linked to a task']);
  assert.equal(isPurged(noteFromRecord(appRecord({}, {isDeleted: 1}))), false, 'no permanent delete here');
  assert.throws(() => purgedNote(), {code: 'UNSUPPORTED'});
});
