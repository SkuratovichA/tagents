// What a knowledge document IS.
//
// One markdown file per subject, small enough to read whole: YAML frontmatter
// that a machine can filter on, then prose split at '## ' headings. The split
// is the unit the index stores and search returns — a hit points at
// `id#heading`, which is an address a human can open and an agent can quote,
// not a byte offset into a 13 KB wall of text.
//
// The folder is an OKF v0.2 bundle and a document is an OKF concept, whose ID
// is the filename stem. Every other tool here addresses documents by id, so
// the stem is the id and a frontmatter `id` can only agree with it or be
// reported by `lint`.
//
// The LOADER is tolerant, as OKF asks of a consumer: unknown keys, a missing
// title or a malformed date never refuse a file, they load as absent. A file
// is refused only when it cannot be addressed or classified (no frontmatter,
// not YAML, neither `type` nor `kind`, a stem that is not a slug). The strict
// layer is `lint`, which reads `raw` and holds the folder to the profile.
//
// Legacy form (`kind`, `updated`, `generated_from`) is read and mapped onto the
// OKF fields so that a folder written before the change keeps loading.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parse as parseYaml } from 'yaml';

export const SCOPES = ['global', 'project'] as const;
export type Scope = (typeof SCOPES)[number];

export const STATUSES = ['draft', 'stable', 'deprecated'] as const;
export type Status = (typeof STATUSES)[number];

/** Filenames of an OKF bundle that are never documents. */
export const RESERVED_FILES: readonly string[] = ['index.md', 'log.md'];

/** The top-level keys this package's profile knows; `lint` reports the rest. */
export const OKF_KEYS: readonly string[] = [
  'type',
  'title',
  'description',
  'tags',
  'resource',
  'generated',
  'verified',
  'sources',
  'status',
  'stale_after',
  'scope',
  'id',
];
/** Extra keys a legacy document may carry. */
export const LEGACY_KEYS: readonly string[] = ['kind', 'updated', 'generated_from'];

/** A slug: lowercase words joined by single dashes. Also the filename stem. */
export const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const DATETIME = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

