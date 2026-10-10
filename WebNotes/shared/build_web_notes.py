"""Packaging shared by Sebastian's and TaskFlow's web notes pages.

Source of truth: Sebastian repo, WebNotes/shared/. TaskFlow's repo keeps an
identical copy (see README.md). Each app's WebNotes/ folder has:
  core.mjs              its records and iCloud provider (same exports in both)
  profile.json          name, paths, features, colours, sample notes
  theme.css             its colours (overrides the tokens in shared/styles.css)
  manifest.webmanifest  and icons/
and its own build.py, which decides where the page and its files go.
"""
import hashlib
import html
import json
from pathlib import Path
import shutil

SHARED_FILES = ['app.mjs', 'rich-text.mjs', 'records.mjs', 'styles.css']
APP_FILES = ['core.mjs', 'theme.css', 'manifest.webmanifest']


def build(app_dir: Path, page_path: Path, assets: Path, environment: str, token: str) -> str:
    """Write the page to `page_path` and its files under `assets` (which
    `profile.json`'s "base" must point at). Returns the version stamp."""
    profile = json.loads((app_dir / 'profile.json').read_text())
    shared = app_dir / 'shared'
    assets.mkdir(parents=True, exist_ok=True)
    for name in APP_FILES:
        shutil.copy2(app_dir / name, assets / name)
    shutil.copytree(app_dir / 'icons', assets / 'icons', dirs_exist_ok=True)
    (assets / 'shared').mkdir(exist_ok=True)
    for name in SHARED_FILES:
        shutil.copy2(shared / name, assets / 'shared' / name)
    shutil.copytree(shared / 'vendor', assets / 'shared' / 'vendor', dirs_exist_ok=True)

    features = profile.get('features', {})
    values = {
        'BASE': profile['base'],
        'APP': profile['appName'],
        'WELCOME_INTRO': profile['welcomeIntro'],
        'WELCOME_FINE': profile['welcomeFine'],
        'THEME_LIGHT': profile['themeColors']['light'],
        'BODY_CLASS': ' '.join(['has-' + name.lower() for name, on in sorted(features.items()) if on]),
    }
    page = (shared / 'page.html').read_text()
    for key, value in values.items():
        page = page.replace('{{' + key + '}}', html.escape(value, quote=True))
    if '{{' in page:
        raise SystemExit('page.html has a placeholder build_web_notes.py does not fill: ' + page[page.index('{{'):][:40])
    page_path.parent.mkdir(parents=True, exist_ok=True)
    page_path.write_text(page)

    # Open tabs compare this with version.json to notice a new deploy.
    digest = hashlib.sha256(page.encode())
    for path in sorted(p for p in assets.rglob('*') if p.is_file() and p.name not in ('config.js', 'version.json')):
        digest.update(path.relative_to(assets).as_posix().encode() + b'\0' + path.read_bytes())
    digest.update(json.dumps(profile, sort_keys=True).encode())
    version = digest.hexdigest()[:12]
    (assets / 'version.json').write_text(json.dumps({'version': version}) + '\n')
    config = {
        'version': version,
        'containerIdentifier': profile['containerIdentifier'],
        'environment': environment,
        'apiToken': token,
        'websiteURL': profile['websiteURL'],
        'profile': profile,
    }
    (assets / 'config.js').write_text('window.NOTES_CONFIG = Object.freeze(' + json.dumps(config, ensure_ascii=False) + ');\n')
    return version
