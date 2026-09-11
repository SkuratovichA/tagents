#!/usr/bin/env node
// tagents-knowledge — the CLI face of this package.
//
// Text output is for a human at a terminal and goes through i18next-shaped
// translation; `--json` output is a contract and is never translated. Every
// read command brings the index in line with the folder first (an incremental
// reindex of a folder this size is a handful of stat() calls), so there is no
// such thing as searching yesterday's copy of a runbook.
//
// Exit codes: 0 ok · 1 error · 2 usage · 4 nothing found.
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import type { DatabaseSync } from 'node:sqlite';
import { openDb, reindex, silenceSqliteWarning } from '../db.ts';
import { createT, type Translate } from '../i18n/index.ts';
import { lint } from '../lint.ts';
import { runMcp } from '../mcp/server.ts';
import { resolveDb, resolveDir } from '../paths.ts';
import { getDoc, getSection, listDocs, parseAddress, search, type Filters } from '../search.ts';

export const EXIT = { ok: 0, error: 1, usage: 2, notFound: 4 } as const;

export interface Io {
  out: (s: string) => void;
  err: (s: string) => void;
}

const json = (value: unknown): string => `${JSON.stringify(value, null, 2)}\n`;

interface Common {
  dir: string | null;
  db: string | null;
}

/** The folder, or the sentence that says why there is none. */
function needDir(explicit: string | null, io: Io, t: Translate): string | null {
  const dir = resolveDir(explicit);
  if (dir.ok) return dir.dir;
  io.err(
    `${dir.reason === 'unset' ? t('noDir', { config: dir.config }) : t('missingDir', { dir: dir.dir ?? '' })}\n`
  );
  return null;
}

/** Resolve the folder, open the index, refresh it, hand both to the verb. */
function withIndex(
  common: Common,
  io: Io,
  t: Translate,
  run: (db: DatabaseSync, dir: string) => number
): number {
  const dir = needDir(common.dir, io, t);
  if (dir === null) return EXIT.error;
  const db = openDb(resolveDb(common.db));
  try {
    // Reading is allowed to be a little stale in its reporting, never in its
    // answers: a file that stopped parsing is named on stderr and the rest of
    // the folder still answers.
    for (const e of reindex(db, dir).errors) io.err(`${path.basename(e.file)}: ${e.message}\n`);
    return run(db, dir);
  } finally {
    db.close();
  }
}

function filters(values: { tag?: string | undefined; kind?: string | undefined }): Filters {
  return {
    ...(values.tag === undefined ? {} : { tag: values.tag }),
    ...(values.kind === undefined ? {} : { kind: values.kind }),
  };
}

function cmdIndex(argv: string[], io: Io, t: Translate): number {
  const { values } = parseArgs({
    args: argv,
    options: { dir: { type: 'string' }, db: { type: 'string' }, full: { type: 'boolean' } },
    strict: true,
    allowPositionals: false,
  });
  const dir = needDir(values.dir ?? null, io, t);
  if (dir === null) return EXIT.error;
  const file = resolveDb(values.db ?? null);
  const db = openDb(file);
  try {
    const stats = reindex(db, dir, values.full === true ? { full: true } : {});
    io.out(
      `${t('indexed', {
        db: file,
        added: stats.added,
        changed: stats.changed,
        unchanged: stats.unchanged,
        removed: stats.removed,
      })}\n`
    );
    for (const e of stats.errors) io.err(`${path.basename(e.file)}: ${e.message}\n`);
    if (stats.errors.length) {
      io.err(`${t('indexErrors', { count: stats.errors.length })}\n`);
      return EXIT.error;
    }
    return EXIT.ok;
  } finally {
    db.close();
  }
}

function cmdSearch(argv: string[], io: Io, t: Translate): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      dir: { type: 'string' },
      db: { type: 'string' },
      tag: { type: 'string' },
      kind: { type: 'string' },
      limit: { type: 'string' },
      json: { type: 'boolean' },
    },
    strict: true,
    allowPositionals: true,
  });
  if (!positionals.length || !positionals.join(' ').trim()) {
    io.err(`${t('missingOption', { option: '<query…>' })}\n`);
    return EXIT.usage;
  }
  const limit = Number(values.limit);
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db) => {
    const hits = search(db, positionals, {
      ...filters(values),
      ...(Number.isFinite(limit) && limit > 0 ? { limit } : {}),
    });
    if (values.json === true) {
      io.out(json(hits.map((h) => ({ id: h.id, title: h.title, heading: h.heading, score: h.score, snippet: h.snippet, path: h.path }))));
      return hits.length ? EXIT.ok : EXIT.notFound;
    }
    if (!hits.length) {
      io.err(`${t('noHits', { query: `"${positionals.join(' ')}"` })}\n`);
      return EXIT.notFound;
    }
    for (const h of hits) {
      const address = h.heading ? `${h.id}#${h.heading}` : h.id;
      io.out(`${address.padEnd(38)} ${h.score.toFixed(2).padStart(7)}  ${h.snippet}\n`);
    }
    return EXIT.ok;
  });
}

