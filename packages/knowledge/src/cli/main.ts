#!/usr/bin/env node
// tagents-knowledge — the CLI face of this package.
//
// Text output is for a human at a terminal and goes through i18next-shaped
// translation; `--json` output is a contract and is never translated. Every
// read command brings the index in line with the folder first (an incremental
// reindex of a folder this size is a handful of stat() calls), so there is no
// such thing as searching yesterday's copy of a runbook.
//
// `search` and `show` also leave a line in the usage store once they have answered (usage.ts says what and why). That is best effort: a store that cannot take it never changes what was printed or the exit code, and `--verbose` is the only way to hear about it.
//
// Exit codes: 0 ok · 1 error · 2 usage · 4 nothing found.
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import type { DatabaseSync } from 'node:sqlite';
import { EXIT } from './exit.ts';
import { INDEX, LINT, LIST, SEARCH, SERVE, SHOW, TOC, USAGE } from './spec.ts';
import { openDb, reindex, silenceSqliteWarning } from '../db.ts';
import { createT, type Translate } from '../i18n/index.ts';
import { loadDir } from '../doc.ts';
import { lint } from '../lint.ts';
import { indexState, writeIndex } from '../toc.ts';
import { DEFAULT_IDLE_SECONDS, defaultSocket, ensureDaemon, runDaemon } from '../mcp/daemon.ts';
import { runMcp } from '../mcp/server.ts';
import { resolveDb, resolveDir, resolveUsageDb } from '../paths.ts';
import { realClock } from '@tagents/core';
import { getDoc, getSection, listDocs, parseAddress, search, type Clock, type Filters, type Hit } from '../search.ts';
import {
  DEFAULT_MIN_DAYS,
  DEFAULT_MIN_GETS,
  DEFAULT_SINCE_DAYS,
  DEFAULT_TOP,
  UsageStoreError,
  callerFromEnv,
  getEvent,
  hitEvents,
  parsePositive,
  parseSince,
  readUsageRows,
  recordReads,
  type UsageEvent,
  type UsageRow,
} from '../usage.ts';

export { EXIT };

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

/** Resolve the folder, open the index, refresh it, hand both to the verb, with the file the index was opened from. */
function withIndex(
  common: Common,
  io: Io,
  t: Translate,
  run: (db: DatabaseSync, dir: string, indexFile: string) => number
): number {
  const dir = needDir(common.dir, io, t);
  if (dir === null) return EXIT.error;
  const indexFile = resolveDb(common.db);
  const db = openDb(indexFile);
  try {
    // Reading is allowed to be a little stale in its reporting, never in its
    // answers: a file that stopped parsing is named on stderr and the rest of
    // the folder still answers.
    for (const e of reindex(db, dir).errors) io.err(`${path.basename(e.file)}: ${e.message}\n`);
    return run(db, dir, indexFile);
  } finally {
    db.close();
  }
}

/** Where the events of a read go, and whether a failure to record them is told. */
interface Recording {
  usageDb: string | null;
  indexFile: string;
  verbose: boolean;
}

/** Leave the events of a read that answered in the usage store; a store that cannot take them is named on stderr only for `--verbose`. */
function record(events: readonly UsageEvent[], where: Recording, io: Io, t: Translate, clock: Clock): void {
  const file = resolveUsageDb(where.usageDb, where.indexFile, process.env);
  recordReads(file, events, {
    now: clock,
    report: (reason) => {
      if (where.verbose) io.err(`${t('notRecorded', { file, reason })}\n`);
    },
  });
}

function filters(values: {
  tag?: string | undefined;
  type?: string | undefined;
  kind?: string | undefined;
}): Filters {
  return {
    ...(values.tag === undefined ? {} : { tag: values.tag }),
    ...(values.type === undefined ? {} : { type: values.type }),
    ...(values.kind === undefined ? {} : { kind: values.kind }),
  };
}

/** ` [deprecated]` and ` [stale]`: the lifecycle marks at the end of a hit or list line. */
function marks(d: { status: string; stale: boolean }): string {
  return `${d.status === 'deprecated' ? ' [deprecated]' : ''}${d.stale ? ' [stale]' : ''}`;
}

/** A hit as `--json` prints it: a contract, so the keys are listed, not spread. */
function hitJson(h: Hit): Record<string, unknown> {
  return {
    id: h.id,
    title: h.title,
    heading: h.heading,
    score: h.score,
    snippet: h.snippet,
    path: h.path,
    type: h.type,
    description: h.description,
    status: h.status,
    stale: h.stale,
  };
}

