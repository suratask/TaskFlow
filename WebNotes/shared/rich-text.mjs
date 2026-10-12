import {safeLink} from '../core.mjs';
/// A web address typed as plain text: http(s)://… or www.…, without trailing punctuation.
export const URL_PATTERN = /\b(?:https?:\/\/|www\.)[^\s<>"]*[^\s<>".,;:!?'")\]]/gi;
/// Where a typed address goes: www.… becomes https://www.…; anything unsafe is null.
export function linkTarget(text) { return safeLink(/^www\./i.test(text) ? 'https://' + text : text); }
/// A bare address keeps its link without Markdown around it.
const isBareLink = (text, link) => link === linkTarget(text);
function linkify(text, attributes) {
  const ops = []; let offset = 0;
  const add = (insert, attrs) => { if (insert) ops.push(Object.keys(attrs).length ? {insert, attributes: attrs} : {insert}); };
  for (const match of text.matchAll(URL_PATTERN)) {
    const link = attributes.link ? null : linkTarget(match[0]);
    if (!link) continue;
    add(text.slice(offset, match.index), attributes); add(match[0], {...attributes, link});
    offset = match.index + match[0].length;
  }
  add(text.slice(offset), attributes); return ops;
}
function inlineOps(text, attributes = {}) {
  const ops = [], pattern = /(\*\*\*([\s\S]+?)\*\*\*|\*\*([\s\S]+?)\*\*|\*([^*]+)\*|\[([^\]]+)\]\(([^)]+)\))/g;
  let offset = 0;
  const add = (insert, attrs = attributes) => { if (insert) ops.push(...linkify(insert, attrs)); };
  for (const match of text.matchAll(pattern)) {
    add(text.slice(offset, match.index));
    if (match[2]) ops.push(...inlineOps(match[2], {...attributes, bold: true, italic: true}));
    else if (match[3]) ops.push(...inlineOps(match[3], {...attributes, bold: true}));
    else if (match[4]) add(match[4], {...attributes, italic: true});
    else { const link = safeLink(match[6]); ops.push(...inlineOps(match[5], link ? {...attributes, link} : attributes)); }
    offset = match.index + match[0].length;
  }
  add(text.slice(offset)); return ops;
}
// MARK: - Tables

/// A Markdown table row: "| a | b |". Pipes inside a cell are written "\\|".
const TABLE_ROW = /^\s*\|.*\|\s*$/;
/// The line under a table's first row: "| --- | :---: |".
const TABLE_RULE = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/;
export const isTableRule = line => TABLE_RULE.test(line) && line.includes('-');
/// The cells of a row, unescaped.
export function tableCells(line) {
  const inner = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  const cells = []; let cell = '';
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === '\\' && inner[i + 1] === '|') { cell += '|'; i++; }
    else if (inner[i] === '|') { cells.push(cell.trim()); cell = ''; }
    else cell += inner[i];
  }
  cells.push(cell.trim());
  return cells;
}
/// Where a table starts at `index`: its rows (header first), and how many lines it takes.
export function tableAt(lines, index) {
  if (!TABLE_ROW.test(lines[index] ?? '') || !isTableRule(lines[index + 1] ?? '')) return null;
  const rows = [tableCells(lines[index])];
  let end = index + 2;
  while (end < lines.length && TABLE_ROW.test(lines[end]) && !isTableRule(lines[end])) rows.push(tableCells(lines[end++]));
  return {rows, length: end - index};
}
let rowSerial = 0;
const newRowID = () => 'row-' + Date.now().toString(36) + '-' + (rowSerial++).toString(36);

