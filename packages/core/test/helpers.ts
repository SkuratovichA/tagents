// Shared plumbing for the suites. Not a *.test.ts file on purpose: the runner
// globs test/**/*.test.ts and must not pick this up as a suite.
//
// Every case here runs against temp directories only — HOME, CLAUDE_HOMES,
// TA_STATE_DIR and TAGENTS_CONFIG_DIR are always pointed somewhere disposable,
// because the developer's real ~/.claude has hundreds of transcripts and would
// make both the listings and the timings meaningless.
import assert from 'node:assert/strict';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { StreamEvent } from '../src/driver.ts';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PKG = path.resolve(HERE, '..');
export const FIXTURES = path.join(HERE, 'fixtures');
export const NODE = process.execPath;

/**
 * The CLI under test: the BUILT bin when there is one (that is what a consumer
 * installs), the source otherwise, so the suite still runs before a build.
 */
export function cliEntry(): string {
  const built = path.join(PKG, 'dist', 'cli', 'main.js');
  return fs.existsSync(built) ? built : path.join(PKG, 'src', 'cli', 'main.ts');
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
    ...extra,
  };
}

/** `cwd` matters to the verbs that resolve a path or a package from where the caller stands. */
export function runCli(args: string[], env: Record<string, string> = {}, cwd: string = PKG): RunResult {
  const r = spawnSync(NODE, [cliEntry(), ...args], { encoding: 'utf8', env: baseEnv(env), cwd });
  if (r.error) throw r.error;
  return { code: r.status, signal: r.signal, stdout: r.stdout, stderr: r.stderr };
}

export function expectFixture(rel: string, actual: string): void {
  const file = path.join(FIXTURES, rel);
  if (process.env['UPDATE_FIXTURES'] === '1') {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, actual);
    return;
  }
  assert.ok(fs.existsSync(file), `missing fixture ${rel}`);
  assert.equal(actual, fs.readFileSync(file, 'utf8'), `fixture mismatch: ${rel}`);
}

/** Exactly one pretty-printed JSON document on stdout, nothing else. */
export function parseSingleJson(stdout: string): unknown {
  assert.ok(stdout.endsWith('\n'), 'stdout must end with a newline');
  const body = stdout.slice(0, -1);
  assert.ok(body.startsWith('{') || body.startsWith('['), 'stdout must be one JSON document');
  const value: unknown = JSON.parse(body);
  assert.equal(JSON.stringify(value, null, 2), body, 'stdout must be pretty-printed JSON, nothing else');
  return value;
}

// --------------------------------------------------------------- transcripts ---

/**
 * A synthetic transcript. The padding must clear the 2000-byte floor
 * (transcripts.ts skips anything smaller) and must contain neither `"user"` nor
 * `"assistant"`, or it would be read as a turn.
 */
export function transcript({ prompt, reply }: { prompt: string; reply: string }): string {
  const pad = JSON.stringify({ type: 'system', subtype: 'pad', note: 'x'.repeat(2400) });
  return [
    JSON.stringify({ type: 'user', isMeta: true, message: { content: '<command-name>/init</command-name>' } }),
    JSON.stringify({ type: 'user', message: { content: prompt } }),
    pad,
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'first pass, superseded' }] } }),
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: reply }] } }),
    '',
  ].join('\n');
}

