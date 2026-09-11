// The index: SQLite with one FTS5 table over the chunks.
//
// TOKENIZER. The corpus is Russian and English prose with shell commands and
// identifiers in it, so the tokenizer decision is the search quality decision:
//
//   unicode61 remove_diacritics 2  — CHOSEN. Unicode-aware word splitting, so
//     Cyrillic is tokenised as words rather than dropped into one blob, and
//     `remove_diacritics 2` folds diacritics correctly for multi-byte text
//     (mode 1 mishandles anything outside Latin-1, and ё/й survive either way
//     because SQLite treats them as their own letters). Identifiers like
//     `tmux-agent-state.sh` split on the punctuation into searchable words.
//   trigram — REJECTED. It would match substrings (useful for `grep`-ish
//     lookups), but it indexes every 3-character window: several times the
//     rows for a corpus this small to gain, and bm25 over trigrams ranks by
//     how many windows coincide, which puts unrelated documents above the one
//     that actually discusses the term.
//   porter/snowball on top — REJECTED. English-only stemming would help
//     English recall and do nothing for the Russian half, at the cost of
//     matching words the author did not write.
//
// A separate `tokenchars` list is deliberately not set: keeping '-' and '.' as
// separators is what makes `agent state` find `tmux-agent-state.sh`.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { SQLInputValue, SQLOutputValue } from 'node:sqlite';
import { DocError, listFiles, readDoc, stemOf, type KnowledgeDoc } from './doc.ts';

export const SCHEMA_VERSION = 1;
export const TOKENIZER = 'unicode61 remove_diacritics 2';

export type Row = Record<string, SQLOutputValue>;

export function text(row: Row, key: string): string {
  const v = row[key];
  if (typeof v === 'string') return v;
  return v === null || v === undefined ? '' : String(v);
}

export function int(row: Row, key: string): number {
  const v = row[key];
  if (typeof v === 'number') return v;
  if (typeof v === 'bigint') return Number(v);
  return Number(v ?? 0);
}

/**
 * node:sqlite is still flagged experimental, and Node says so on stderr the
 * first time it is loaded. This CLI's stderr carries errors a human is meant
 * to read (and a test pins), so the notice is dropped while every other
 * warning keeps printing.
 */
export function silenceSqliteWarning(): void {
  process.removeAllListeners('warning');
  process.on('warning', (w: Error) => {
    if (w.name === 'ExperimentalWarning' && w.message.includes('SQLite')) return;
    process.stderr.write(`${w.name}: ${w.message}\n`);
  });
}

const DDL = `
create table if not exists meta (key text primary key, value text not null);

create table if not exists docs (
  id      text primary key,
  path    text not null,
  title   text not null,
  kind    text not null,
  tags    text not null,           -- a JSON array, queried with json_each
  updated text not null,
  mtime   integer not null,        -- ms, the file's mtime at index time
  hash    text not null            -- sha256 of the file, first 32 hex chars
);

create table if not exists chunks (
  doc_id  text not null references docs(id) on delete cascade,
  heading text not null,           -- '' is the preamble before the first '## '
  ord     integer not null,
  body    text not null,
  primary key (doc_id, ord)
);

create index if not exists chunks_by_doc on chunks(doc_id);

create virtual table if not exists chunks_fts using fts5(
  doc_id unindexed,
  heading,
  body,
  tokenize='${TOKENIZER}'
);
`;

/** Open (creating it if need be) and bring the schema up to date. */
export function openDb(file: string): DatabaseSync {
  silenceSqliteWarning();
  if (file !== ':memory:') fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec('pragma foreign_keys = on');
  const version = schemaVersion(db);
  // No migration path while the schema is one version old: the index is a
  // derived artefact, and rebuilding it from the markdown costs milliseconds.
  if (version !== null && version !== SCHEMA_VERSION) drop(db);
  db.exec(DDL);
  db.prepare('insert or replace into meta (key, value) values (?, ?)').run(
    'schema_version',
    String(SCHEMA_VERSION)
  );
  return db;
}

function schemaVersion(db: DatabaseSync): number | null {
  try {
    const row = db.prepare("select value from meta where key = 'schema_version'").get();
    return row ? int(row, 'value') : null;
  } catch {
    return null; // no meta table yet: a fresh file
  }
}

