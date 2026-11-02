// The engine section of the knowledge vectors: what the index is made of (the DDL, the tokenizer, the SQLite that runs it), how it follows a folder, and the arithmetic of a file's modification time.
//
// The Rust program builds the same file with a bundled SQLite, so each thing the two could disagree on is written here as node does it: the text of the schema, the terms the tokenizer gives every code point of the Basic Multilingual Plane, the rows after each step of a life of an index.
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { DocError } from '../../packages/knowledge/src/doc.ts';
import { INDEX_BUSY_TIMEOUT_MS, SCHEMA_VERSION, TOKENIZER, openDb, reindex, silenceSqliteWarning } from '../../packages/knowledge/src/db.ts';
import { BUSY_TIMEOUT_MS, RETENTION_DAYS, openUsageDb } from '../../packages/knowledge/src/usage.ts';
import { plain, relativize, scratch } from './util.mts';

type Table = Array<Record<string, unknown>>;

function rowsOf(db: DatabaseSync, sql: string): Table {
  return db.prepare(sql).all().map((row) => ({ ...row }));
}

/** Everything `sqlite_master` holds, which is the DDL text as SQLite stored it, comments included. */
function master(db: DatabaseSync): Table {
  return rowsOf(db, 'select type, name, tbl_name, sql from sqlite_master order by type, name');
}

// ---- schema ----------------------------------------------------------------------------------

/** What a connection reports about itself once `openDb` or `openUsageDb` has run: the settings the code asks for, read back from SQLite and not from the constant that was passed. */
function applied(db: DatabaseSync): Record<string, unknown> {
  const setting = (pragma: string, column: string): unknown => rowsOf(db, `pragma ${pragma}`)[0]?.[column];
  return {
    busyTimeout: setting('busy_timeout', 'timeout'),
    journalMode: setting('journal_mode', 'journal_mode'),
    synchronous: setting('synchronous', 'synchronous'),
    foreignKeys: setting('foreign_keys', 'foreign_keys'),
  };
}

export function schemaVectors(): unknown {
  silenceSqliteWarning();
  const dir = scratch('schema');
  const index = openDb(path.join(dir, 'nested', 'index.sqlite'));
  const meta = rowsOf(index, 'select key, value from meta order by key');
  const indexMaster = master(index);
  const indexApplied = applied(index);
  index.close();
  const usage = openUsageDb(path.join(dir, 'nested', 'usage.sqlite'));
  const usageMaster = master(usage);
  const usageApplied = applied(usage);
  usage.close();
  const probe = new DatabaseSync(':memory:');
  const sqlite = rowsOf(probe, 'select sqlite_version() as version')[0];
  // The compiler that built node is no part of what the index does, and it differs between the machines that regenerate the vectors.
  const compileOptions = rowsOf(probe, 'pragma compile_options')
    .map((row) => row['compile_options'])
    .filter((option) => typeof option !== 'string' || !option.startsWith('COMPILER='));
  probe.close();
  return {
    schemaVersion: SCHEMA_VERSION,
    tokenizer: TOKENIZER,
    indexBusyMs: INDEX_BUSY_TIMEOUT_MS,
    usageBusyMs: BUSY_TIMEOUT_MS,
    retentionDays: RETENTION_DAYS,
    applied: { index: indexApplied, usage: usageApplied },
    meta,
    indexMaster,
    usageMaster,
    sqliteVersion: sqlite?.['version'] ?? null,
    compileOptions,
  };
}

// ---- schema versions -------------------------------------------------------------------------

/** A file that carries `value` as its schema version and a row in `docs` that only a rebuild removes. The version is read the way node reads it: as a JavaScript number. */
const VERSION_VALUES = ['1', '2', '3', '0', '', ' 2 ', '2.0', '0x2', '2e0', '+2', '-2', 'abc', 'Infinity', '2 3', '02', '\t2\n'];

