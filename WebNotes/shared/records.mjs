// Shared by Sebastian's and TaskFlow's web notes pages (source of truth:
// Sebastian repo, WebNotes/shared/; TaskFlow keeps a copy — see README.md).
//
// Listing every note on every sync downloads every note's text each time.
// Instead, list only each record's name and change tag (a small field is
// asked for), then download in full just the records that are new or changed
// since the last sync. A record that's gone from iCloud drops out.

const FETCH_BATCH = 100;

/// The tiny field each listing asks for. Every note record has it.
const LISTING_KEYS = ['schemaVersion'];

/// Follows CloudKit's continuation markers, refusing a marker it has seen
/// (which would loop forever) or a missing one (which would truncate).
async function queryPages(database, query, options, check) {
  let response = check(await database.performQuery(query, options));
  const records = [...(response.records ?? [])];
  const seen = new Set();
  while (response.moreComing) {
    if (!response.continuationMarker || seen.has(response.continuationMarker)) throw new Error('iCloud returned an incomplete notes list. Please refresh to try again.');
    seen.add(response.continuationMarker);
    response = check(await database.performQuery(response, options));
    records.push(...(response.records ?? []));
  }
  return records;
}

/// All records of `recordType`, in full, reusing `cache` (recordName → full
/// record) for any whose change tag hasn't moved. The cache is updated in
/// place. `check` turns CloudKit errors into exceptions.
export async function queryAll(database, recordType, cache, check) {
  const listing = await queryPages(database, {recordType}, {desiredKeys: LISTING_KEYS}, check);
  const wanted = listing.filter(record => !cache.has(record.recordName) || cache.get(record.recordName).recordChangeTag !== record.recordChangeTag)
    .map(record => record.recordName);
  for (let start = 0; start < wanted.length; start += FETCH_BATCH) {
    const response = await database.fetchRecords(wanted.slice(start, start + FETCH_BATCH));
    // A record deleted since the listing just drops out; any other error fails the sync.
    const errors = (response.errors ?? []).filter(error => !['NOT_FOUND', 'UNKNOWN_ITEM'].includes(error?.ckErrorCode ?? error?.serverErrorCode));
    if (errors.length) check({...response, errors});
    for (const record of response.records ?? []) if (record?.recordName && record.fields) cache.set(record.recordName, record);
  }
  const listed = new Set(listing.map(record => record.recordName));
  for (const name of [...cache.keys()]) if (!listed.has(name)) cache.delete(name);
  // In the listing's order; a record fetched as changed again since is
  // still the newest copy we have.
  return listing.map(record => cache.get(record.recordName)).filter(Boolean);
}