function drop(db: DatabaseSync): void {
  for (const t of ['chunks_fts', 'chunks', 'docs', 'meta']) db.exec(`drop table if exists ${t}`);
}

export interface IndexStats {
  readonly added: number;
  readonly changed: number;
  readonly unchanged: number;
  readonly removed: number;
  readonly errors: readonly DocError[];
}

function deleteDoc(db: DatabaseSync, id: string): void {
  db.prepare('delete from chunks_fts where doc_id = ?').run(id);
  db.prepare('delete from chunks where doc_id = ?').run(id);
  db.prepare('delete from docs where id = ?').run(id);
}

function insertDoc(db: DatabaseSync, doc: KnowledgeDoc, mtime: number): void {
  db.prepare(
    'insert into docs (id, path, title, kind, tags, updated, mtime, hash) values (?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(
    doc.meta.id,
    doc.path,
    doc.meta.title,
    doc.meta.kind,
    JSON.stringify(doc.meta.tags),
    doc.meta.updated,
    Math.floor(mtime),
    doc.hash
  );
  const chunkStmt = db.prepare('insert into chunks (doc_id, heading, ord, body) values (?, ?, ?, ?)');
  const ftsStmt = db.prepare('insert into chunks_fts (rowid, doc_id, heading, body) values (?, ?, ?, ?)');
  for (const c of doc.chunks) {
    const changes = chunkStmt.run(doc.meta.id, c.heading, c.ord, c.body);
    // The FTS table shares the chunks rowid: that is the join, and it is why
    // a delete has to walk both tables.
    ftsStmt.run(toInput(changes.lastInsertRowid), doc.meta.id, c.heading, c.body);
  }
}

function toInput(v: number | bigint): SQLInputValue {
  return typeof v === 'bigint' ? v : Math.floor(v);
}

/**
 * Bring the index in line with the folder.
 *
 * A file whose mtime is unchanged is not even read; one whose mtime moved is
 * read and compared by hash, so `git checkout` (which rewrites mtimes and not
 * content) costs a hash, not a reindex. Documents whose file is gone are
 * dropped.
 */
export function reindex(db: DatabaseSync, dir: string, options: { full?: boolean } = {}): IndexStats {
  if (options.full === true) {
    db.exec('delete from chunks_fts');
    db.exec('delete from chunks');
    db.exec('delete from docs');
  }
  const known = new Map<string, { mtime: number; hash: string }>();
  for (const row of db.prepare('select id, mtime, hash from docs').all())
    known.set(text(row, 'id'), { mtime: int(row, 'mtime'), hash: text(row, 'hash') });

  const errors: DocError[] = [];
  const seen = new Set<string>();
  let added = 0;
  let changed = 0;
  let unchanged = 0;

  for (const file of listFiles(dir)) {
    const id = stemOf(file);
    let mtime: number;
    try {
      mtime = Math.floor(fs.statSync(file).mtimeMs);
    } catch {
      continue; // a file that vanished between readdir and stat
    }
    seen.add(id);
    const before = known.get(id);
    if (before && before.mtime === mtime) {
      unchanged++;
      continue;
    }
    let doc: KnowledgeDoc;
    try {
      doc = readDoc(file);
    } catch (e) {
      errors.push(e instanceof DocError ? e : new DocError(file, (e as Error).message));
      // A file that stopped parsing must not keep serving its last good text.
      if (before) deleteDoc(db, id);
      seen.delete(id);
      continue;
    }
    if (before && before.hash === doc.hash) {
      db.prepare('update docs set mtime = ? where id = ?').run(mtime, id);
      unchanged++;
      continue;
    }
    if (before) deleteDoc(db, id);
    insertDoc(db, doc, mtime);
    if (before) changed++;
    else added++;
  }

  let removed = 0;
  for (const id of known.keys()) {
    if (seen.has(id)) continue;
    deleteDoc(db, id);
    removed++;
  }
  return { added, changed, unchanged, removed, errors };
}

export function docCount(db: DatabaseSync): number {
  const row = db.prepare('select count(*) as n from docs').get();
  return row ? int(row, 'n') : 0;
}
