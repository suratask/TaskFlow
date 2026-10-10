#!/usr/bin/env python3
"""Package the TaskFlow Notes web page. No note data or account server is part of this bundle.

Output (.build/WebNotes/site), as the `taskflow-notes` Worker serves it:
  notes.html        the page, at /notes
  notes/...         its files (core.mjs, theme, icons, config.js, version.json,
                    and shared/ — the page code shared with Sebastian), at /notes/...
"""
import argparse
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parent
sys.path.insert(0, str(root / 'shared'))
from build_web_notes import build  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--environment', choices=['development', 'production'], default='development')
parser.add_argument('--token-file', type=Path, help='Local file containing the CloudKit web API token; never paste it into chat or commit it')
args = parser.parse_args()
token = args.token_file.read_text().strip() if args.token_file else ''
if args.environment == 'production' and not token:
    parser.error('Production packaging requires --token-file.')
site = root.parent / '.build' / 'WebNotes' / 'site'
if site.exists():
    shutil.rmtree(site)
version = build(root, site / 'notes.html', site / 'notes', args.environment, token)
print(f'Static website files: {site} (version {version})')
print('iCloud connection configured.' if token else 'Local preview only; live iCloud is not configured.')
