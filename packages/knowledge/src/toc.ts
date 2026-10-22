// The OKF progressive-disclosure file: `index.md` at the folder root.
//
// `toc` writes it and `lint` checks it, and both go through `renderIndex`, so
// what lint calls "out of date" is exactly what toc would change. The output is
// a pure function of the documents: same folder, same bytes.
import fs from 'node:fs';
import path from 'node:path';
import type { KnowledgeDoc } from './doc.ts';

export const INDEX_FILE = 'index.md';

const HEAD = '---\nokf_version: "0.2"\n---\n';

const oneLine = (s: string): string => s.replace(/\s+/g, ' ').trim();

/** Code-unit order, not locale order: the same folder gives the same bytes on every machine. */
const byText = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

/** The text of `index.md` for these documents: groups by type, entries by id. */
export function renderIndex(docs: readonly KnowledgeDoc[]): string {
  const groups = new Map<string, { heading: string; lines: string[] }>();
  for (const doc of [...docs].sort((a, b) => byText(a.meta.id, b.meta.id))) {
    const key = doc.meta.type.toLowerCase();
    let group = groups.get(key);
    if (group === undefined) {
      // types that differ only in case share the first spelling, in id order
      group = { heading: oneLine(doc.meta.type), lines: [] };
      groups.set(key, group);
    }
    const description = doc.meta.description === undefined ? '' : ` - ${oneLine(doc.meta.description)}`;
    const deprecated = doc.meta.status === 'deprecated' ? ' (deprecated)' : '';
    group.lines.push(`* [${oneLine(doc.meta.title)}](${doc.meta.id}.md)${description}${deprecated}`);
  }
  if (groups.size === 0) return HEAD;
  const body = [...groups.entries()]
    .sort(([a], [b]) => byText(a, b))
    .map(([, g]) => `# ${g.heading}\n\n${g.lines.join('\n')}`);
  return `${HEAD}\n${body.join('\n\n')}\n`;
}

export type IndexState = 'current' | 'missing' | 'outdated';

/** How the `index.md` on disk compares with what `renderIndex` gives for `docs`. */
export function indexState(dir: string, docs: readonly KnowledgeDoc[]): IndexState {
  let onDisk: string;
  try {
    onDisk = fs.readFileSync(path.join(dir, INDEX_FILE), 'utf8');
  } catch {
    return 'missing';
  }
  return onDisk === renderIndex(docs) ? 'current' : 'outdated';
}

/** Write `index.md` and return its path. */
export function writeIndex(dir: string, docs: readonly KnowledgeDoc[]): string {
  const file = path.join(dir, INDEX_FILE);
  fs.writeFileSync(file, renderIndex(docs));
  return file;
}
