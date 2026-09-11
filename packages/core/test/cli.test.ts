// The CLI's outside edge, spawned as a real program (the BUILT bin when there
// is one — that is what a consumer installs).
//
// Two contracts are under test. The JSON verbs must put exactly ONE
// pretty-printed document on stdout and nothing else: no banner, no progress,
// no second document — a caller pipes this into jq. The text verbs must print
// what sessions.mjs printed, byte for byte, against the fixtures copied from
// the orchestrator.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fakeClaude, tmpDir } from '../src/testkit.ts';
import { spawnSync } from 'node:child_process';
import { baseEnv, cliEntry, expectFixture, NODE, parseSingleJson, runCli, seedSessions, writeStateRow } from './helpers.ts';

let tmp: string;
let claudeHome: string;
let state: string;
let config: string;
let fakeBin: string;

const withHome = (extra: Record<string, string> = {}): Record<string, string> => ({
  HOME: tmp,
  CLAUDE_HOMES: claudeHome,
  TA_STATE_DIR: state,
  TAGENTS_CONFIG_DIR: config,
  ...extra,
});

before(() => {
  tmp = tmpDir('cli-test');
  claudeHome = path.join(tmp, '.claude');
  state = path.join(tmp, 'agent-state');
  config = path.join(tmp, 'config');
  fs.mkdirSync(config, { recursive: true });
  seedSessions(claudeHome);
  writeStateRow(state, {
    key: '7',
    at: 1_760_000_000,
    state: 'working',
    sessionId: 'sess-live',
    cwd: '/Users/demo/git/demo',
    detail: 'Bash ls',
    configDir: '',
  });
  fakeBin = fakeClaude({ tools: ['Bash'], text: 'hi', result: { text: 'done' } }, fs.mkdtempSync(path.join(tmp, 'fake-'))).bin;
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// ------------------------------------------------------------------- text ---

test('sessions recent/search/show print what sessions.mjs printed', () => {
  const recent = runCli(['sessions', 'recent'], withHome());
  assert.equal(recent.code, 0);
  assert.equal(recent.stderr, '');
  expectFixture('sessions/recent.txt', recent.stdout);
  assert.equal(runCli(['sessions'], withHome()).stdout, recent.stdout, 'no subcommand behaves like recent');
  expectFixture('sessions/recent-1.txt', runCli(['sessions', 'recent', '1'], withHome()).stdout);
  expectFixture('sessions/search-deploy.txt', runCli(['sessions', 'search', 'deploy'], withHome()).stdout);
  expectFixture('sessions/search-miss.txt', runCli(['sessions', 'search', 'zzzznothing'], withHome()).stdout);
  expectFixture('sessions/show.txt', runCli(['sessions', 'show', 'aaaaaaaa'], withHome()).stdout);
});

test('sessions: the usage and not-found lines keep their exit codes', () => {
  const noWords = runCli(['sessions', 'search'], withHome());
  assert.equal(noWords.code, 1);
  assert.equal(noWords.stdout, '');
  assert.equal(noWords.stderr, 'usage: sessions.mjs search <words…>\n');

  const noPrefix = runCli(['sessions', 'show'], withHome());
  assert.equal(noPrefix.code, 1);
  assert.equal(noPrefix.stderr, 'usage: sessions.mjs show <id-prefix>\n');

  const unknown = runCli(['sessions', 'show', 'nope'], withHome());
  assert.equal(unknown.code, 1);
  assert.equal(unknown.stdout, '');
  assert.equal(unknown.stderr, 'no session starts with "nope"\n');

  const bogus = runCli(['sessions', 'bogus'], withHome());
  assert.equal(bogus.code, 0);
  assert.equal(bogus.stdout, 'usage: sessions.mjs [recent [N] | search <words…> | show <id-prefix>]\n');
});

// ------------------------------------------------------------------- json ---

test('session open prints exactly one JSON document', () => {
  const r = runCli(['session', 'open', '--cwd', tmp, '--label', 'smoke', '--model', 'fable'], withHome());
  assert.equal(r.code, 0);
  assert.equal(r.stderr, '');
  const ref = parseSingleJson(r.stdout) as { id: string; claudeSessionId: string | null; spec: { label: string } };
  assert.equal(typeof ref.id, 'string');
  assert.equal(ref.claudeSessionId, null);
  assert.equal(ref.spec.label, 'smoke');
});

test('session open refuses to guess: no --cwd is a usage error', () => {
  const r = runCli(['session', 'open'], withHome());
  assert.equal(r.code, 2);
  assert.equal(r.stdout, '');
  const both = runCli(['session', 'open', '--cwd', tmp, '--config-dir', '/x', '--no-config-dir'], withHome());
  assert.equal(both.code, 2);
  const unknownFlag = runCli(['session', 'open', '--cwd', tmp, '--invented'], withHome());
  assert.equal(unknownFlag.code, 2);
});

test('--no-config-dir is not the same as leaving it out', () => {
  const unset = parseSingleJson(runCli(['session', 'open', '--cwd', tmp, '--no-config-dir'], withHome()).stdout);
  assert.equal((unset as { spec: { configDir: null } }).spec.configDir, null);
  const inherit = parseSingleJson(runCli(['session', 'open', '--cwd', tmp], withHome()).stdout);
  assert.equal('configDir' in (inherit as { spec: Record<string, unknown> }).spec, false);
});

test('a turn through the CLI: one document, exit 0', () => {
  const ref = openWithFake();
  const r = runCli(['session', 'prompt', JSON.stringify(ref), 'do the thing'], withHome());
  assert.equal(r.code, 0);
  const outcome = parseSingleJson(r.stdout) as { kind: string; toolUses: number; text: string };
  assert.equal(outcome.kind, 'ok');
  assert.equal(outcome.toolUses, 1);
  assert.equal(outcome.text, 'hi');
});

test('--events streams NDJSON and makes the outcome the last line', () => {
  const ref = openWithFake();
  const r = runCli(['session', 'prompt', JSON.stringify(ref), 'go', '--events'], withHome());
  assert.equal(r.code, 0);
  const lines = r.stdout.trimEnd().split('\n');
  const parsed = lines.map((l) => JSON.parse(l) as { kind: string });
  assert.deepEqual(parsed.slice(0, -1).map((e) => e.kind), ['other', 'tool_use', 'text', 'result']);
  assert.equal(parsed.at(-1)?.kind, 'ok');
  for (const l of lines) assert.ok(!l.includes('\n  '), 'streamed events are compact, one per line');
});

test('a timed-out turn exits 4 and says so on stderr', () => {
  const hang = fakeClaude({ silent: true }, fs.mkdtempSync(path.join(tmp, 'fake-'))).bin;
  const ref = openWithFake(hang);
  const r = runCli(['session', 'prompt', JSON.stringify(ref), 'go', '--timeout', '400'], withHome());
  assert.equal(r.code, 4);
  assert.equal((parseSingleJson(r.stdout) as { kind: string }).kind, 'timeout');
  assert.match(r.stderr, /^exit=SIGKILL \(timeout 400ms, 0 tool call\(s\)\)/);
});

test('a prompt against a ref nobody knows is an error, not a crash', () => {
  const r = runCli(['session', 'prompt', 'no-such-session', 'go'], withHome());
  assert.equal(r.code, 1);
  assert.equal(r.stdout, '');
});

test('session list answers from the hook records', () => {
  const r = runCli(['session', 'list'], withHome());
  assert.equal(r.code, 0);
  const refs = parseSingleJson(r.stdout) as Array<{ id: string; claudeSessionId: string }>;
  assert.deepEqual(refs.map((x) => x.claudeSessionId), ['sess-live']);
  assert.deepEqual(parseSingleJson(runCli(['session', 'list', '--state', 'done'], withHome()).stdout), []);
  assert.equal(runCli(['session', 'list', '--state', 'invented'], withHome()).code, 2);
});

test('aborting something with no process behind it is refused, not faked', () => {
  const r = runCli(['session', 'abort', 'sess-live'], withHome());
  assert.equal(r.code, 3);
  assert.equal(r.stdout, '');
});

test('plugin list is JSON, and empty without a config', () => {
  const r = runCli(['plugin', 'list'], withHome());
  assert.equal(r.code, 0);
  const listed = parseSingleJson(r.stdout) as { plugins: unknown[]; errors: unknown[] };
  assert.deepEqual(listed.plugins, []);
  assert.deepEqual(listed.errors, []);
});

test('doctor reports the machine, and says nothing on stderr', () => {
  const r = runCli(['doctor'], withHome());
  assert.equal(r.code, 0);
  assert.equal(r.stderr, '');
  assert.match(r.stdout, /^node v\d+\./);
  assert.match(r.stdout, new RegExp(`agent state ${state.replace(/[/\\]/g, '\\$&')} \\(1 record`));
  assert.match(r.stdout, /config .*config\.yaml: missing/);
});

test('a half-read pipe is not a crash', () => {
  // `| head -1` closes stdout under the CLI. Reading part of the output is a
  // normal thing to do to a listing; an EPIPE stack trace would not be.
  const quoted = `${NODE} ${cliEntry()} sessions recent | head -1`;
  const r = spawnSync('/bin/sh', ['-c', quoted], { encoding: 'utf8', env: baseEnv(withHome()) });
  assert.equal(r.status, 0);
  assert.equal(r.stderr, '');
  assert.match(r.stdout, /^ffffffff /);
});

test('an unknown verb is a usage error with the usage on stderr', () => {
  const r = runCli(['nonsense'], withHome());
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown command: nonsense/);
  assert.match(r.stderr, /usage: tagents-core/);
  assert.equal(runCli(['--help'], withHome()).code, 0);
  assert.equal(runCli([], withHome()).code, 2, 'no arguments at all is a usage error');
});

test('TAGENTS_LOCALE translates the human strings and nothing else', () => {
  const ru = runCli(['nonsense'], withHome({ TAGENTS_LOCALE: 'ru' }));
  assert.match(ru.stderr, /неизвестная команда: nonsense/);
  const json = runCli(['session', 'list'], withHome({ TAGENTS_LOCALE: 'ru' }));
  assert.equal(json.stdout, runCli(['session', 'list'], withHome()).stdout, 'JSON output is not a human string');
});

/** A ref pointing at the fake binary, the way a caller would hand-edit one. */
function openWithFake(bin = fakeBin): unknown {
  const opened = parseSingleJson(runCli(['session', 'open', '--cwd', tmp], withHome()).stdout);
  const ref = opened as { spec: Record<string, unknown> };
  ref.spec['bin'] = bin;
  return ref;
}
