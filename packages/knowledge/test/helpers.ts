// Shared plumbing for the suites. Not a *.test.ts file on purpose: the runner
// globs test/**/*.test.ts and must not pick this up as a suite.
//
// Every case runs against a temp directory and a temp index — never the
// developer's own knowledge folder, never ~/.config/tagents — because this
// package's whole job is reading somebody's real notes and a suite that could
// see them would be both flaky and a leak.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { z } from 'zod';
import { int, silenceSqliteWarning, text } from '../src/db.ts';

// Importing node:sqlite, here or in a module under test, queues Node's experimental notice for the next tick. Drop it before that tick, as the CLI does before anything runs, so that no suite puts it into the runner's output because its first test did not happen to open a database.
silenceSqliteWarning();

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PKG = path.resolve(HERE, '..');
export const FIXTURES = path.join(HERE, 'fixtures');
export const KNOWLEDGE = path.join(FIXTURES, 'knowledge');
/** The same kind of folder in the OKF form, with the reserved index.md and log.md in it. */
export const OKF = path.join(FIXTURES, 'okf');
export const NODE = process.execPath;

/**
 * The CLI under test: the BUILT bin when there is one (that is what a consumer
 * installs, and what an MCP client spawns), the source otherwise, so the suite
 * still runs before a build.
 */
export function cliEntry(): string {
  const built = path.join(PKG, 'dist', 'cli', 'main.js');
  return fs.existsSync(built) ? built : path.join(PKG, 'src', 'cli', 'main.ts');
}

/** A disposable directory that the test removes when it is done. */
export function tmpDir(name: string): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), `tagents-knowledge-${name}-`));
}

export function removeDir(dir: string): void {
  fs.rmSync(dir, { recursive: true, force: true });
}

/** A copy of the fixture folder, so a test may edit or delete documents in it. */
export function copyKnowledge(dest: string): string {
  return copyFolder(KNOWLEDGE, dest);
}

export function copyOkf(dest: string): string {
  return copyFolder(OKF, dest);
}

function copyFolder(src: string, dest: string): string {
  fs.mkdirSync(dest, { recursive: true });
  for (const name of fs.readdirSync(src)) fs.copyFileSync(path.join(src, name), path.join(dest, name));
  return dest;
}

export function writeDoc(dir: string, name: string, text: string): string {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  fs.writeFileSync(file, text);
  return file;
}

/** Frontmatter + body, with the fields a case does not care about filled in. */
export function doc(
  fields: Partial<Record<'id' | 'title' | 'kind' | 'tags' | 'updated' | 'extra', string>>,
  body = 'Body text.\n'
): string {
  const lines = [
    `id: ${fields.id ?? 'sample'}`,
    `title: ${fields.title ?? 'Sample'}`,
    `kind: ${fields.kind ?? 'note'}`,
    `tags: ${fields.tags ?? '[sample]'}`,
    `updated: ${fields.updated ?? '2026-09-11'}`,
  ];
  if (fields.extra !== undefined) lines.push(fields.extra);
  return `---\n${lines.join('\n')}\n---\n\n${body}`;
}

/** A document in the OKF form: `type` and whatever extra frontmatter lines a case needs. */
export function okfDoc(type: string, extra: readonly string[] = [], body = 'Body text.\n'): string {
  return `---\n${[`type: ${type}`, ...extra].join('\n')}\n---\n\n${body}`;
}

export interface RunResult {
  code: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
}

/** A deliberately small env: nothing of the developer's shell decides anything. */
export function baseEnv(extra: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: `${path.dirname(NODE)}:/usr/bin:/bin:/usr/sbin:/sbin`,
    LANG: 'en_US.UTF-8',
    LC_ALL: 'en_US.UTF-8',
    TZ: 'UTC',
    // Nothing here may fall back to the real config or the real index.
    TAGENTS_CONFIG_DIR: path.join(os.tmpdir(), 'tagents-knowledge-nowhere'),
    ...extra,
  };
}

export function runCli(args: string[], env: Record<string, string> = {}): RunResult {
  const r = spawnSync(NODE, [cliEntry(), ...args], { encoding: 'utf8', env: baseEnv(env), cwd: PKG });
  if (r.error) throw r.error;
  return { code: r.status, signal: r.signal, stdout: r.stdout, stderr: r.stderr };
}

/**
 * A repository with one commit at a FIXED date, for the checks that compare a
 * document's `updated:` against git. The date is pinned because "today" would
 * make the fixtures stale the day after they were written.
 */
export function gitInit(dir: string, when = '2026-09-07T12:00:00Z'): void {
  const env = baseEnv({ GIT_AUTHOR_DATE: when, GIT_COMMITTER_DATE: when });
  const run = (...args: string[]): void => {
    const r = spawnSync('git', ['-C', dir, ...args], { encoding: 'utf8', env });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  };
  run('-c', 'init.defaultBranch=main', 'init', '-q');
  run('config', 'user.email', 'suite@example.invalid');
  run('config', 'user.name', 'suite');
  run('add', '-A');
  run(
    '-c',
    'user.email=suite@example.invalid',
    '-c',
    'user.name=suite',
    'commit',
    '-q',
    '-m',
    'fixture'
  );
}

export interface StoredEvent {
  readonly ts: number;
  readonly docId: string;
  readonly heading: string;
  readonly kind: string;
  readonly caller: string | null;
}

/** The events of a usage store that is already open, oldest first. */
export function readEvents(db: DatabaseSync): StoredEvent[] {
  return db
    .prepare('select ts, doc_id, heading, kind, caller from usage_events order by ts, rowid')
    .all()
    .map((row) => ({
      ts: int(row, 'ts'),
      docId: text(row, 'doc_id'),
      heading: text(row, 'heading'),
      kind: text(row, 'kind'),
      caller: row['caller'] === null ? null : text(row, 'caller'),
    }));
}

/** What a usage store file holds, read the way anybody with sqlite3 would. Throws when the file is not there. */
export function eventsIn(file: string): StoredEvent[] {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    return readEvents(db);
  } finally {
    db.close();
  }
}

/** The events a usage store holds, none when there is no store yet. */
export function recordedEvents(file: string): StoredEvent[] {
  return fs.existsSync(file) ? eventsIn(file) : [];
}

/** The same, a line for each: `get deploy-runbook#Rollback by reader`. */
export function recordedLines(file: string): string[] {
  return recordedEvents(file).map((e) => `${e.kind} ${e.docId}#${e.heading} by ${e.caller}`);
}

// `JSON.parse` hands back `any`. A schema is what turns a parsed answer into a type, and fails the case when the answer is not that shape.

/** A `--json` answer that a case reads only for the ids in it. */
export const IdRows = z.array(z.object({ id: z.string() }));

/** The rows of `usage --json` and of the `knowledge_usage` tool: these keys and no others. */
export const UsageRows = z.array(
  z
    .object({
      id: z.string(),
      type: z.string().nullable(),
      status: z.string().nullable(),
      gets: z.number(),
      hits: z.number(),
      days: z.number(),
      last: z.string().nullable(),
    })
    .strict()
);
