// What a knowledge document IS.
//
// One markdown file per subject, small enough to read whole: YAML frontmatter
// that a machine can filter on, then prose split at '## ' headings. The split
// is the unit the index stores and search returns — a hit points at
// `id#heading`, which is an address a human can open and an agent can quote,
// not a byte offset into a 13 KB wall of text.
//
// The frontmatter is validated, not merely parsed. A document that lies about
// its own id is worse than one that has none: every other tool here addresses
// documents by id, so `id` must equal the filename stem and the loader refuses
// the file otherwise.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parse as parseYaml } from 'yaml';
import { z } from 'zod';

export const KINDS = ['cheatsheet', 'runbook', 'map', 'decision', 'note'] as const;
export type Kind = (typeof KINDS)[number];

export const SCOPES = ['global', 'project'] as const;
export type Scope = (typeof SCOPES)[number];

/** A slug: lowercase words joined by single dashes. Also the filename stem. */
export const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** A date that a calendar actually has: '2026-02-30' parses and is still wrong. */
function isRealDate(s: string): boolean {
  if (!DATE.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

export const FrontmatterSchema = z
  .object({
    id: z.string().regex(SLUG, 'id must be a slug: lowercase words joined by dashes'),
    title: z.string().min(1),
    kind: z.enum(KINDS),
    tags: z.array(z.string().regex(SLUG, 'a tag must be a slug')),
    updated: z.string().refine(isRealDate, 'updated must be a real YYYY-MM-DD date'),
    generated_from: z.string().min(1).optional(),
    scope: z.enum(SCOPES).optional(),
  })
  .strict();

export type Frontmatter = z.infer<typeof FrontmatterSchema>;

/** One '## ' section. The prose before the first heading is the chunk ''. */
export interface Chunk {
  readonly heading: string;
  readonly ord: number;
  readonly body: string;
}

export interface KnowledgeDoc {
  readonly meta: Frontmatter;
  /** Absolute path of the file this was read from. */
  readonly path: string;
  /** Everything after the frontmatter, verbatim. */
  readonly body: string;
  readonly chunks: readonly Chunk[];
  /** The whole file, frontmatter included — what `show <id>` prints. */
  readonly text: string;
  readonly hash: string;
}

/** A problem with one file, in a shape both the loader and `lint` report. */
export class DocError extends Error {
  readonly file: string;
  constructor(file: string, message: string) {
    super(message);
    this.name = 'DocError';
    this.file = file;
  }
}

const FENCE = /^\s*(```|~~~)/;
const HEADING = /^##\s+(.+?)\s*$/;

/**
 * Split a body at '## ' headings, ignoring fenced code. Cheat-sheets are full
 * of shell blocks whose comments start with '##', and a chunk boundary drawn
 * inside a code fence cuts a command in half.
 */
export function chunk(body: string): Chunk[] {
  const chunks: Chunk[] = [];
  let heading = '';
  let lines: string[] = [];
  let fence: string | null = null;
  const flush = (): void => {
    const text = lines.join('\n').trim();
    if (heading === '' && text === '') {
      lines = [];
      return; // a document that opens with a heading has no preamble
    }
    chunks.push({ heading, ord: chunks.length, body: text });
    lines = [];
  };
  for (const line of body.split('\n')) {
    const fenceHit = FENCE.exec(line);
    if (fenceHit) {
      const marker = fenceHit[1] ?? '';
      if (fence === null) fence = marker;
      else if (fence === marker) fence = null;
      lines.push(line);
      continue;
    }
    const head = fence === null ? HEADING.exec(line) : null;
    if (head) {
      flush();
      heading = head[1] ?? '';
      continue;
    }
    lines.push(line);
  }
  flush();
  return chunks;
}

/** Frontmatter block and the rest, without validating either. */
export function splitFrontmatter(text: string): { yaml: string; body: string } | null {
  const normalized = text.startsWith('﻿') ? text.slice(1) : text;
  if (!normalized.startsWith('---')) return null;
  const end = normalized.indexOf('\n---', 3);
  if (end === -1) return null;
  const after = normalized.indexOf('\n', end + 1);
  return {
    yaml: normalized.slice(normalized.indexOf('\n') + 1, end),
    body: after === -1 ? '' : normalized.slice(after + 1),
  };
}

export function hashOf(text: string): string {
  return createHash('sha256').update(text).digest('hex').slice(0, 32);
}

/** Parse one document. `file` decides the expected id; the text decides the rest. */
export function parseDoc(file: string, text: string): KnowledgeDoc {
  const parts = splitFrontmatter(text);
  if (!parts) throw new DocError(file, 'no YAML frontmatter: the file must open with a --- block');
  let raw: unknown;
  try {
    raw = parseYaml(parts.yaml);
  } catch (e) {
    throw new DocError(file, `frontmatter is not YAML: ${(e as Error).message}`);
  }
  const parsed = FrontmatterSchema.safeParse(raw ?? {});
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new DocError(file, `frontmatter: ${issues}`);
  }
  return {
    meta: parsed.data,
    path: file,
    body: parts.body,
    chunks: chunk(parts.body),
    text,
    hash: hashOf(text),
  };
}

/** The id a file's name promises. Addressing is by id, so the two must agree. */
export function stemOf(file: string): string {
  return path.basename(file).replace(/\.md$/, '');
}

/**
 * Read one document and hold it to the stem rule. `lint` deliberately does NOT
 * go through here: it parses with parseDoc and reports the mismatch as a
 * finding, because a report that stops at the first bad file is not a report.
 */
export function readDoc(file: string): KnowledgeDoc {
  const doc = parseDoc(file, fs.readFileSync(file, 'utf8'));
  const stem = stemOf(file);
  if (doc.meta.id !== stem)
    throw new DocError(file, `id "${doc.meta.id}" must equal the filename stem "${stem}"`);
  return doc;
}

/** Every *.md in the folder, sorted by id. Dotfiles and subdirectories are skipped. */
export function listFiles(dir: string): string[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    throw new Error(`knowledge directory ${dir} cannot be read`);
  }
  return entries
    .filter((e) => e.isFile() && e.name.endsWith('.md') && !e.name.startsWith('.'))
    .map((e) => path.join(dir, e.name))
    .sort();
}

export interface LoadResult {
  readonly docs: readonly KnowledgeDoc[];
  readonly errors: readonly DocError[];
}

/** Read the whole folder. One bad file is reported, not thrown. */
export function loadDir(dir: string): LoadResult {
  const docs: KnowledgeDoc[] = [];
  const errors: DocError[] = [];
  const seen = new Map<string, string>();
  for (const file of listFiles(dir)) {
    let doc: KnowledgeDoc;
    try {
      doc = readDoc(file);
    } catch (e) {
      errors.push(e instanceof DocError ? e : new DocError(file, (e as Error).message));
      continue;
    }
    const first = seen.get(doc.meta.id);
    if (first !== undefined) {
      errors.push(new DocError(file, `duplicate id "${doc.meta.id}", already used by ${first}`));
      continue;
    }
    seen.set(doc.meta.id, file);
    docs.push(doc);
  }
  return { docs, errors };
}

/** `[[id]]` / `[[id#heading]]` — the only link form this package understands. */
export const WIKILINK = /\[\[([^\]|#]+)(?:#([^\]|]+))?\]\]/g;

export interface Wikilink {
  readonly id: string;
  readonly heading: string | null;
}

export function wikilinks(body: string): Wikilink[] {
  const out: Wikilink[] = [];
  for (const m of body.matchAll(WIKILINK)) {
    const id = (m[1] ?? '').trim();
    const heading = m[2] === undefined ? null : m[2].trim();
    if (id) out.push({ id, heading });
  }
  return out;
}
