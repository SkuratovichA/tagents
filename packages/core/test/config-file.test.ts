// Which file is the config, how it is read, and what the TypeScript readers say about it. The bash dashboard reads the same file; tests/config-toml.sh is its side of these cases.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { configFile, loadPlugins, readPluginList } from '../src/host.ts';
import { parseConfigFile, parseConfigText, tomlKey } from '../src/config-file.ts';
import { tmpDir } from '../src/testkit.ts';
import { FIXTURES } from './helpers.ts';

let tmp: string;
let n = 0;
before(() => {
  tmp = tmpDir('config-file-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/** A fresh config dir holding the given files. */
const dirWith = (files: Record<string, string>): string => {
  const dir = path.join(tmp, `case-${n++}`);
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), body);
  return dir;
};

const GOOD = path.join(FIXTURES, 'plugin', 'good');

// smol-toml hands back objects with no prototype, which is the safe shape for a table called __proto__; a deep comparison against a literal wants plain ones.
const plain = (value: unknown): unknown => JSON.parse(JSON.stringify(value));

test('an empty file is an empty document', () => {
  assert.deepEqual(plain(parseConfigText('')), {});
});

test('the config is config.toml in the config dir the environment names, whether it is there yet or not', () => {
  const dir = dirWith({});
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: dir }), path.join(dir, 'config.toml'));
  fs.writeFileSync(path.join(dir, 'config.toml'), '');
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: dir }), path.join(dir, 'config.toml'));
});

test('a config.yaml beside the config is not looked at', () => {
  const dir = dirWith({ 'config.yaml': `plugins:\n  demo:\n    from: ./p\n` });
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: dir }), path.join(dir, 'config.toml'));
  assert.deepEqual(readPluginList(configFile({ TAGENTS_CONFIG_DIR: dir })), []);
});

test('the plugin list is read from a TOML config, in file order', () => {
  const dir = dirWith({
    'config.toml': `[plugins.demo]\nfrom = ${JSON.stringify(GOOD)}\n[plugins.second]\nfrom = "./two"\n`,
  });
  assert.deepEqual(readPluginList(path.join(dir, 'config.toml')), [
    { name: 'demo', from: GOOD },
    { name: 'second', from: './two' },
  ]);
});

test('a TOML config loads its plugins', async () => {
  const dir = dirWith({ 'config.toml': `[plugins.fixture]\nfrom = ${JSON.stringify(GOOD)}\n` });
  const loaded = await loadPlugins(path.join(dir, 'config.toml'));
  assert.deepEqual(loaded.errors, []);
  assert.deepEqual(loaded.plugins.map((p) => p.name), ['fixture']);
});

test('a TOML config with no plugins table lists nothing', () => {
  const dir = dirWith({ 'config.toml': `[usage]\nworkdays = true\n` });
  assert.deepEqual(readPluginList(path.join(dir, 'config.toml')), []);
});

test('a TOML config that does not parse throws the parser error, naming nothing it cannot know', () => {
  const dir = dirWith({ 'config.toml': 'plugins = \n' });
  assert.throws(() => readPluginList(path.join(dir, 'config.toml')));
});

test('parseConfigFile on a missing file throws, so a caller decides what a missing file means', () => {
  assert.throws(() => parseConfigFile(path.join(tmp, 'nowhere', 'config.toml')), { code: 'ENOENT' });
});

test('tomlKey leaves a bare key as it is, quotes any other through the string writer, and has none for a control character', () => {
  assert.equal(tomlKey('plain-key_1'), 'plain-key_1');
  assert.equal(tomlKey('a b'), '"a b"');
  assert.equal(tomlKey('a"b'), '"a\\"b"');
  assert.equal(tomlKey('a\tb'), null);
});
