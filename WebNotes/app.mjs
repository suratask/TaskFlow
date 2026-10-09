import {CloudNotesProvider, DemoNotesProvider, NoteConflict, newNote, visibleNotes, safeLink} from './core.mjs';
import {markdownToDelta, deltaToMarkdown} from './rich-text.mjs';
const $ = id => document.getElementById(id);
let provider, account = '', notes = [], draft = null, dirty = false, revision = 0, timer, savePromise, refreshing = false, conflict = null, trash = false;
let session = 0, entering = null, renderFrame, resolving = false;
const rich = new Quill('#note-body', {modules: {toolbar: false, history: {userOnly: true}}, formats: ['bold', 'italic', 'link', 'header', 'list', 'blockquote', 'indent'], placeholder: 'Start writing…'});
rich.root.setAttribute('role', 'textbox'); rich.root.setAttribute('aria-label', 'Note content'); rich.root.setAttribute('aria-multiline', 'true');
rich.on('text-change', (_, __, source) => { if (source === 'user' && draft) { draft.text = deltaToMarkdown(rich.getContents()); draft.format = 'markdown'; changed(); } });
const prefix = 'TaskFlow.notes.draft.';
const status = (text, error = false) => { $('sync-status').textContent = text; $('sync-status').classList.toggle('error', error); $('save-detail').textContent = text; $('download-draft').hidden = !error || !draft; };
function draftKey() { return prefix + encodeURIComponent(account) + '.' + draft.id; }
function stash() { if (draft && account) { try { sessionStorage.setItem(draftKey(), JSON.stringify(draft)); } catch { status('Draft recovery unavailable. Keep this tab open until saved.', true); } } }
function clearDraft() { if (draft && account) sessionStorage.removeItem(draftKey()); }
function upsert(note) { notes = notes.filter(item => item.id !== note.id); notes.push(note); }
function renderList() {
  const currentFolder = $('folder-filter').value;
  const folders = [...new Set(notes.filter(note => !note.isDeleted).map(note => note.folder).filter(Boolean))].sort();
  $('folder-filter').replaceChildren(new Option('All folders', ''), ...folders.map(folder => new Option(folder, folder)));
  $('folder-filter').value = folders.includes(currentFolder) ? currentFolder : '';
  $('folder-names').replaceChildren(...folders.map(folder => new Option(folder)));
  const filtered = visibleNotes(notes, {query: $('search').value, folder: $('folder-filter').value, trash});
  $('note-count').textContent = `${filtered.length} ${filtered.length === 1 ? 'note' : 'notes'}`;
  $('note-list').replaceChildren();
  for (const note of filtered) {
    const button = document.createElement('button'); button.className = 'note-card' + (note.id === draft?.id ? ' selected' : '');
    const title = document.createElement('strong'); title.textContent = (note.isPinned ? '★ ' : '') + (note.title || 'Untitled Note');
    const body = document.createElement('p'); body.textContent = note.text.slice(0, 240) || 'Start writing…';
    const folder = document.createElement('small'); folder.textContent = note.folder || 'Unfiled';
    button.append(title, body, folder); button.addEventListener('click', () => selectNote(note)); $('note-list').append(button);
  }
  if (!filtered.length) { const empty = document.createElement('p'); empty.className = 'muted'; empty.textContent = $('search').value ? 'No matching notes.' : trash ? 'Trash is empty.' : 'No notes here yet.'; $('note-list').append(empty); }
}
async function selectNote(note) {
  const currentSession = session;
  if (dirty && !await flush()) return;
  if (session !== currentSession || !provider) return;
  note = notes.find(item => item.id === note.id) ?? note;
  draft = structuredClone(note); revision++; dirty = !!sessionStorage.getItem(prefix + encodeURIComponent(account) + '.' + note.id);
  $('empty-selection').hidden = true; $('editor').hidden = false;
  $('note-title').value = draft.title; rich.setContents(markdownToDelta(draft.text, draft.format), 'silent'); rich.getModule('history').clear(); $('note-folder').value = draft.folder; $('note-tags').value = draft.tags.join(', ');
  $('pin-note').setAttribute('aria-pressed', String(draft.isPinned)); $('pin-note').textContent = draft.isPinned ? 'Unpin' : 'Pin';
  $('trash-note').textContent = draft.hasDrawing ? 'Manage in TaskFlow' : draft.isDeleted ? 'Restore Note' : 'Move to Trash'; $('trash-note').disabled = draft.hasDrawing;
  $('attachment-note').hidden = !draft.attachments?.length && !draft.hasDrawing;
  renderPreview(); renderList(); status(dirty ? 'Recovered unsaved draft. Save to sync your changes.' : provider instanceof DemoNotesProvider ? 'Local preview · changes stay in this tab.' : 'Saved to iCloud');
}
function changed() {
  if (!draft) return;
  draft.title = $('note-title').value; draft.folder = $('note-folder').value.trim();
  draft.tags = [...new Set($('note-tags').value.split(',').map(tag => tag.trim()).filter(Boolean))];
  dirty = true; revision++; stash(); upsert(draft); status('Unsaved changes');
  if (!renderFrame) renderFrame = requestAnimationFrame(() => { renderFrame = null; renderList(); renderPreview(); });
  clearTimeout(timer); timer = setTimeout(flush, 800);
}
async function flush() {
  clearTimeout(timer);
  if (savePromise) return savePromise;
  if (!dirty || !draft) return true;
  if (conflict) { if (!$('conflict-dialog').open) $('conflict-dialog').showModal(); return false; }
  const currentSession = session, currentProvider = provider;
  const operation = (async () => {
    while (dirty && draft) {
      const captured = structuredClone(draft), capturedRevision = revision;
      status('Saving…');
      try {
        const saved = await currentProvider.save(captured);
        if (session !== currentSession) return false;
        if (draft?.id === captured.id) {
          draft.record = saved.record;
          if (revision === capturedRevision) { draft = saved; dirty = false; clearDraft(); }
          upsert(draft); renderList();
        }
        status(dirty ? 'Unsaved changes' : provider instanceof DemoNotesProvider ? 'Saved in this tab · local preview' : 'Saved to iCloud');
      } catch (error) {
        if (session !== currentSession) return false;
        stash(); status(error.message || 'Unable to sync. Your draft is still here.', true);
        if (error instanceof NoteConflict) {
          try {
            const remote = await currentProvider.latest(captured.id);
            if (session !== currentSession) return false;
            conflict = {local: structuredClone(draft), remote};
            $('conflict-local').textContent = conflict.local.text; $('conflict-remote').textContent = remote.isDeleted ? 'Moved to Trash elsewhere.\n\n' + remote.text : remote.text;
            $('conflict-dialog').showModal();
          } catch { if (session === currentSession) status('Unable to retrieve the other version. Your draft is still here.', true); }
        }
        return false;
      }
    }
    return true;
  })();
  savePromise = operation;
  const succeeded = await operation;
  if (savePromise === operation) savePromise = null;
  return succeeded;
}
async function refresh() {
  if (!provider || refreshing || conflict) return;
  refreshing = true;
  const currentSession = session, currentProvider = provider;
  try {
    if (dirty && !await flush()) return;
    if (session !== currentSession) return;
    const selectedID = draft?.id, currentRevision = revision;
    const fetched = await currentProvider.list();
    // Typing or selecting during a network request must never be replaced by its older result.
    if (session !== currentSession || revision !== currentRevision || dirty) return;
    notes = fetched; renderList();
    if (selectedID) { const updated = notes.find(note => note.id === selectedID); if (updated) await selectNote(updated); }
    status(provider instanceof DemoNotesProvider ? 'Local preview · no iCloud connection' : 'Up to date');
  } catch (error) { if (session === currentSession) status(error.message || 'Unable to refresh. Your notes are still here.', true); }
  finally { if (session === currentSession) refreshing = false; }
}
async function enterWorkspace(user) {
  if (!$('workspace').hidden && account === user.userRecordName) return;
  if (entering) return entering;
  const currentSession = session;
  const operation = initializeWorkspace(user, currentSession);
  entering = operation;
  try { return await operation; } finally { if (entering === operation) entering = null; }
}
async function initializeWorkspace(user, currentSession) {
  if (session !== currentSession || !provider) return;
  account = user.userRecordName;
  const fetched = await provider.list();
  if (session !== currentSession) return;
  notes = fetched;
  $('welcome').hidden = true; $('workspace').hidden = false; $('refresh').hidden = false; $('signout').hidden = false;
  if (provider instanceof DemoNotesProvider) { $('notice').hidden = false; $('notice').textContent = 'Local preview — sample notes only. Nothing is sent to iCloud, and signing out clears this preview.'; }
  const recovered = [];
  for (let i = 0; i < sessionStorage.length; i++) {
    const key = sessionStorage.key(i);
    if (!key.startsWith(prefix + encodeURIComponent(account) + '.')) continue;
    try { const item = JSON.parse(sessionStorage.getItem(key)); if (item.id && typeof item.text === 'string') recovered.push(item); } catch { /* Invalid recovery files never replace cloud notes. */ }
  }
  renderList();
  if (recovered.length) {
    for (const item of recovered) upsert(item);
    $('notice').hidden = false; $('notice').textContent = 'Your unsaved drafts are ready to recover. Save a draft to sync it, or keep editing.';
    renderList(); await selectNote(recovered[0]); dirty = true; revision++;
    status('Recovered unsaved draft. Save to sync your changes.'); return;
  }
  status(provider instanceof DemoNotesProvider ? 'Local preview · no iCloud connection' : 'Up to date');
}
async function loadCloudKit() {
  if (window.CloudKit) return;
  await new Promise((resolve, reject) => {
    const script = document.createElement('script'); script.src = 'https://cdn.apple-cloudkit.com/ck/2/cloudkit.js';
    script.onload = resolve; script.onerror = () => reject(new Error('Apple sign-in could not load. Please try again.')); document.head.append(script);
  });
}
$('connect').onclick = async () => {
  const config = window.TASKFLOW_NOTES_CONFIG;
  if (!config?.apiToken) { $('welcome-error').textContent = 'iCloud access is being prepared. You can explore the sample notes below.'; return; }
  $('connect').disabled = true; $('welcome-error').textContent = '';
  try {
    await loadCloudKit();
    CloudKit.configure({containers: [{containerIdentifier: config.containerIdentifier, environment: config.environment,
      apiTokenAuth: {apiToken: config.apiToken, persist: false, signInButton: {id: 'apple-signin', theme: 'medium'}, signOutButton: {id: 'apple-signout'}}}]});
    const container = CloudKit.getDefaultContainer(), loginProvider = new CloudNotesProvider(container);
    session++; entering = null; refreshing = false; account = '';
    provider = loginProvider;
    const currentSession = session, login = loginProvider.connect();
    const finishLogin = async () => {
      try { const user = await login; if (session === currentSession && provider === loginProvider) await enterWorkspace(user); }
      catch (error) { if (session === currentSession) $('welcome-error').textContent = error.message; }
    };
    container.whenUserSignsIn().then(finishLogin);
    container.whenUserSignsOut().then(() => { if (provider === loginProvider) reset(); });
    await finishLogin();
  } catch (error) { $('welcome-error').textContent = error.message; }
  finally { $('connect').disabled = false; }
};
$('try-demo').onclick = async () => {
  session++; entering = null; refreshing = false; account = '';
  provider = new DemoNotesProvider();
  const samples = [
    ['A place for your ideas', '## Your notes, wherever you are\n\nCapture a thought here, then pick it up in TaskFlow.\n\n- Keep a reading list\n- Plan a project\n- Save something worth remembering\n\n**Select a word** and use the toolbar to format it.', 'Personal'],
    ['Weekend plans', '- [ ] Visit the farmers market\n- [ ] Take a walk by the water\n- [ ] Try a new recipe\n\nLeave a little room for something unplanned.', 'Personal'],
    ['Next project', '## A clear starting point\n\n1. Write down the goal\n2. Pick one next step\n3. Make space to begin\n\n> Small steps count.', 'Work']
  ];
  for (const [title, text, folder] of samples) await provider.save({...newNote(), title, text, folder});
  await enterWorkspace(await provider.connect());
};
$('new-note').onclick = async () => { if (dirty && !await flush()) return; const note = newNote(); upsert(note); await selectNote(note); changed(); $('note-title').focus(); };
for (const id of ['note-title', 'note-folder', 'note-tags']) $(id).addEventListener('input', changed);
$('search').addEventListener('input', renderList); $('folder-filter').addEventListener('change', renderList);
$('trash-filter').onclick = async () => { if (dirty && !await flush()) return; trash = !trash; $('trash-filter').setAttribute('aria-pressed', String(trash)); renderList(); };
$('pin-note').onclick = () => { if (!draft) return; draft.isPinned = !draft.isPinned; $('pin-note').setAttribute('aria-pressed', String(draft.isPinned)); $('pin-note').textContent = draft.isPinned ? 'Unpin' : 'Pin'; changed(); };
$('trash-note').onclick = async () => { if (!draft) return; draft.isDeleted = !draft.isDeleted; $('trash-note').textContent = draft.isDeleted ? 'Restore Note' : 'Move to Trash'; changed(); await flush(); };
$('save-now').onclick = flush; $('refresh').onclick = refresh;
function reset() {
  session++; revision++; savePromise = null; entering = null; refreshing = false; resolving = false;
  cancelAnimationFrame(renderFrame); renderFrame = null;
  clearTimeout(timer);
  for (let i = sessionStorage.length - 1; i >= 0; i--) if (sessionStorage.key(i).startsWith(prefix + encodeURIComponent(account) + '.')) sessionStorage.removeItem(sessionStorage.key(i));
  account = ''; draft = null; dirty = false; notes = []; provider = null; trash = false;
  $('trash-filter').setAttribute('aria-pressed', 'false'); $('search').value = '';
  $('folder-filter').replaceChildren(new Option('All folders', '')); $('folder-names').replaceChildren();
  $('note-preview').hidden = true; $('note-body').hidden = false;
  $('preview-toggle').setAttribute('aria-pressed', 'false'); $('preview-toggle').textContent = 'Preview';
  $('note-title').value = ''; rich.setText('', 'silent'); rich.getModule('history').clear(); $('note-folder').value = ''; $('note-tags').value = ''; $('note-preview').replaceChildren(); $('note-list').replaceChildren();
  $('conflict-local').textContent = ''; $('conflict-remote').textContent = ''; conflict = null;
  if ($('conflict-dialog').open) $('conflict-dialog').close();
  $('workspace').hidden = true; $('welcome').hidden = false; $('refresh').hidden = true; $('signout').hidden = true; $('notice').hidden = true; $('editor').hidden = true; $('empty-selection').hidden = false;
  status('Your notes, wherever you are.');
}
$('signout').onclick = async () => {
  if (dirty && !await flush() && !confirm('Your changes have not synced. Download your draft before signing out, or choose Cancel to keep editing. Sign out and discard this unsaved draft?')) return;
  try { await provider.signOut(); reset(); } catch { status('Unable to sign out. Please try again.', true); }
};
window.addEventListener('beforeunload', event => { if (dirty) { stash(); event.preventDefault(); event.returnValue = ''; } });
window.addEventListener('online', () => { if (provider) refresh(); });
window.addEventListener('focus', () => { if (provider) refresh(); });
setInterval(() => { if (provider && !document.hidden) refresh(); }, 30_000);
$('download-draft').onclick = () => {
  if (!draft) return;
  const url = URL.createObjectURL(new Blob([draft.title + '\n\n' + draft.text], {type: 'text/markdown'}));
  const anchor = document.createElement('a'); anchor.href = url; anchor.download = 'TaskFlow-unsaved-note.md'; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
};
async function resolveConflict(choice) {
  if (!conflict || resolving) return;
  resolving = true;
  const currentSession = session, currentProvider = provider;
  const {local, remote} = conflict;
  try {
  if (choice === 'both') {
    const copy = {...local, id: crypto.randomUUID().toUpperCase(), title: (local.title || 'Untitled Note') + ' (My Edit)', folder: 'Recovered Notes', record: undefined, isDeleted: false, hasDrawing: false};
    try { const saved = await currentProvider.save(copy); if (session !== currentSession) return; upsert(saved); }
    catch (error) { if (session === currentSession) status(error.message, true); return; }
  }
  clearDraft(); conflict = null; $('conflict-dialog').close();
  if (choice === 'mine') { draft = {...local, record: remote.record, hasDrawing: remote.hasDrawing}; dirty = true; revision++; stash(); await flush(); }
  else { dirty = false; upsert(remote); await selectNote(remote); }
  } finally { if (session === currentSession) resolving = false; }
}
$('keep-both').onclick = () => resolveConflict('both'); $('keep-other').onclick = () => resolveConflict('other'); $('keep-mine').onclick = () => resolveConflict('mine');
$('conflict-cancel').onclick = () => $('conflict-dialog').close();
for (const button of document.querySelectorAll('[data-format]')) {
  button.addEventListener('mousedown', event => event.preventDefault());
  button.onclick = () => {
    if (!draft) return;
    const range = rich.getSelection(true), action = button.dataset.format;
    if (action === 'bold' || action === 'italic') rich.format(action, !rich.getFormat(range)[action], 'user');
    else if (action === 'link') { const raw = prompt('Link address (https://…)'); if (raw === null) return; const link = safeLink(raw); if (!link) { status('Enter a valid web or email link.', true); return; } rich.format('link', link, 'user'); }
    else if (action === 'heading') rich.formatLine(range.index, range.length, 'header', rich.getFormat(range).header ? false : 2, 'user');
    else if (action === 'quote') rich.formatLine(range.index, range.length, 'blockquote', !rich.getFormat(range).blockquote, 'user');
    else if (action === 'normal') rich.formatLine(range.index, range.length, {header: false, blockquote: false, list: false, indent: false}, 'user');
    else rich.formatLine(range.index, range.length, 'list', {bullet: 'bullet', number: 'ordered', checklist: 'unchecked'}[action], 'user');
  };
}
$('preview-toggle').onclick = () => { const show = $('note-preview').hidden; $('note-preview').hidden = !show; $('note-body').hidden = show; $('preview-toggle').setAttribute('aria-pressed', String(show)); $('preview-toggle').textContent = show ? 'Edit' : 'Preview'; renderPreview(); };
function inline(text, parent) {
  const pattern = /(\*\*([^*]+)\*\*|\*([^*]+)\*|\[([^\]]+)\]\(([^)]+)\))/g; let offset = 0;
  for (const match of text.matchAll(pattern)) {
    parent.append(document.createTextNode(text.slice(offset, match.index)));
    let element;
    if (match[2]) { element = document.createElement('strong'); element.textContent = match[2]; }
    else if (match[3]) { element = document.createElement('em'); element.textContent = match[3]; }
    else { const href = safeLink(match[5]); element = document.createElement(href ? 'a' : 'span'); element.textContent = match[4]; if (href) { element.href = href; element.target = '_blank'; element.rel = 'noopener noreferrer'; } }
    parent.append(element); offset = match.index + match[0].length;
  }
  parent.append(document.createTextNode(text.slice(offset)));
}
function renderPreview() {
  if (!draft || $('note-preview').hidden) return;
  const preview = $('note-preview'); preview.replaceChildren();
  let source = draft.text;
  const prefixes = {bullets: '- ', checklist: '- [ ] ', quote: '> '};
  if (prefixes[draft.format]) source = source.split('\n').map(line => line ? prefixes[draft.format] + line : line).join('\n');
  for (const line of source.split('\n')) {
    const heading = line.match(/^(#{1,6})\s+(.*)$/), quote = line.match(/^>\s?(.*)$/), bullet = line.match(/^\s*[-*]\s+(.*)$/), numbered = line.match(/^\s*(\d+)\.\s+(.*)$/);
    const element = document.createElement(heading ? 'h' + heading[1].length : quote ? 'blockquote' : 'p');
    let text = heading ? heading[2] : quote ? quote[1] : bullet ? '• ' + bullet[1] : numbered ? numbered[1] + '. ' + numbered[2] : line;
    text = text.replace(/^• \[ \] /, '☐ ').replace(/^• \[[xX]\] /, '☑ ');
    inline(text, element); if (!line) element.append(document.createElement('br')); preview.append(element);
  }
}
