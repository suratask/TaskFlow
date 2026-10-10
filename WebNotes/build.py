#!/usr/bin/env python3
"""Package the TaskFlow Notes web page. No note data or account server is part of this bundle.

Output (.build/WebNotes/site), as the `taskflow-notes` Worker serves it:
  notes.html        the page, at /notes
  notes/...         its scripts, styles, icons and version.json, at /notes/...
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--environment', choices=['development', 'production'], default='development')
parser.add_argument('--token-file', type=Path, help='Local file containing the CloudKit web API token; never paste it into chat or commit it')
args = parser.parse_args()
root = Path(__file__).resolve().parent
site = root.parent / '.build' / 'WebNotes' / 'site'
assets = site / 'notes'
token = args.token_file.read_text().strip() if args.token_file else ''
if args.environment == 'production' and not token:
    parser.error('Production packaging requires --token-file.')
if site.exists():
    shutil.rmtree(site)
assets.mkdir(parents=True)
shutil.copy2(root / 'index.html', site / 'notes.html')
for name in ['styles.css', 'app.mjs', 'core.mjs', 'rich-text.mjs', 'manifest.webmanifest']:
    shutil.copy2(root / name, assets / name)
for folder in ['vendor', 'icons']:
    shutil.copytree(root / folder, assets / folder)
# Open tabs compare this with version.json to notice a new deploy.
digest = hashlib.sha256()
for path in sorted(p for p in site.rglob('*') if p.is_file()):
    digest.update(path.relative_to(site).as_posix().encode() + b'\0' + path.read_bytes())
version = digest.hexdigest()[:12]
(assets / 'version.json').write_text(json.dumps({'version': version}) + '\n')
config = {
    'version': version,
    'containerIdentifier': 'iCloud.com.surratt.TaskFlow',
    'environment': args.environment,
    'apiToken': token,
    'websiteURL': 'https://modcaststudios.app/notes',
}
(assets / 'config.js').write_text('window.TASKFLOW_NOTES_CONFIG = Object.freeze(' + json.dumps(config) + ');\n')
print(f'Static website files: {site}')
print('iCloud connection configured.' if token else 'Local preview only; live iCloud is not configured.')
