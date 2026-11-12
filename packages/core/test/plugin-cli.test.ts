// `tagents-core plugin list`, and the library that edits the config file (`add`, `remove` and `new` are the binary's verbs; their tests are crates/tagents-core/tests).
//
// Every case runs against a config dir under $TMPDIR, pointed at with
// TAGENTS_CONFIG_DIR: the owner's real ~/.config/tagents must never be read,
// and — this being the one suite that WRITES config files — never written.
//
// The load-bearing assertion is not "the entry is there". It is that
// everything else in the file came back byte for byte: the config is somebody's
// hand-written document with comments in it, and an installer that reflows it
// is an installer nobody runs twice.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { addPluginEntry, defaultPluginName, removePluginEntry } from '../src/plugin-config.ts';
import { tmpDir } from '../src/testkit.ts';
import { FIXTURES, parseSingleJson, runCli } from './helpers.ts';

const PLUGINS = path.join(FIXTURES, 'plugin');
const GOOD = path.join(PLUGINS, 'good');

let tmp: string;
let seq = 0;

/** A fresh, empty config dir per case. */
function configDir(): string {
  const dir = path.join(tmp, `cfg-${++seq}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

/** A fresh config dir holding `body` as its config.toml. */
function tomlDir(body: string): string {
  const dir = configDir();
  fs.writeFileSync(path.join(dir, 'config.toml'), body);
  return dir;
}

const inDir = (dir: string): Record<string, string> => ({ TAGENTS_CONFIG_DIR: dir });

before(() => {
  tmp = tmpDir('plugin-cli-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test('plugin list says so in words when nothing is configured', () => {
  const dir = configDir();
  const r = runCli(['plugin', 'list'], inDir(dir));
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^no plugins configured in .*config\.toml\n$/);
});

test('plugin list --json is one JSON document, and the JSON is unchanged', () => {
  const dir = configDir();
  const r = runCli(['plugin', 'list', '--json'], inDir(dir));
  assert.equal(r.code, 0);
  const listed = parseSingleJson(r.stdout) as { plugins: unknown[]; errors: unknown[]; file: string };
  assert.deepEqual(listed.plugins, []);
  assert.deepEqual(listed.errors, []);
  assert.equal(listed.file, path.join(dir, 'config.toml'));
});

test('plugin list prints the config key and what the plugin offers', () => {
  const dir = configDir();
  fs.writeFileSync(path.join(dir, 'config.toml'), `[plugins.fixture-plugin]\nfrom = "${GOOD}"\n`);
  const r = runCli(['plugin', 'list'], inDir(dir));
  assert.equal(r.code, 0);
  assert.equal(
    r.stdout,
    `fixture-plugin → ${GOOD}\n  commands: echo, greet, exits, boom, join · services: ticker · mcp tools: sessions_recent\n`
  );
});

test('the default key is the package name without its scope or plugin- prefix', () => {
  assert.equal(defaultPluginName('@tagents/plugin-telegram'), 'telegram');
  assert.equal(defaultPluginName('tagents-plugin-notes'), 'notes');
  assert.equal(defaultPluginName('fixture-plugin'), 'fixture-plugin');
});

test('the library edits a TOML file the same way', () => {
  const file = path.join(tomlDir('[usage]\nworkdays = true\n'), 'config.toml');
  assert.equal(addPluginEntry(file, 'x', '/pkg/x'), 'added');
  assert.equal(addPluginEntry(file, 'x', '/pkg/x'), 'exists');
  assert.equal(removePluginEntry(file, 'x'), 'removed');
  assert.equal(removePluginEntry(file, 'x'), 'absent');
  assert.equal(fs.readFileSync(file, 'utf8'), '[usage]\nworkdays = true\n');
});

test('a plugin path with a control character in it is refused for a TOML config, naming the file, and nothing is written', () => {
  const file = path.join(tomlDir('[usage]\nworkdays = true\n'), 'config.toml');
  assert.throws(() => addPluginEntry(file, 'x', '/pkg/a\tb'), (e: unknown) => e instanceof Error && e.message.includes(file));
  assert.equal(fs.readFileSync(file, 'utf8'), '[usage]\nworkdays = true\n');
});

test('a plugin name with a control character in it is refused for a TOML config, naming the file, and nothing is written', () => {
  const file = path.join(tomlDir('[usage]\nworkdays = true\n'), 'config.toml');
  assert.throws(() => addPluginEntry(file, 'a\tb', '/pkg/a'), (e: unknown) => e instanceof Error && e.message.includes(file));
  assert.equal(fs.readFileSync(file, 'utf8'), '[usage]\nworkdays = true\n');
});

test('a plugin path or name with a lone surrogate in it is refused for a TOML config, saying so, and nothing is written', () => {
  const file = path.join(tomlDir('[usage]\nworkdays = true\n'), 'config.toml');
  for (const [name, from] of [['x', '/pkg/a\ud800b'], ['a\ud800b', '/pkg/a']] as const) {
    assert.throws(() => addPluginEntry(file, name, from), (e: unknown) => e instanceof Error && e.message.includes(file) && e.message.includes('lone surrogate'));
    assert.equal(fs.readFileSync(file, 'utf8'), '[usage]\nworkdays = true\n');
  }
});

test('an unknown plugin verb is a usage error that prints the usage', () => {
  const r = runCli(['plugin', 'install', 'x'], inDir(configDir()));
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown command: plugin install/);
  assert.match(r.stderr, /plugin add <package-or-path>/);
});