export function markdownToDelta(text, format = 'markdown') {
  const ops = [];
  const lines = text.split('\n');
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    // A table becomes a grid: one line per cell, all of a row's cells sharing its id.
    const table = format === 'markdown' ? tableAt(lines, index) : null;
    if (table) {
      const columns = Math.max(...table.rows.map(row => row.length));
      for (const row of table.rows) {
        const id = newRowID();
        for (let column = 0; column < columns; column++) {
          ops.push(...inlineOps(row[column] ?? ''));
          ops.push({insert: '\n', attributes: {table: id}});
        }
      }
      index += table.length - 1;
      continue;
    }
    let body = line, attributes = {};
    if (format === 'bullets') attributes.list = 'bullet';
    else if (format === 'checklist') attributes.list = 'unchecked';
    else if (format === 'quote') attributes.blockquote = true;
    else if (format === 'markdown') {
      const heading = line.match(/^(#{1,6})\s+(.*)$/), quote = line.match(/^>\s?(.*)$/), list = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
      if (heading) { attributes.header = heading[1].length; body = heading[2]; }
      else if (quote) { attributes.blockquote = true; body = quote[1]; }
      else if (list) {
        body = list[3]; attributes.list = /^\d/.test(list[2]) ? 'ordered' : 'bullet';
        const check = body.match(/^\[([ xX])\]\s?(.*)$/); if (check) { attributes.list = check[1].toLowerCase() === 'x' ? 'checked' : 'unchecked'; body = check[2]; }
        const indent = Math.min(8, Math.floor(list[1].replace(/\t/g, '  ').length / 2)); if (indent) attributes.indent = indent;
      }
    }
    ops.push(...(format === 'plain' ? [{insert: body}] : inlineOps(body)));
    ops.push(Object.keys(attributes).length ? {insert: '\n', attributes} : {insert: '\n'});
  }
  return {ops: ops.filter(op => op.insert)};
}
export function deltaToMarkdown(delta) {
  const lines = [], numbers = new Map(); let segments = [];
  /// Neighbouring runs with the same emphasis share one pair of markers, kept
  /// inside any spaces at their edges ("**a b** c", never "**a ****b**").
  function renderLine() {
    let text = '';
    for (let i = 0; i < segments.length;) {
      const style = segments[i].style; let run = '';
      while (i < segments.length && segments[i].style === style) run += segments[i++].text;
      const [, lead, core, trail] = run.match(/^(\s*)([\s\S]*?)(\s*)$/);
      const marker = style === 'bi' ? '***' : style === 'b' ? '**' : style === 'i' ? '*' : '';
      text += core && marker ? lead + marker + core + marker + trail : run;
    }
    segments = [];
    return text;
  }
  function finish(attributes = {}) {
    const indent = Math.min(8, Math.max(0, attributes.indent || 0));
    let prefix = '';
    if (attributes.header) prefix = '#'.repeat(Math.min(6, attributes.header)) + ' ';
    else if (attributes.blockquote) prefix = '> ';
    else if (attributes.list) {
      prefix = '  '.repeat(indent);
      if (attributes.list === 'ordered') { const n = (numbers.get(indent) || 0) + 1; numbers.set(indent, n); prefix += `${n}. `; }
      else { numbers.delete(indent); prefix += attributes.list === 'checked' ? '- [x] ' : attributes.list === 'unchecked' ? '- [ ] ' : '- '; }
    } else numbers.clear();
    lines.push(prefix + renderLine());
  }
  /// A table's cells as they arrive: rows of cell text, by row id.
  let table = null;
  function finishTable() {
    if (!table) return;
    const columns = Math.max(1, ...table.map(row => row.cells.length));
    const render = cells => '| ' + Array.from({length: columns}, (_, i) => (cells[i] ?? '').replace(/\|/g, '\\|')).join(' | ') + ' |';
    lines.push(render(table[0].cells));
    lines.push('| ' + Array(columns).fill('---').join(' | ') + ' |');
    for (const row of table.slice(1)) lines.push(render(row.cells));
    table = null; numbers.clear();
  }
  function finishCell(id) {
    const text = renderLine();
    if (!table) table = [];
    const last = table[table.length - 1];
    if (last && last.id === id) last.cells.push(text); else table.push({id, cells: [text]});
  }
  for (const op of delta.ops ?? []) {
    if (typeof op.insert !== 'string') continue; // Image uploads are outside this first version.
    const parts = op.insert.split('\n');
    parts.forEach((part, index) => {
      const attributes = op.attributes ?? {};
      if (part) {
        const link = safeLink(attributes.link);
        const text = link && !isBareLink(part, link) ? `[${part}](${link})` : part;
        segments.push({text, style: (attributes.bold ? 'b' : '') + (attributes.italic ? 'i' : '')});
      }
      if (index < parts.length - 1) {
        if (attributes.table) finishCell(attributes.table);
        else { finishTable(); finish(attributes); }
      }
    });
  }
  finishTable();
  if (segments.length) lines.push(renderLine());
  return lines.join('\n');
}

/// Tables as readable lines, for previews: "Milk · 3.48", no rules or pipes.
export function tablesAsText(text) {
  const lines = text.split('\n'), out = [];
  for (let index = 0; index < lines.length; index++) {
    const table = tableAt(lines, index);
    if (!table) { out.push(lines[index]); continue; }
    for (const row of table.rows) out.push(row.filter(Boolean).join(' · '));
    index += table.length - 1;
  }
  return out.join('\n');
}
