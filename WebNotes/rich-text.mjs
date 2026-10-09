import {safeLink} from './core.mjs';
function inlineOps(text, attributes = {}) {
  const ops = [], pattern = /(\*\*\*([\s\S]+?)\*\*\*|\*\*([\s\S]+?)\*\*|\*([^*]+)\*|\[([^\]]+)\]\(([^)]+)\))/g;
  let offset = 0;
  const add = (insert, attrs = attributes) => { if (insert) ops.push(Object.keys(attrs).length ? {insert, attributes: attrs} : {insert}); };
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
  const lines = [], numbers = new Map(); let line = '';
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
    lines.push(prefix + line); line = '';
  }
  for (const op of delta.ops ?? []) {
    if (typeof op.insert !== 'string') continue; // Image uploads are outside this first version.
    const parts = op.insert.split('\n');
    parts.forEach((part, index) => {
      const attributes = op.attributes ?? {};
      let text = part;
      if (part && attributes.bold && attributes.italic) text = `***${text}***`;
      else if (part && attributes.bold) text = `**${text}**`;
      else if (part && attributes.italic) text = `*${text}*`;
      const link = safeLink(attributes.link); if (part && link) text = `[${text}](${link})`;
      line += text;
      if (index < parts.length - 1) finish(attributes);
    });
  }
  if (line) lines.push(line);
  return lines.join('\n');
}
