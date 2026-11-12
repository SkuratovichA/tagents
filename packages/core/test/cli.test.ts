// The CLI's outside edge, spawned as a real program (the BUILT bin when there is one — that is what a consumer installs).
//
// What is left of the CLI once the Rust binary serves the session, sessions, doctor and plugin-writing verbs: `plugin list`, the usage lines, and the one line a retired verb gets.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { tmpDir } from '../src/testkit.ts';
import { loadSpec } from '../src/cli/spec.ts';
import { parseSingleJson, runCli } from './helpers.ts';

let tmp: string;
let config: string;

const withHome = (extra: Record<string, string> = {}): Record<string, string> => ({
  HOME: tmp,
  TAGENTS_CONFIG_DIR: config,
  ...extra,
});

before(() => {
  tmp = tmpDir('cli-test');
  config = path.join(tmp, 'config');
  fs.mkdirSync(config, { recursive: true });
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test('plugin list --json is JSON, and empty without a config', () => {
  const r = runCli(['plugin', 'list', '--json'], withHome());
  assert.equal(r.code, 0);
  const listed = parseSingleJson(r.stdout) as { plugins: unknown[]; errors: unknown[] };
  assert.deepEqual(listed.plugins, []);
  assert.deepEqual(listed.errors, []);
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
});

// ------------------------------------------------------------ retired verbs ---

/** What the line says, whatever the verb: both ways to get the binary, and which verb needs it. */
const needsBinary = (verb: string): RegExp => new RegExp(`^${verb} is served by the tagents-core binary.*\`tagents update\`.*\`cargo build --release -p tagents-core\`.*\n$`);

test('a retired verb prints the needs-binary line and exits 69, with nothing on stdout', () => {
  const cases: [string[], string][] = [
    [['session', 'open', '--cwd', '/x'], 'session open'],
    [['session', 'whatever'], 'session whatever'],
    [['session'], 'session'],
    [['sessions', 'recent'], 'sessions recent'],
    [['sessions', 'nonsense'], 'sessions nonsense'],
    [['doctor'], 'doctor'],
    [['plugin', 'add', './p'], 'plugin add'],
    [['plugin', 'remove', 'x'], 'plugin remove'],
    [['plugin', 'new', 'x'], 'plugin new'],
    [['mcp', '--contract', 'f'], 'mcp'],
    [['notify', 'run'], 'notify run'],
  ];
  for (const [argv, shown] of cases) {
    const r = runCli(argv, withHome());
    assert.equal(r.code, 69, `${argv.join(' ')} exits 69`);
    assert.equal(r.stdout, '', `${argv.join(' ')} prints nothing on stdout`);
    assert.match(r.stderr, needsBinary(shown), `${argv.join(' ')} says so`);
  }
});

test('every verb the spec marks rust gets the line, and no verb marked node does', () => {
  const spec = JSON.parse(fs.readFileSync(new URL('../../../spec/cli/tagents-core.json', import.meta.url), 'utf8')) as {
    commands: { path: string[]; impl: 'rust' | 'node' }[];
  };
  assert.ok(loadSpec().served.length > 0);
  for (const c of spec.commands) {
    const r = runCli([...c.path], withHome());
    if (c.impl === 'rust') assert.equal(r.code, 69, `${c.path.join(' ')} is the binary's`);
    else assert.notEqual(r.code, 69, `${c.path.join(' ')} is node's`);
  }
});

test('a group the binary serves only in part is not retired for its other words', () => {
  for (const argv of [['notify', 'status'], ['notify', 'install'], ['notify']]) {
    const r = runCli(argv, withHome());
    assert.notEqual(r.code, 69, `${argv.join(' ')} is node's, the spec lists only notify run`);
  }
});

test('a group wholly the binary\'s keeps the line for any word after it', () => {
  for (const argv of [['session', 'bogus'], ['sessions', 'anything']]) {
    assert.equal(runCli(argv, withHome()).code, 69, `${argv.join(' ')} is the binary's`);
  }
});

test('the needs-binary text is translated, and the code is the same', () => {
  const r = runCli(['doctor'], withHome({ TAGENTS_LOCALE: 'ru' }));
  assert.equal(r.code, 69);
  assert.match(r.stderr, /^doctor is served by the tagents-core binary/, 'the Russian table has no such line, so English is the fallback');
});
