import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {CloudNotesProvider, DemoNotesProvider, NoteConflict, newNote, noteFromRecord, recordForNote, visibleNotes, safeLink} from '../core.mjs';
if (!globalThis.crypto) globalThis.crypto = webcrypto;

test('new browser notes use native-compatible enum values and dates', () => {
  const note = newNote();
  assert.equal(note.format, 'markdown'); assert.equal(note.layout, 'standard'); assert.ok(Number.isFinite(Date.parse(note.createdAt)));
  const result = noteFromRecord(recordForNote(note)); assert.equal(result.text, ''); assert.equal(result.id, note.id);
});
test('editing retains native attachment references and unknown metadata', () => {
  const note = {...newNote(), attachments: [{id: 'attachment', kind: 'url', title: 'Link', urlString: 'https://example.com'}], linkedTaskID: 'task', customFutureField: {kept: true}};
  const result = noteFromRecord(recordForNote({...note, text: 'An edit'}));
  assert.deepEqual(result.attachments, note.attachments); assert.equal(result.linkedTaskID, 'task'); assert.deepEqual(result.customFutureField, note.customFutureField);
});
test('malformed and mismatched records are rejected', () => {
  const record = recordForNote(newNote()); record.recordName = 'Wrong'; assert.throws(() => noteFromRecord(record));
  const unknown = recordForNote(newNote()); unknown.fields.schemaVersion.value = 2; assert.throws(() => noteFromRecord(unknown));
  assert.throws(() => recordForNote({...newNote(), text: 'x'.repeat(600_001)}));
});
test('a stale browser save conflicts instead of replacing a newer edit', async () => {
  const provider = new DemoNotesProvider(); const first = await provider.save({...newNote(), text: 'Base'});
  const changed = await provider.save({...first, text: 'Newer writing'});
  await assert.rejects(provider.save({...first, text: 'Stale writing'}), NoteConflict);
  assert.equal((await provider.latest(first.id)).text, changed.text);
});
test('trash is reversible and keeps the original note content', async () => {
  const provider = new DemoNotesProvider(); const saved = await provider.save({...newNote(), text: 'Keep this'});
  const trashed = await provider.save({...saved, isDeleted: true}); assert.equal(visibleNotes(await provider.list()).length, 0);
  assert.equal(visibleNotes(await provider.list(), {trash: true})[0].text, 'Keep this');
  await provider.save({...trashed, isDeleted: false}); assert.equal(visibleNotes(await provider.list()).length, 1);
});
test('search, folder filtering, and pinned ordering work together', () => {
  const first = {...newNote(), title: 'First', text: 'Work', folder: 'Projects'};
  const second = {...newNote(), title: 'Second', text: 'Work', folder: 'Projects', isPinned: true};
  const third = {...newNote(), title: 'Third', folder: 'Personal'};
  assert.deepEqual(visibleNotes([first, second, third], {query: 'work', folder: 'Projects'}).map(n => n.title), ['Second', 'First']);
});
test('preview links cannot execute script or open local files', () => {
  assert.equal(safeLink('javascript:alert(1)'), null); assert.equal(safeLink('file:///etc/passwd'), null);
  assert.equal(safeLink('https://example.com'), 'https://example.com/');
});
test('CloudKit pages are all fetched and writes keep the original change tag', async () => {
  const one = recordForNote({...newNote(), text: 'Page one'}), two = recordForNote({...newNote(), text: 'Page two'});
  one.recordChangeTag = 'original'; let pages = 0, sent;
  const db = {performQuery: async () => ++pages === 1 ? {records: [one], moreComing: true, continuationMarker: 'next'} : {records: [two]}, saveRecords: async record => { sent = record; return {records: [{...record, recordChangeTag: 'updated'}]}; }};
  const provider = new CloudNotesProvider({privateCloudDatabase: db});
  assert.equal((await provider.list()).length, 2); await provider.save({...noteFromRecord(one), text: 'Edited'});
  assert.equal(sent.recordChangeTag, 'original');
});
test('CloudKit conflicts and incomplete saves never report success', async () => {
  const provider = new CloudNotesProvider({privateCloudDatabase: {saveRecords: async () => ({hasErrors: true, errors: [{ckErrorCode: 'CONFLICT'}]})}});
  await assert.rejects(provider.save(newNote()), NoteConflict);
  provider.database.saveRecords = async () => ({records: []}); await assert.rejects(provider.save(newNote()), /did not confirm/);
});
test('missing readiness gives an actionable native-sync message', async () => {
  for (const code of ['UNKNOWN_ITEM', 'NOT_FOUND']) {
    const provider = new CloudNotesProvider({setUpAuth: async () => ({userRecordName: 'test'}), privateCloudDatabase: {
      fetchRecords: async () => ({hasErrors: true, errors: [{serverErrorCode: code}]})
    }});
    await assert.rejects(provider.connect(), /updated TaskFlow app and sync/);
  }
});
test('broken CloudKit pagination cannot silently truncate notes or loop forever', async () => {
  for (const response of [{moreComing: true}, {moreComing: true, continuationMarker: 'repeated'}]) {
    let calls = 0;
    const provider = new CloudNotesProvider({privateCloudDatabase: {performQuery: async () => { calls++; return response; }}});
    await assert.rejects(provider.list(), /incomplete notes list/);
    assert.ok(calls <= 2);
  }
});

test('rich editor round-trips mixed paragraphs, word formatting, lists and checklists', async () => {
  const {markdownToDelta, deltaToMarkdown} = await import('../rich-text.mjs');
  const text = 'A **bold** word and *italic* text\n\n## Heading\n- One\n  - Nested\n- [x] Finished\n1. First\n2. Second\n> A quote\nNormal paragraph';
  assert.equal(deltaToMarkdown(markdownToDelta(text)), text);
});
test('rich editor preserves plain-note asterisks and rejects unsafe link formatting', async () => {
  const {markdownToDelta} = await import('../rich-text.mjs');
  const ops = markdownToDelta('A *literal* word', 'plain').ops;
  assert.equal(ops[0].insert, 'A *literal* word'); assert.equal(ops[0].attributes, undefined);
  assert.equal(markdownToDelta('[Bad](javascript:alert)', 'markdown').ops.some(op => op.attributes?.link), false);
});

test('drawing notes can be edited without exposing or discarding original artwork', () => {
  const original = recordForNote({...newNote(), hasDrawing: true, text: 'Has a drawing'});
  const note = noteFromRecord(original);
  assert.equal(recordForNote({...note, text: 'Edited text'}).fields.hasDrawing.value, 1);
  assert.throws(() => recordForNote({...note, isDeleted: true}), /preserve their original artwork/);
});