function cmdIndex(argv: string[], io: Io, t: Translate): number {
  const { values } = parseArgs({
    args: argv,
    options: INDEX.options,
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

function cmdSearch(argv: string[], io: Io, t: Translate, clock: Clock): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: SEARCH.options,
    strict: true,
    allowPositionals: true,
  });
  if (!positionals.length || !positionals.join(' ').trim()) {
    io.err(`${t('missingOption', { option: '<query…>' })}\n`);
    return EXIT.usage;
  }
  const limit = Number(values.limit);
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db, _dir, indexFile) => {
    const hits = search(db, positionals, {
      ...filters(values),
      now: clock,
      ...(Number.isFinite(limit) && limit > 0 ? { limit } : {}),
    });
    // Once per document among the results, after the answer is out as `show` does it; a search that found nothing has nothing to record.
    const hit = (): void =>
      record(
        hitEvents(hits, callerFromEnv(process.env)),
        { usageDb: values['usage-db'] ?? null, indexFile, verbose: values.verbose === true },
        io,
        t,
        clock
      );
    if (values.json === true) {
      io.out(json(hits.map(hitJson)));
      hit();
      return hits.length ? EXIT.ok : EXIT.notFound;
    }
    if (!hits.length) {
      io.err(`${t('noHits', { query: `"${positionals.join(' ')}"` })}\n`);
      return EXIT.notFound;
    }
    for (const h of hits) {
      const address = h.heading ? `${h.id}#${h.heading}` : h.id;
      io.out(`${address.padEnd(38)} ${h.score.toFixed(2).padStart(7)}  ${h.snippet}${marks(h)}\n`);
    }
    hit();
    return EXIT.ok;
  });
}

function cmdShow(argv: string[], io: Io, t: Translate, clock: Clock): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: SHOW.options,
    strict: true,
    allowPositionals: true,
  });
  const address = positionals[0];
  if (address === undefined || !address.trim()) {
    io.err(`${t('missingOption', { option: '<id[#heading]>' })}\n`);
    return EXIT.usage;
  }
  const { id, heading } = parseAddress(address);
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db, _dir, indexFile) => {
    const doc = getDoc(db, id);
    if (!doc) {
      io.err(`${t('unknownId', { id })}\n`);
      return EXIT.notFound;
    }
    // A get is recorded only for a call that returned text: the section under the heading the document writes, whatever case was asked for.
    const got = (section: string): void =>
      record(
        [getEvent(doc.id, section, callerFromEnv(process.env))],
        { usageDb: values['usage-db'] ?? null, indexFile, verbose: values.verbose === true },
        io,
        t,
        clock
      );
    if (heading === null) {
      let text: string;
      try {
        text = fs.readFileSync(doc.path, 'utf8');
      } catch {
        io.err(`${t('unknownId', { id })}\n`);
        return EXIT.notFound;
      }
      io.out(text.endsWith('\n') ? text : `${text}\n`);
      got('');
      return EXIT.ok;
    }
    const section = getSection(db, id, heading);
    if (section === null) {
      io.err(`${t('unknownHeading', { id, heading })}\n`);
      return EXIT.notFound;
    }
    io.out(section.heading ? `## ${section.heading}\n\n${section.body}\n` : `${section.body}\n`);
    got(section.heading);
    return EXIT.ok;
  });
}

function cmdList(argv: string[], io: Io, t: Translate, clock: Clock): number {
  const { values } = parseArgs({
    args: argv,
    options: LIST.options,
    strict: true,
    allowPositionals: false,
  });
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db, dir) => {
    const docs = listDocs(db, { ...filters(values), now: clock });
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
      io.out(`${d.id.padEnd(28)} ${d.type.padEnd(10)} ${d.updated}  ${d.title}${tags}${marks(d)}\n`);
    }
    return EXIT.ok;
  });
}

function cmdLint(argv: string[], io: Io, t: Translate, clock: Clock): number {
  const { values } = parseArgs({
    args: argv,
    options: LINT.options,
    strict: true,
    allowPositionals: false,
  });
  const dir = needDir(values.dir ?? null, io, t);
  if (dir === null) return EXIT.error;
  const result = lint(dir, t, process.env, clock);
  for (const issue of result.issues) io.out(`${path.basename(issue.file)}: ${issue.message}\n`);
  if (!result.issues.length) {
    io.out(`${t('lintClean', { count: result.checked, dir })}\n`);
    return EXIT.ok;
  }
  io.out(`${t('lintProblems', { count: result.issues.length, dir })}\n`);
  return EXIT.error;
}

function cmdToc(argv: string[], io: Io, t: Translate): number {
  const { values } = parseArgs({
    args: argv,
    options: TOC.options,
    strict: true,
    allowPositionals: false,
  });
  const dir = needDir(values.dir ?? null, io, t);
  if (dir === null) return EXIT.error;
  const { docs, errors } = loadDir(dir);
  if (values.check === true) {
    if (indexState(dir, docs) === 'current') return EXIT.ok;
    io.err(`${t('tocOutOfDate')}\n`);
    return EXIT.error;
  }
  for (const e of errors) io.err(`${path.basename(e.file)}: ${e.message}\n`);
  io.out(`${t('tocWrote', { path: writeIndex(dir, docs) })}\n`);
  return EXIT.ok;
}

