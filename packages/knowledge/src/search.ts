// Asking the index a question.
//
// A hit is a CHUNK, addressed as `id#heading`: the answer to "where is this
// written down" is a section a human can open, not a document to re-read.
//
// Ranking is bm25 with the heading weighted ten times the body. A section
// CALLED "Deploy" is what somebody searching for "deploy" wants; a section
// that mentions deploying once, in passing, is not. The weight is what makes
// that ordering, not the order rows happen to come out of FTS5.
//
// A deprecated document is ranked after every other and never hidden: the
// reader who searches for the retired system should find it, below the live
// one, marked as retired. Staleness is a question about NOW, so it is computed
// here, per query, from a clock the caller may inject.
import type { DatabaseSync } from 'node:sqlite';
import type { SQLInputValue } from 'node:sqlite';
import { realClock, type TurnClock } from '@tagents/core';
import { int, text, type Row } from './db.ts';
import { STATUSES, isStale, oneLine, utcDateOf, type Status } from './doc.ts';

export const HEADING_WEIGHT = 10;
export const BODY_WEIGHT = 1;
export const DEFAULT_LIMIT = 10;
export const SNIPPET_TOKENS = 14;

/** Where a query gets "now" from: the real clock, or a fake one in a test. */
export type Clock = Pick<TurnClock, 'now'>;

export interface Lifecycle {
  readonly type: string;
  /** '' when the document has none. */
  readonly description: string;
  readonly status: Status;
  /** `stale_after` has been reached, as of the query. */
  readonly stale: boolean;
}

export interface Hit extends Lifecycle {
  readonly id: string;
  readonly title: string;
  /** '' for the preamble chunk. */
  readonly heading: string;
  readonly score: number;
  readonly snippet: string;
  readonly path: string;
}

export interface Filters {
  readonly tag?: string;
  /** Exact, case-insensitive. */
  readonly type?: string;
  /** Deprecated alias of `type`; `type` wins when both are given. */
  readonly kind?: string;
}

export interface Timed {
  readonly now?: Clock;
}

export interface SearchOptions extends Filters, Timed {
  readonly limit?: number;
}

function lifecycle(row: Row, now: Clock): Lifecycle {
  const stale = row['stale_after'];
  return {
    type: text(row, 'type'),
    description: text(row, 'description'),
    status: STATUSES.find((s) => s === text(row, 'status')) ?? 'stable',
    stale: typeof stale === 'string' && isStale(stale, now.now()),
  };
}

/**
 * Words → an FTS5 MATCH expression.
 *
 * Everything a user types is quoted, because an unquoted '-' means NOT and an
 * unbalanced '"' is a syntax error — a search box must not be able to crash on
 * `tmux-agent-state.sh`. A trailing '*' survives quoting as FTS5's prefix
 * operator, which is how `deplo*` stays useful.
 */