/** A date that a calendar actually has: '2026-02-30' parses and is still wrong. */
export function isRealDate(s: string): boolean {
  if (!DATE.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/**
 * An ISO 8601 datetime with an explicit offset (`Z` or `+hh:mm`) as epoch
 * milliseconds, or null. An offset is required because "10:00" means a
 * different instant in every place the folder is read.
 */
export function parseOffsetDatetime(value: unknown): number | null {
  if (typeof value !== 'string') return null;
  const m = DATETIME.exec(value);
  if (!m || !isRealDate(m[1] ?? '')) return null;
  const offset = m[5] ?? '';
  const offsetOk = offset === 'Z' || (Number(offset.slice(1, 3)) < 24 && Number(offset.slice(4, 6)) < 60);
  if (!offsetOk || Number(m[2]) > 23 || Number(m[3]) > 59 || Number(m[4] ?? 0) > 59) return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
}

/** The UTC calendar date (YYYY-MM-DD) of a datetime with an offset, or null. */
export function utcDateOf(at: unknown): string | null {
  const ms = parseOffsetDatetime(at);
  return ms === null ? null : new Date(ms).toISOString().slice(0, 10);
}

/** Stale means `stale_after` has been reached. Computed per query, never stored. */
export function isStale(staleAfter: string | null | undefined, nowMs: number): boolean {
  const limit = parseOffsetDatetime(staleAfter);
  return limit !== null && nowMs >= limit;
}

export interface Generated {
  readonly by: string;
  /** ISO 8601 datetime with an explicit offset. */
  readonly at: string;
}

export interface Source {
  readonly resource: string;
  readonly id: string | undefined;
  readonly title: string | undefined;
}

/** The tolerant view of a document's frontmatter. `raw` holds what was written. */
export interface Frontmatter {
  /** The filename stem. */
  readonly id: string;
  readonly type: string;
  readonly title: string;
  readonly description: string | undefined;
  readonly tags: readonly string[];
  readonly resource: string | undefined;
  readonly generated: Generated | undefined;
  readonly sources: readonly Source[];
  readonly status: Status;
  readonly staleAfter: string | undefined;
  readonly scope: Scope | undefined;
  /** True when the file was written in the legacy form (`kind`, `updated`). */
  readonly legacy: boolean;
}

/** One '## ' section. The prose before the first heading is the chunk ''. */
export interface Chunk {
  readonly heading: string;
  readonly ord: number;
  readonly body: string;
}

export interface KnowledgeDoc {
  readonly meta: Frontmatter;
  /** The frontmatter mapping exactly as parsed: what `lint` validates. */
  readonly raw: Readonly<Record<string, unknown>>;
  /** The frontmatter `id` key when it is a string, else null. */
  readonly declaredId: string | null;
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

/** Each line of a body, and whether it sits in (or opens, or closes) a fenced code block. */
function* scanFences(body: string): Generator<{ line: string; inFence: boolean }> {
  let fence: string | null = null;
  for (const line of body.split('\n')) {
    const hit = FENCE.exec(line);
    if (hit) {
      const marker = hit[1] ?? '';
      if (fence === null) fence = marker;
      else if (fence === marker) fence = null;
      yield { line, inFence: true };
      continue;
    }
    yield { line, inFence: fence !== null };
  }
}

/**
 * Split a body at '## ' headings, ignoring fenced code. Cheat-sheets are full
 * of shell blocks whose comments start with '##', and a chunk boundary drawn
 * inside a code fence cuts a command in half.
 */
export function chunk(body: string): Chunk[] {
  const chunks: Chunk[] = [];
  let heading = '';
  let lines: string[] = [];
  const flush = (): void => {
    const text = lines.join('\n').trim();
    if (heading === '' && text === '') {
      lines = [];
      return; // a document that opens with a heading has no preamble
    }
    chunks.push({ heading, ord: chunks.length, body: text });
    lines = [];
  };
  for (const { line, inFence } of scanFences(body)) {
    const head = inFence ? null : HEADING.exec(line);
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

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function nonEmpty(v: unknown): string | undefined {
  return typeof v === 'string' && v.trim() !== '' ? v : undefined;
}

function generatedOf(v: unknown): Generated | undefined {
  if (!isRecord(v)) return undefined;
  const by = nonEmpty(v['by']);
  const at = v['at'];
  return by !== undefined && typeof at === 'string' && parseOffsetDatetime(at) !== null ? { by, at } : undefined;
}

function sourcesOf(v: unknown): Source[] {
  if (!Array.isArray(v)) return [];
  const out: Source[] = [];
  const entries: unknown[] = v;
  for (const entry of entries) {
    if (!isRecord(entry)) continue;
    const resource = nonEmpty(entry['resource']);
    if (resource === undefined) continue;
    out.push({ resource, id: nonEmpty(entry['id']), title: nonEmpty(entry['title']) });
  }
  return out;
}

function stringsOf(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  const items: unknown[] = v;
  return items.filter((t): t is string => typeof t === 'string');
}

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/** The id a file's name promises. Addressing is by id, so the two must agree. */
export function stemOf(file: string): string {
  return path.basename(file).replace(/\.md$/, '');
}

/**
 * Parse one document. `file` decides the id (its stem); the text decides the
 * rest. Tolerant: see the top of this file for what is refused. A stem that
 * is not a slug is NOT refused here — `readDoc` does that — so that `lint`
 * can parse the file and report the stem as a finding of its own.
 */
export function parseDoc(file: string, text: string): KnowledgeDoc {
  const parts = splitFrontmatter(text);
  if (!parts) throw new DocError(file, 'no YAML frontmatter: the file must open with a --- block');
  let parsed: unknown;
  try {
    parsed = parseYaml(parts.yaml);
  } catch (e) {
    throw new DocError(file, `frontmatter is not YAML: ${(e as Error).message}`);
  }
  if (parsed !== null && parsed !== undefined && !isRecord(parsed))
    throw new DocError(file, 'frontmatter: (root): expected a mapping of keys to values');
  const raw: Record<string, unknown> = isRecord(parsed) ? parsed : {};

  const legacy = raw['type'] === undefined && raw['kind'] !== undefined;
  const typeKey = legacy ? 'kind' : 'type';
  if (raw[typeKey] === undefined)
    throw new DocError(file, 'frontmatter: type: required — a document needs a `type` (legacy: `kind`)');
  const written = nonEmpty(raw[typeKey]);
  if (written === undefined) throw new DocError(file, `frontmatter: ${typeKey}: must be a non-empty string`);

  const id = stemOf(file);
  const updated = typeof raw['updated'] === 'string' && isRealDate(raw['updated']) ? raw['updated'] : undefined;
  const generatedFrom = nonEmpty(raw['generated_from']);
  const statusWritten = STATUSES.find((s) => s === raw['status']);
  const scope = SCOPES.find((s) => s === raw['scope']);
  const stale = raw['stale_after'];
  const meta: Frontmatter = {
    id,
    type: legacy ? capitalise(written) : written,
    title: nonEmpty(raw['title']) ?? id,
    description: nonEmpty(raw['description'])?.trim(),
    tags: stringsOf(raw['tags']),
    resource: nonEmpty(raw['resource']),
    generated: legacy
      ? updated === undefined
        ? undefined
        : { by: 'legacy', at: `${updated}T00:00:00Z` }
      : generatedOf(raw['generated']),
    sources: legacy ? (generatedFrom === undefined ? [] : [{ resource: generatedFrom, id: undefined, title: undefined }]) : sourcesOf(raw['sources']),
    status: statusWritten ?? 'stable',
    staleAfter: typeof stale === 'string' && parseOffsetDatetime(stale) !== null ? stale : undefined,
    scope,
    legacy,
  };
  return {
    meta,
    raw,
    declaredId: typeof raw['id'] === 'string' ? raw['id'] : null,
    path: file,
    body: parts.body,
    chunks: chunk(parts.body),
    text,
    hash: hashOf(text),
  };
}

/**
 * Read one document and hold it to the slug rule. `lint` deliberately does NOT
 * go through here: it parses with parseDoc and reports a bad stem as a
 * finding, because a report that stops at the first bad file is not a report.
 */
export function readDoc(file: string): KnowledgeDoc {
  const stem = stemOf(file);
  if (!SLUG.test(stem))
    throw new DocError(file, `filename stem "${stem}" must be a slug: lowercase words joined by single dashes`);
  return parseDoc(file, fs.readFileSync(file, 'utf8'));
}

/** Every document file in the folder, sorted by id. Dotfiles, subdirectories and `index.md`/`log.md` are skipped. */
export function listFiles(dir: string): string[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    throw new Error(`knowledge directory ${dir} cannot be read`);
  }
  return entries
    .filter((e) => e.isFile() && e.name.endsWith('.md') && !e.name.startsWith('.') && !RESERVED_FILES.includes(e.name))
    .map((e) => path.join(dir, e.name))
    .sort();
}

export interface LoadResult {
  readonly docs: readonly KnowledgeDoc[];
  readonly errors: readonly DocError[];
}

/** Read the whole folder. One bad file is reported, not thrown. Ids are stems, so they cannot collide. */
export function loadDir(dir: string): LoadResult {
  const docs: KnowledgeDoc[] = [];
  const errors: DocError[] = [];
  for (const file of listFiles(dir)) {
    try {
      docs.push(readDoc(file));
    } catch (e) {
      errors.push(e instanceof DocError ? e : new DocError(file, (e as Error).message));
    }
  }
  return { docs, errors };
}

/** `[[id]]` / `[[id#heading]]`. */
export const WIKILINK = /\[\[([^\]|#]+)(?:#([^\]|]+))?\]\]/g;
/** `[text](target)` — the target has no spaces; images (`![`) are not links to documents. */
const MARKDOWN_LINK = /(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const URL_SCHEME = /^[a-z][a-z0-9+.-]*:/i;

export interface Wikilink {
  readonly id: string;
  readonly heading: string | null;
}

/** A link from one document to another (or to one of its sections), in either form. */
export interface DocLink {
  readonly form: 'wiki' | 'markdown';
  /** The link exactly as written, for messages. */
  readonly raw: string;
  readonly id: string;
  /** The heading (wikilink) or fragment (markdown link) as written, or null. */
  readonly fragment: string | null;
}

function markdownTarget(target: string): { id: string; fragment: string | null } | null {
  if (URL_SCHEME.test(target)) return null;
  const hash = target.indexOf('#');
  const file = hash === -1 ? target : target.slice(0, hash);
  if (!file.endsWith('.md')) return null;
  const id = file.slice(0, -3).replace(/^\.?\//, '');
  if (id === '') return null;
  const fragment = hash === -1 ? '' : target.slice(hash + 1);
  return { id, fragment: fragment === '' ? null : fragment };
}

/**
 * Every link to a document of the bundle in a body, in document order per
 * line: `[[id]]`, `[[id#Heading]]` and the markdown forms `[t](/id.md#frag)`,
 * `[t](./id.md)`, `[t](id.md)`. Links in fenced code are not links. A target
 * with a URL scheme, one that is not a `.md` file, or a bare `#fragment` is
 * not a document link.
 */
export function documentLinks(body: string): DocLink[] {
  const out: DocLink[] = [];
  for (const { line, inFence } of scanFences(body)) {
    if (inFence) continue;
    for (const m of line.matchAll(WIKILINK)) {
      const id = (m[1] ?? '').trim();
      if (id) out.push({ form: 'wiki', raw: m[0], id, fragment: m[2] === undefined ? null : m[2].trim() });
    }
    for (const m of line.matchAll(MARKDOWN_LINK)) {
      const target = markdownTarget(m[1] ?? '');
      if (target) out.push({ form: 'markdown', raw: m[0], id: target.id, fragment: target.fragment });
    }
  }
  return out;
}

export function wikilinks(body: string): Wikilink[] {
  return documentLinks(body)
    .filter((l) => l.form === 'wiki')
    .map((l) => ({ id: l.id, heading: l.fragment }));
}

/** GitHub-style anchor of a heading: lowercase, spaces to dashes, everything but letters, digits and dashes dropped. */
export function headingSlug(heading: string): string {
  return heading
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s/g, '-');
}

/** A markdown-link fragment names a heading when it equals the text (case-insensitive, URL-decoded) or its slug. */
export function fragmentMatches(fragment: string, heading: string): boolean {
  let decoded = fragment;
  try {
    decoded = decodeURIComponent(fragment);
  } catch {
    // a malformed escape is compared as written
  }
  const want = decoded.trim().toLowerCase();
  return heading.trim().toLowerCase() === want || headingSlug(heading) === want;
}