/** A count flag: its value, the default when it is absent, null (after saying which flag) when it is not a positive whole number. */
function countFlag(flag: 'top' | 'min-gets' | 'min-days', value: string | undefined, fallback: number, io: Io, t: Translate): number | null {
  if (value === undefined) return fallback;
  const n = parsePositive(value);
  if (n === null) io.err(`${t('badCount', { flag })}\n`);
  return n;
}

/** The report as text: the header, then a line per row, the columns at least two spaces apart and the counts flush right. */
function usageTable(rows: readonly UsageRow[], t: Translate): string[] {
  const header = t('usageColumns').split(' ');
  const body = rows.map((r) => [r.id, r.type ?? '-', r.status ?? '-', String(r.gets), String(r.hits), String(r.days), r.last ?? '-']);
  const table = [header, ...body];
  const widths = header.map((_, i) => Math.max(...table.map((row) => (row[i] ?? '').length)));
  return table.map((row) =>
    row
      .map((cell, i) => (i >= 3 && i <= 5 ? cell.padStart(widths[i] ?? 0) : cell.padEnd(widths[i] ?? 0)))
      .join('  ')
      .trimEnd()
  );
}

function cmdUsage(argv: string[], io: Io, t: Translate, clock: Clock): number {
  const { values } = parseArgs({
    args: argv,
    options: USAGE.options,
    strict: true,
    allowPositionals: false,
  });
  const sinceDays = values.since === undefined ? DEFAULT_SINCE_DAYS : parseSince(values.since);
  if (sinceDays === null) io.err(`${t('badSince')}\n`);
  const top = countFlag('top', values.top, DEFAULT_TOP, io, t);
  const minGets = countFlag('min-gets', values['min-gets'], DEFAULT_MIN_GETS, io, t);
  const minDays = countFlag('min-days', values['min-days'], DEFAULT_MIN_DAYS, io, t);
  if (sinceDays === null || top === null || minGets === null || minDays === null) return EXIT.usage;
  return withIndex({ dir: values.dir ?? null, db: values.db ?? null }, io, t, (db, _dir, indexFile) => {
    const file = resolveUsageDb(values['usage-db'] ?? null, indexFile, process.env);
    let rows: UsageRow[];
    try {
      rows = readUsageRows(db, file, {
        sinceDays,
        top,
        minGets,
        minDays,
        all: values.all === true,
        candidates: values.candidates === true,
        now: clock,
        ...(values.type === undefined ? {} : { type: values.type }),
      });
    } catch (e) {
      if (!(e instanceof UsageStoreError)) throw e;
      io.err(`${t('usageUnreadable', { file: e.file, reason: e.reason })}\n`);
      return EXIT.error;
    }
    if (values.json === true) {
      io.out(json(rows));
      return rows.length ? EXIT.ok : EXIT.notFound;
    }
    if (!rows.length) {
      io.err(`${t('noUsageRows')}\n`);
      return EXIT.notFound;
    }
    for (const line of usageTable(rows, t)) io.out(`${line}\n`);
    return EXIT.ok;
  });
}

/**
 * `serve` prints the socket of the shared server for this environment, starting the server first when none answers. `--foreground` is the server itself, which `serve` starts detached.
 */
async function cmdServe(argv: string[], io: Io, t: Translate): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: SERVE.options,
    strict: true,
    allowPositionals: false,
  });
  const idle = values.idle === undefined ? DEFAULT_IDLE_SECONDS : Number(values.idle);
  if (!Number.isFinite(idle) || idle <= 0) {
    io.err(`${t('badIdle')}\n`);
    return EXIT.usage;
  }
  try {
    if (values.foreground === true) {
      await runDaemon({ socket: values.socket ?? defaultSocket(), idleMs: idle * 1000 });
      return EXIT.ok;
    }
    io.out(`${await ensureDaemon(process.env, idle)}\n`);
    return EXIT.ok;
  } catch (e) {
    io.err(`${t('serveFailed', { reason: e instanceof Error ? e.message : String(e) })}\n`);
    return EXIT.error;
  }
}

export async function main(argv: string[], io: Io = stdio(), clock: Clock = realClock): Promise<number> {
  // Before anything runs: importing node:sqlite queues Node's experimental
  // notice, and a verb that never opens the index (lint, help) would otherwise
  // print it on the next tick, into stderr a human is reading.
  silenceSqliteWarning();
  const t = createT();
  const [verb, ...rest] = argv;
  try {
    if (verb === 'index') return cmdIndex(rest, io, t);
    if (verb === 'search') return cmdSearch(rest, io, t, clock);
    if (verb === 'show') return cmdShow(rest, io, t, clock);
    if (verb === 'list') return cmdList(rest, io, t, clock);
    if (verb === 'lint') return cmdLint(rest, io, t, clock);
    if (verb === 'toc') return cmdToc(rest, io, t);
    if (verb === 'usage') return cmdUsage(rest, io, t, clock);
    if (verb === 'serve') return await cmdServe(rest, io, t);
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