export function ftsQuery(words: readonly string[]): string {
  const terms: string[] = [];
  for (const raw of words.join(' ').split(/\s+/)) {
    const prefix = raw.endsWith('*');
    const bare = (prefix ? raw.slice(0, -1) : raw).replace(/"/g, '');
    if (!bare.trim()) continue;
    terms.push(`"${bare}"${prefix ? '*' : ''}`);
  }
  return terms.join(' ');
}

function filterSql(f: Filters): { sql: string; params: SQLInputValue[] } {
  const sql: string[] = [];
  const params: SQLInputValue[] = [];
  const type = f.type !== undefined && f.type !== '' ? f.type : f.kind;
  if (type !== undefined && type !== '') {
    sql.push('and docs.type_key = ?');
    params.push(type.toLowerCase());
  }
  if (f.tag !== undefined && f.tag !== '') {
    sql.push('and exists (select 1 from json_each(docs.tags) where value = ?)');
    params.push(f.tag);
  }
  return { sql: sql.join(' '), params };
}

export function search(db: DatabaseSync, words: readonly string[], options: SearchOptions = {}): Hit[] {
  const match = ftsQuery(words);
  if (!match) return [];
  const limit = options.limit !== undefined && options.limit > 0 ? Math.floor(options.limit) : DEFAULT_LIMIT;
  const where = filterSql(options);
  const sql = `
    select docs.id as id, docs.title as title, docs.path as path,
           docs.type as type, docs.description as description, docs.status as status,
           docs.stale_after as stale_after,
           chunks.heading as heading,
           bm25(chunks_fts, 0.0, ${HEADING_WEIGHT}.0, ${BODY_WEIGHT}.0) as rank,
           snippet(chunks_fts, 2, '[', ']', '…', ${SNIPPET_TOKENS}) as snip
      from chunks_fts
      join chunks on chunks.rowid = chunks_fts.rowid
      join docs on docs.id = chunks.doc_id
     where chunks_fts match ? ${where.sql}
     order by (docs.status = 'deprecated') asc, rank asc, docs.id asc, chunks.ord asc
     limit ?`;
  let rows: Row[];
  try {
    rows = db.prepare(sql).all(match, ...where.params, limit);
  } catch {
    return []; // a MATCH expression FTS5 refuses is an empty result, not a crash
  }
  const now = options.now ?? realClock;
  return rows.map((row) => ({
    ...lifecycle(row, now),
    id: text(row, 'id'),
    title: text(row, 'title'),
    heading: text(row, 'heading'),
    // bm25 counts down from zero; callers want "bigger is better".
    score: Math.round(-Number(row['rank'] ?? 0) * 1000) / 1000,
    snippet: oneLine(text(row, 'snip')),
    path: text(row, 'path'),
  }));
}

export interface DocSummary extends Lifecycle {
  readonly id: string;
  readonly title: string;
  readonly tags: readonly string[];
  /** The UTC date of `generated.at`, or '-' when the document has no `generated`. */
  readonly updated: string;
  readonly path: string;
  readonly headings: readonly string[];
}

function tagsOf(row: Row): string[] {
  const parsed: unknown = JSON.parse(text(row, 'tags') || '[]');
  return Array.isArray(parsed) ? parsed.filter((t): t is string => typeof t === 'string') : [];
}

function summary(db: DatabaseSync, row: Row, now: Clock): DocSummary {
  const id = text(row, 'id');
  const headings = db
    .prepare('select heading from chunks where doc_id = ? order by ord asc')
    .all(id)
    .map((r) => text(r, 'heading'))
    .filter((h) => h !== '');
  return {
    ...lifecycle(row, now),
    id,
    title: text(row, 'title'),
    tags: tagsOf(row),
    updated: utcDateOf(text(row, 'generated_at')) ?? '-',
    path: text(row, 'path'),
    headings,
  };
}

export function listDocs(db: DatabaseSync, filters: Filters & Timed = {}): DocSummary[] {
  const where = filterSql(filters);
  const now = filters.now ?? realClock;
  const rows = db
    .prepare(`select * from docs where 1 = 1 ${where.sql} order by (docs.status = 'deprecated') asc, docs.id asc`)
    .all(...where.params);
  return rows.map((row) => summary(db, row, now));
}

export function getDoc(db: DatabaseSync, id: string, now: Clock = realClock): DocSummary | null {
  const row = db.prepare('select * from docs where id = ?').get(id);
  return row ? summary(db, row, now) : null;
}

export interface Section {
  readonly id: string;
  readonly heading: string;
  readonly ord: number;
  readonly body: string;
}

/**
 * One '## ' section (heading '' is the preamble), or null when there is none.
 *
 * The heading is matched case-insensitively IN JAVASCRIPT, not with SQLite's
 * `collate nocase`: that collation folds ASCII only, so `диски` would never
 * find `Диски` and half the corpus would be unaddressable.
 */
export function getSection(db: DatabaseSync, id: string, heading: string): Section | null {
  const want = heading.trim().toLowerCase();
  const rows = db.prepare('select heading, ord, body from chunks where doc_id = ? order by ord asc').all(id);
  const row = rows.find((r) => text(r, 'heading').toLowerCase() === want);
  return row
    ? { id, heading: text(row, 'heading'), ord: int(row, 'ord'), body: text(row, 'body') }
    : null;
}

/** `id#heading` → its two halves. A bare id means the whole document. */
export function parseAddress(address: string): { id: string; heading: string | null } {
  const hash = address.indexOf('#');
  if (hash === -1) return { id: address.trim(), heading: null };
  return { id: address.slice(0, hash).trim(), heading: address.slice(hash + 1).trim() };
}