function versionVectors(): unknown {
  const dir = scratch('versions');
  const cases = VERSION_VALUES.map((value, i) => {
    const file = path.join(dir, `v-${i}.sqlite`);
    const seed = new DatabaseSync(file);
    seed.exec('create table meta (key text primary key, value text not null)');
    seed.prepare("insert into meta (key, value) values ('schema_version', ?)").run(value);
    seed.exec("create table docs (id text primary key, note text); insert into docs (id, note) values ('old', 'x')");
    seed.exec("create virtual table chunks_fts using fts5(only_column)");
    seed.close();
    const db = openDb(file);
    const survived = rowsOf(db, "select name from sqlite_master where type = 'table' and name = 'docs'").length === 1 && rowsOf(db, "select 1 from pragma_table_info('docs') where name = 'note'").length === 1;
    const version = rowsOf(db, "select value from meta where key = 'schema_version'");
    const tables = rowsOf(db, "select name from sqlite_master where type = 'table' and name not like 'chunks_fts_%' order by name");
    db.close();
    return { value, setup: ['create table meta (key text primary key, value text not null)', "create table docs (id text primary key, note text)", "insert into docs (id, note) values ('old', 'x')", 'create virtual table chunks_fts using fts5(only_column)'], keptOldRows: survived, version, tables };
  });
  // A file that is not a database at all is not refused by the index: nothing in `openDb` catches it.
  const garbage = path.join(dir, 'garbage.sqlite');
  fs.writeFileSync(garbage, 'this is not a database file at all, and it is longer than one page header needs');
  let garbageResult: unknown;
  try {
    openDb(garbage).close();
    garbageResult = { opened: true };
  } catch (e) {
    garbageResult = { error: relativize(e instanceof Error ? e.message : String(e), dir) };
  }
  return { cases, garbage: garbageResult };
}

// ---- the life of an index --------------------------------------------------------------------

type Step =
  | { readonly op: 'write'; readonly name: string; readonly text: string; readonly mtimeSec: number }
  | { readonly op: 'delete'; readonly name: string }
  | { readonly op: 'mkdir'; readonly name: string }
  | { readonly op: 'reindex'; readonly full?: boolean };

const note = (type: string, title: string, body: string, extra = ''): string => `---\ntype: ${type}\ntitle: ${title}\n${extra}---\n${body}`;

const SCENARIOS: ReadonlyArray<{ readonly name: string; readonly steps: readonly Step[] }> = [
  {
    name: 'the life of one index',
    steps: [
      { op: 'write', name: 'alpha.md', text: note('Note', 'Alpha', '## One\nfirst words\n\n## Two\nsecond words\n', 'tags: [x, y]\nstatus: draft\n'), mtimeSec: 1000 },
      { op: 'write', name: 'beta.md', text: note('Runbook', 'Beta', 'Preamble of beta.\n\n## Диски\nпро диски и тома\n'), mtimeSec: 1000 },
      { op: 'write', name: 'broken.md', text: '---\ntitle: no type here\n---\nbody\n', mtimeSec: 1000 },
      { op: 'write', name: 'Not A Slug.md', text: note('Note', 'Slug', 'body\n'), mtimeSec: 1000 },
      { op: 'write', name: 'index.md', text: '# the index file is not a document\n', mtimeSec: 1000 },
      { op: 'mkdir', name: 'folder.md' },
      { op: 'reindex' },
      { op: 'reindex' },
      // The same text with a newer time: read, hashed, not reindexed.
      { op: 'write', name: 'alpha.md', text: note('Note', 'Alpha', '## One\nfirst words\n\n## Two\nsecond words\n', 'tags: [x, y]\nstatus: draft\n'), mtimeSec: 2000 },
      { op: 'reindex' },
      // A new text with a newer time: reindexed.
      { op: 'write', name: 'beta.md', text: note('Runbook', 'Beta', 'Preamble of beta, edited.\n\n## Диски\nпро диски и тома\n\n## Новое\nещё раздел\n'), mtimeSec: 3000 },
      { op: 'reindex' },
      // A new text with the time it had: not even read.
      { op: 'write', name: 'beta.md', text: note('Runbook', 'Beta', 'Edited again and the time kept.\n'), mtimeSec: 3000 },
      { op: 'reindex' },
      // Gone.
      { op: 'delete', name: 'alpha.md' },
      { op: 'reindex' },
      // A known document that stops parsing is dropped and counted as removed, with its error.
      { op: 'write', name: 'beta.md', text: '---\ntype: [oops\n---\nbody\n', mtimeSec: 4000 },
      { op: 'reindex' },
      { op: 'write', name: 'beta.md', text: note('Runbook', 'Beta back', 'It parses again.\n'), mtimeSec: 5000 },
      { op: 'reindex' },
      // A full reindex reads everything again.
      { op: 'reindex', full: true },
      { op: 'reindex' },
      // Several documents that share words, a legacy one and a stale one.
      { op: 'write', name: 'gamma.md', text: note('Note', 'Gamma', '## Shared\ncommon word here\n', 'stale_after: 2026-01-01T00:00:00Z\ngenerated: {by: tool, at: 2026-10-30T23:30:00-02:00}\n'), mtimeSec: 6000 },
      { op: 'write', name: 'delta.md', text: '---\nkind: runbook\nupdated: 2026-09-10\ngenerated_from: https://example.org\n---\n## Shared\ncommon word again\n', mtimeSec: 6000 },
      { op: 'reindex' },
      // The same id twice cannot happen; a file replaced by a directory of the same name leaves the index.
      { op: 'delete', name: 'gamma.md' },
      { op: 'mkdir', name: 'gamma.md' },
      { op: 'reindex' },
    ],
  },
  {
    name: 'a folder of documents that all fail',
    steps: [
      { op: 'write', name: 'one.md', text: 'no front matter\n', mtimeSec: 10 },
      { op: 'write', name: 'two.md', text: '---\ntype: \n---\n', mtimeSec: 10 },
      { op: 'write', name: 'three.md', text: '---\n- a\n---\n', mtimeSec: 10 },
      { op: 'reindex' },
      { op: 'reindex' },
    ],
  },
  {
    name: 'an empty folder',
    steps: [{ op: 'reindex' }, { op: 'reindex', full: true }],
  },
];