/** Project dir names are the absolute cwd with '/' → '-'. */
export function writeSession(
  claudeHome: string,
  { slug, id, prompt, reply, mtime }: { slug: string; id: string; prompt: string; reply: string; mtime: string }
): string {
  const dir = path.join(claudeHome, 'projects', slug);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${id}.jsonl`);
  fs.writeFileSync(file, transcript({ prompt, reply }));
  assert.ok(fs.statSync(file).size > 2000, 'transcript must clear the 2000-byte floor');
  const at = new Date(mtime);
  fs.utimesSync(file, at, at);
  return file;
}

/** The two sessions every parity fixture was recorded from. */
export function seedSessions(claudeHome: string): void {
  writeSession(claudeHome, {
    slug: '-Users-demo-git-demo',
    id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    prompt: 'Fix the deploy script for the staging cluster',
    reply: 'Deploy script fixed and staging is green.',
    mtime: '2026-01-02T03:04:05.000Z',
  });
  writeSession(claudeHome, {
    slug: '-Users-demo-git-other-repo',
    id: 'ffffffff-1111-2222-3333-444444444444',
    prompt: 'Собери сводку по топикам за неделю',
    reply: 'Сводка готова, отправил в «dev».',
    mtime: '2026-02-03T04:05:06.000Z',
  });
}

// -------------------------------------------------------------- agent state ---

export interface StateRowInput {
  key: string;
  at?: number;
  state?: string;
  sessionId?: string;
  cwd?: string;
  transcript?: string;
  detail?: string;
  configDir?: string | null;
  pid?: number;
  logFile?: string;
  label?: string;
  parentKey?: string;
  parentSid?: string;
}

/** Write one record the way hooks/tmux-agent-state.sh writes it. */
export function writeStateRow(dir: string, r: StateRowInput): void {
  fs.mkdirSync(dir, { recursive: true });
  const fields = [
    String(r.at ?? Math.floor(Date.now() / 1000)),
    r.state ?? 'working',
    r.sessionId ?? '',
    r.cwd ?? '/tmp',
    r.transcript ?? '',
    r.detail ?? '',
  ];
  // configDir === null reproduces a pre-account record: SIX fields, not seven.
  if (r.configDir !== null) fields.push(r.configDir ?? '');
  // The tail is positional, so a field is only written once something after it
  // has to be: asking for a parentKey alone still produces a well-formed
  // twelve-column record, and asking for none of it leaves the seven the hook
  // writes for a session with a pane.
  const tail: Array<string | undefined> = [
    r.pid === undefined ? undefined : String(r.pid),
    r.logFile,
    r.label,
    r.parentKey,
    r.parentSid,
  ];
  let last = -1;
  for (let i = 0; i < tail.length; i += 1) if (tail[i] !== undefined) last = i;
  for (let i = 0; i <= last; i += 1) fields.push(tail[i] ?? '');
  fs.writeFileSync(path.join(dir, `${r.key}.tsv`), `${fields.join('\t')}\n`);
}

/** A real process to stand behind a state row's pid: the caller stops it, and waits for `exit` to learn how it ended. */
export function startSleeper(): ChildProcess & { readonly pid: number } {
  const child = spawn('sleep', ['60'], { stdio: 'ignore' });
  assert.ok(child.pid !== undefined, 'sleep did not start');
  return Object.assign(child, { pid: child.pid });
}

export function writeHistory(
  dir: string,
  rows: Array<[number, string, string, string, string, string] | [number, string, string, string, string, string, string]>
): void {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'history.tsv'), rows.map((r) => r.join('\t')).join('\n') + '\n');
}

// ------------------------------------------------------------------- timing ---

// The fake clock lives in the testkit, where a plugin's tests can reach it too.
export { FakeClock } from '../src/testkit.ts';

/**
 * The onEvent sink a fake-clock turn is steered by. The child is a real
 * process, so a test cannot know when it has spoken — it waits for the event
 * (`await seen('text')`) and only then moves the clock, which is what makes a
 * timeout test a statement about order instead of a race against a real timer.
 */
export interface EventWaiter {
  readonly onEvent: (e: StreamEvent) => void;
  /** Resolves on the first event of that kind. */
  readonly seen: (kind: StreamEvent['kind']) => Promise<void>;
}

export function eventWaiter(): EventWaiter {
  const waiting = new Map<string, () => void>();
  const arrived = new Set<string>();
  return {
    onEvent: (e) => {
      arrived.add(e.kind);
      waiting.get(e.kind)?.();
    },
    seen: (kind) => (arrived.has(kind) ? Promise.resolve() : new Promise((resolve) => waiting.set(kind, resolve))),
  };
}
