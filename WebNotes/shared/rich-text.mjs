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
export function markdownToDelta(text, format = 'markdown') {
  const ops = [];
  for (const line of text.split('\n')) {
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
      if (index < parts.length - 1) finish(attributes);
    });
  }
  if (segments.length) lines.push(renderLine());
  return lines.join('\n');
}
