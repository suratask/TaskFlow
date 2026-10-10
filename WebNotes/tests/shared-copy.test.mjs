// Sebastian's and TaskFlow's web notes pages share WebNotes/shared/ (source of
// truth: Sebastian's). When both repositories are checked out side by side,
// their copies must match: run `python3 WebNotes/sync-shared.py` in Sebastian's.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readdirSync, readFileSync, statSync, existsSync} from 'node:fs';
import {join, dirname, basename, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'shared');
const repo = resolve(here, '..', '..'), name = basename(repo);
const otherPath = join(dirname(repo), name === 'TaskFlow' ? 'Sebastian' : 'TaskFlow', 'WebNotes', 'shared');
const other = existsSync(otherPath) ? otherPath : null;
const list = root => readdirSync(root, {recursive: true}).filter(path => !path.includes('__pycache__') && !path.endsWith('.DS_Store') && statSync(join(root, path)).isFile()).sort();

test('the shared page matches the other app’s copy', {skip: !other && 'the other repository is not checked out next to this one'}, () => {
  assert.deepEqual(list(other), list(here), 'same files');
  for (const path of list(here)) assert.ok(readFileSync(join(here, path)).equals(readFileSync(join(other, path))), `${path} differs — run python3 WebNotes/sync-shared.py in the Sebastian repo`);
});