function dump(db: DatabaseSync, dir: string): unknown {
  const rel = (table: Table): Table => table.map((row) => Object.fromEntries(Object.entries(row).map(([k, v]) => [k, typeof v === 'string' ? relativize(v, dir) : v])));
  return plain({
    meta: rowsOf(db, 'select key, value from meta order by key'),
    docs: rel(rowsOf(db, 'select id, path, title, type, type_key, description, tags, status, stale_after, generated_at, mtime, hash from docs order by id')),
    chunks: rowsOf(db, 'select rowid, doc_id, heading, ord, body from chunks order by rowid'),
    fts: rowsOf(db, 'select rowid, doc_id, heading, body from chunks_fts order by rowid'),
  });
}

function reindexVectors(): unknown {
  return SCENARIOS.map((scenario) => {
    const dir = scratch('reindex');
    const folder = path.join(dir, 'folder');
    fs.mkdirSync(folder);
    const db = openDb(path.join(dir, 'index.sqlite'));
    const steps = scenario.steps.map((step) => {
      switch (step.op) {
        case 'write': {
          const file = path.join(folder, step.name);
          fs.writeFileSync(file, step.text);
          fs.utimesSync(file, step.mtimeSec, step.mtimeSec);
          return step;
        }
        case 'delete':
          fs.rmSync(path.join(folder, step.name), { recursive: true });
          return step;
        case 'mkdir':
          fs.mkdirSync(path.join(folder, step.name));
          return step;
        case 'reindex': {
          const stats = reindex(db, folder, step.full === true ? { full: true } : {});
          return {
            ...step,
            after: {
              added: stats.added,
              changed: stats.changed,
              unchanged: stats.unchanged,
              removed: stats.removed,
              errors: stats.errors.map((e: DocError) => ({ file: path.basename(e.file), message: relativize(e.message, dir) })),
              ...(dump(db, folder) as object),
            },
          };
        }
      }
    });
    db.close();
    return { name: scenario.name, steps };
  });
}

// ---- the modification time -------------------------------------------------------------------

/** What node's `Stats` makes of a second and a nanosecond: `sec * 1000 + nsec / 1e6` in doubles. */
const msOf = (sec: number, nsec: number): number => sec * 1000 + nsec / 1e6;

const SECONDS = [0, 1, 1_000_000_000, 1_700_000_000, 1_761_912_000, 2_147_483_647, 4_102_444_800];
const NANOS = [0, 1, 499_999, 500_000, 500_001, 999_999, 1_000_000, 1_000_001, 1_499_999, 1_500_000, 1_999_999, 2_000_000, 123_456_789, 456_000_000, 499_999_999, 500_000_000, 999_000_000, 999_499_999, 999_500_000, 999_999_000, 999_999_744, 999_999_998, 999_999_999];

