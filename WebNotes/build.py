#!/usr/bin/env python3
"""Package static Notes assets. No note data or account server is part of this bundle."""
import argparse
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--environment', choices=['development', 'production'], default='development')
parser.add_argument('--token-file', type=Path, help='Local file containing the CloudKit web API token; never paste it into chat')
args = parser.parse_args()
root = Path(__file__).resolve().parent
output = root.parent / '.build' / 'WebNotes' / 'notes'
token = args.token_file.read_text().strip() if args.token_file else ''
if args.environment == 'production' and not token:
    parser.error('Production packaging requires --token-file after live iCloud validation.')
output.mkdir(parents=True, exist_ok=True)
for name in ['index.html', 'styles.css', 'app.mjs', 'core.mjs', 'rich-text.mjs']:
    shutil.copy2(root / name, output / name)
shutil.copytree(root / 'vendor', output / 'vendor', dirs_exist_ok=True)
config = {'containerIdentifier': 'iCloud.com.surratt.TaskFlow', 'environment': args.environment, 'apiToken': token, 'websiteURL': 'https://modcaststudios.app/notes/'}
(output / 'config.js').write_text('window.TASKFLOW_NOTES_CONFIG = Object.freeze(' + json.dumps(config) + ');\n')
shutil.copy2(root / '_headers', output.parent / '_headers')
print(f'Static website files: {output}')
print('iCloud connection configured.' if token else 'Local preview only; live iCloud is not configured.')
