// The shared listing helper (shared/records.mjs). Same file in Sebastian's and TaskFlow's repositories.
import test from 'node:test';
import assert from 'node:assert/strict';
import {queryAll} from '../shared/records.mjs';

const check = response => { if (response.errors?.length) throw new Error(response.errors[0].ckErrorCode ?? 'error'); return response; };
const record = (name, tag, text = name) => ({recordName: name, recordChangeTag: tag, fields: {schemaVersion: {value: 1}, payload: {value: text}}});
function database(records) {
  const db = {records, listings: [], fetched: [],
    async performQuery(query, options) {
      db.listings.push(options?.desiredKeys);
      // Listings carry only the requested keys.
      return {records: db.records.map(({recordName, recordChangeTag}) => ({recordName, recordChangeTag, fields: {schemaVersion: {value: 1}}}))};
    },
    async fetchRecords(names) { db.fetched.push(...names); return {records: names.map(name => db.records.find(r => r.recordName === name)).filter(Boolean)}; }};
  return db;
}

test('lists names and change tags only, then downloads what is new or changed', async () => {
  const db = database([record('a', '1'), record('b', '1')]), cache = new Map();
  assert.deepEqual((await queryAll(db, 'Note', cache, check)).map(r => r.fields.payload.value), ['a', 'b']);
  assert.deepEqual(db.listings, [['schemaVersion']]);
  assert.deepEqual(db.fetched, ['a', 'b']);
  db.records = [record('a', '1'), record('b', '2', 'b edited'), record('c', '1')];
  const second = await queryAll(db, 'Note', cache, check);
  assert.deepEqual(db.fetched.slice(2), ['b', 'c'], 'only the changed and the new');
  assert.deepEqual(second.map(r => r.fields.payload.value), ['a', 'b edited', 'c']);
  db.records = [record('c', '1')];
  assert.deepEqual((await queryAll(db, 'Note', cache, check)).map(r => r.recordName), ['c']);
  assert.deepEqual([...cache.keys()], ['c'], 'the cache forgets deleted records');
});

test('pages are followed, and broken pagination fails instead of truncating or looping', async () => {
  const pages = [[record('a', '1')], [record('b', '1')]];
  const db = {performQuery: async query => {
    const index = query.continuationMarker ? 1 : 0;
    return index === 0 ? {records: pages[0], moreComing: true, continuationMarker: 'next'} : {records: pages[1]};
  }, fetchRecords: async names => ({records: names.map(name => pages.flat().find(r => r.recordName === name))})};
  assert.equal((await queryAll(db, 'Note', new Map(), check)).length, 2);
  for (const response of [{moreComing: true}, {moreComing: true, continuationMarker: 'same'}]) {
    let calls = 0;
    const loop = {performQuery: async () => { calls++; return response; }, fetchRecords: async () => ({records: []})};
    await assert.rejects(queryAll(loop, 'Note', new Map(), check), /incomplete notes list/);
    assert.ok(calls <= 2);
  }
});

test('downloads go in batches of 100', async () => {
  const many = Array.from({length: 250}, (_, i) => record(`n${i}`, '1'));
  const db = database(many), batches = [];
  const fetch = db.fetchRecords; db.fetchRecords = async names => { batches.push(names.length); return fetch(names); };
  assert.equal((await queryAll(db, 'Note', new Map(), check)).length, 250);
  assert.deepEqual(batches, [100, 100, 50]);
});