/** The formula against the real thing: files set by `utimesSync` to times near a millisecond, read back as nanoseconds, must give what `statSync(file).mtimeMs` gives. */
function checkFormula(): number {
  const dir = scratch('mtime');
  const file = path.join(dir, 'f');
  fs.writeFileSync(file, '');
  const times: number[] = [];
  for (const sec of [1, 1_700_000_000, 1_761_912_000, 4_102_444_800]) {
    for (const frac of [0, 0.001, 0.0005, 0.0015, 0.000999, 0.0009999, 0.999, 0.9995, 0.9999, 0.99999, 0.123456789]) times.push(sec + frac);
  }
  for (const t of times) {
    fs.utimesSync(file, t, t);
    const big = fs.statSync(file, { bigint: true });
    const ns = big.mtimeNs;
    const sec = Number(ns / 1_000_000_000n);
    const nsec = Number(ns % 1_000_000_000n);
    const real = fs.statSync(file).mtimeMs;
    if (msOf(sec, nsec) !== real) throw new Error(`mtime formula differs from statSync for ${t}: ${msOf(sec, nsec)} against ${real}`);
  }
  return times.length;
}

function mtimeVectors(): unknown {
  const checked = checkFormula();
  const pairs = SECONDS.flatMap((sec) => NANOS.map((nsec) => ({ sec, nsec, floor: Math.floor(msOf(sec, nsec)), round: Math.round(msOf(sec, nsec)) })));
  return { formula: 'sec * 1000 + nsec / 1e6', checkedAgainstStat: checked, pairs };
}

// ---- the tokenizer ---------------------------------------------------------------------------

/** The code points the sweep covers, as inclusive ranges (the surrogates are left out of each): the Basic Multilingual Plane, the first two supplementary planes, and U+E0000 to U+E01FF, the tag characters and the first variation selectors of the plane that follows. */
const SWEPT_RANGES: ReadonlyArray<readonly [number, number]> = [[0x0, 0xffff], [0x10000, 0x2ffff], [0xe0000, 0xe01ff]];

/** The terms the index's tokenizer gives `x<c>x` for each code point `c`, read through `fts5vocab`, in blocks of 256 code points. */
function tokenizerVectors(): unknown {
  silenceSqliteWarning();
  const db = new DatabaseSync(':memory:');
  db.exec(`create virtual table t using fts5(body, tokenize='${TOKENIZER}')`);
  db.exec("create virtual table v using fts5vocab(t, 'instance')");
  const probe = (cp: number): string => `x${String.fromCodePoint(cp)}x`;
  const points: number[] = [];
  for (const [first, last] of SWEPT_RANGES) for (let cp = first; cp <= last; cp++) if (cp < 0xd800 || cp > 0xdfff) points.push(cp);
  const supplementary = [0x10000, 0x1000b, 0x10400, 0x1d400, 0x1d7ce, 0x1e900, 0x1f600, 0x20000, 0x2f800, 0xe0001, 0xe0100, 0xf0000, 0x10ffff];
  const all = [...points, ...supplementary];
  const insert = db.prepare('insert into t (rowid, body) values (?, ?)');
  db.exec('begin');
  all.forEach((cp, i) => insert.run(i + 1, probe(cp)));
  db.exec('commit');
  const termsOf = new Map<number, string[]>();
  for (const row of db.prepare('select doc, term from v order by doc, offset').all()) {
    const doc = Number(row['doc']);
    const list = termsOf.get(doc) ?? [];
    list.push(String(row['term']));
    termsOf.set(doc, list);
  }
  const line = (cp: number, i: number): string => `${cp.toString(16).toUpperCase().padStart(4, '0')} ${(termsOf.get(i + 1) ?? []).join(' ')}\n`;
  const blocks = new Map<number, string>();
  points.forEach((cp, i) => {
    const block = cp >> 8;
    blocks.set(block, (blocks.get(block) ?? '') + line(cp, i));
  });
  return {
    probe: 'x<c>x',
    line: '<code point in hex, four digits at least> <terms separated by a space>',
    ranges: SWEPT_RANGES,
    codePoints: points.length,
    blocks: [...blocks.entries()].map(([block, text]) => ({ first: block << 8, digest: createHash('sha256').update(text).digest('hex') })),
    supplementary: supplementary.map((cp, i) => ({ cp, terms: termsOf.get(points.length + i + 1) ?? [] })),
  };
}

export function engineVectors(): unknown {
  return {
    schema: schemaVectors(),
    schemaVersions: versionVectors(),
    reindex: reindexVectors(),
    mtime: mtimeVectors(),
    tokenizer: tokenizerVectors(),
  };
}
