// Shared plumbing for the suites. Not a *.test.ts file on purpose: the runner
// globs test/**/*.test.ts and must not pick this up as a suite.
//
// Every case here runs against temp directories only — HOME, CLAUDE_HOMES,
// TA_STATE_DIR and TAGENTS_CONFIG_DIR are always pointed somewhere disposable,
// because the developer's real ~/.claude has hundreds of transcripts and would
// make both the listings and the timings meaningless.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

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

export function runCli(args: string[], env: Record<string, string> = {}): RunResult {
  const r = spawnSync(NODE, [cliEntry(), ...args], { encoding: 'utf8', env: baseEnv(env), cwd: PKG });
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
  if (r.pid !== undefined) fields.push(String(r.pid));
  fs.writeFileSync(path.join(dir, `${r.key}.tsv`), `${fields.join('\t')}\n`);
}

export function writeHistory(dir: string, rows: Array<[number, string, string, string, string, string]>): void {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'history.tsv'), rows.map((r) => r.join('\t')).join('\n') + '\n');
}