function cmdShow(argv: string[], io: Io, t: Translate): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { dir: { type: 'string' }, db: { type: 'string' } },
    strict: true,
    allowPositionals: true,
  });
  const address = positionals[0];
  if (address === undefined || !address.trim()) {
    io.err(`${t('missingOption', { option: '<id[#heading]>' })}\n`);
    return EXIT.usage;
  }
  const { id, heading } = parseAddress(address);
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db) => {
    const doc = getDoc(db, id);
    if (!doc) {
      io.err(`${t('unknownId', { id })}\n`);
      return EXIT.notFound;
    }
    if (heading === null) {
      let text: string;
      try {
        text = fs.readFileSync(doc.path, 'utf8');
      } catch {
        io.err(`${t('unknownId', { id })}\n`);
        return EXIT.notFound;
      }
      io.out(text.endsWith('\n') ? text : `${text}\n`);
      return EXIT.ok;
    }
    const section = getSection(db, id, heading);
    if (section === null) {
      io.err(`${t('unknownHeading', { id, heading })}\n`);
      return EXIT.notFound;
    }
    io.out(section.heading ? `## ${section.heading}\n\n${section.body}\n` : `${section.body}\n`);
    return EXIT.ok;
  });
}

function cmdList(argv: string[], io: Io, t: Translate): number {
  const { values } = parseArgs({
    args: argv,
    options: {
      dir: { type: 'string' },
      db: { type: 'string' },
      kind: { type: 'string' },
      tag: { type: 'string' },
      json: { type: 'boolean' },
    },
    strict: true,
    allowPositionals: false,
  });
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db, dir) => {
    const docs = listDocs(db, filters(values));
    if (values.json === true) {
      io.out(json(docs));
      return docs.length ? EXIT.ok : EXIT.notFound;
    }
    if (!docs.length) {
      io.err(`${t('noDocs', { dir })}\n`);
      return EXIT.notFound;
    }
    for (const d of docs) {
      const tags = d.tags.length ? `  #${d.tags.join(' #')}` : '';
      io.out(`${d.id.padEnd(28)} ${d.kind.padEnd(10)} ${d.updated}  ${d.title}${tags}\n`);
    }
    return EXIT.ok;
  });
}

function cmdLint(argv: string[], io: Io, t: Translate): number {
  const { values } = parseArgs({
    args: argv,
    options: { dir: { type: 'string' } },
    strict: true,
    allowPositionals: false,
  });
  const dir = needDir(values.dir ?? null, io, t);
  if (dir === null) return EXIT.error;
  const result = lint(dir, t);
  for (const issue of result.issues) io.out(`${path.basename(issue.file)}: ${issue.message}\n`);
  if (!result.issues.length) {
    io.out(`${t('lintClean', { count: result.checked, dir })}\n`);
    return EXIT.ok;
  }
  io.out(`${t('lintProblems', { count: result.issues.length, dir })}\n`);
  return EXIT.error;
}

export async function main(argv: string[], io: Io = stdio()): Promise<number> {
  // Before anything runs: importing node:sqlite queues Node's experimental
  // notice, and a verb that never opens the index (lint, help) would otherwise
  // print it on the next tick, into stderr a human is reading.
  silenceSqliteWarning();
  const t = createT();
  const [verb, ...rest] = argv;
  try {
    if (verb === 'index') return cmdIndex(rest, io, t);
    if (verb === 'search') return cmdSearch(rest, io, t);
    if (verb === 'show') return cmdShow(rest, io, t);
    if (verb === 'list') return cmdList(rest, io, t);
    if (verb === 'lint') return cmdLint(rest, io, t);
    if (verb === 'mcp') {
      await runMcp();
      return EXIT.ok;
    }
    if (verb === undefined || verb === 'help' || verb === '--help' || verb === '-h') {
      io.out(`${t('usage')}\n`);
      return verb === undefined ? EXIT.usage : EXIT.ok;
    }
    io.err(`${t('unknownCommand', { command: verb })}\n${t('usage')}\n`);
    return EXIT.usage;
  } catch (e) {
    // parseArgs throws for an unknown flag: that is a usage error, not a crash.
    const err = e as NodeJS.ErrnoException;
    const usage = typeof err.code === 'string' && err.code.startsWith('ERR_PARSE_ARGS');
    io.err(`${err.message}\n`);
    return usage ? EXIT.usage : EXIT.error;
  }
}

/** `tagents-knowledge search x | head` closes the pipe mid-write; that is fine. */
function stdio(): Io {
  const ignore = (): void => undefined;
  process.stdout.on('error', ignore);
  process.stderr.on('error', ignore);
  const write = (stream: NodeJS.WriteStream, text: string): void => {
    try {
      stream.write(text);
    } catch {
      // The reader is gone; there is nobody left to tell.
    }
  };
  return {
    out: (s) => write(process.stdout, s),
    err: (s) => write(process.stderr, s),
  };
}

// Run only as a program, never on import: a test imports main() directly.
const invokedAs = process.argv[1] ? pathToFileURL(fs.realpathSync(process.argv[1])).href : '';
if (invokedAs === import.meta.url) {
  process.exitCode = await main(process.argv.slice(2));
}
