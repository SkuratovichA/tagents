// Which file is the config, how it is read, and what the TypeScript readers say about it. The bash dashboard applies the same lookup; tests/config-toml.sh is its side of these cases.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { configFile, loadPlugins, readPluginList } from '../src/host.ts';
import { configFormat, parseConfigText, readConfigFile, resolveConfigFile } from '../src/config-file.ts';
import { tmpDir } from '../src/testkit.ts';
import { FIXTURES, PKG } from './helpers.ts';

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

/** Everything written to stderr while `fn` runs. */
function stderrOf<T>(fn: () => T): { result: T; err: string } {
  const real = process.stderr.write.bind(process.stderr);
  let err = '';
  process.stderr.write = ((chunk: string | Uint8Array): boolean => {
    err += typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');
    return true;
  }) as typeof process.stderr.write;
  try {
    return { result: fn(), err };
  } finally {
    process.stderr.write = real;
  }
}

const GOOD = path.join(FIXTURES, 'plugin', 'good');

// smol-toml hands back objects with no prototype, which is the safe shape for a table called __proto__; a deep comparison against a literal wants plain ones.
const plain = (value: unknown): unknown => JSON.parse(JSON.stringify(value));

// The same table tests/config-toml.sh walks through the bash reader, so the two cannot disagree about what a TOML file is.
test('a name ending in .toml, case-sensitively, is TOML and everything else is YAML, as in the dashboard', () => {
  const rows = fs
    .readFileSync(path.join(PKG, '..', '..', 'tests', 'fixtures', 'config-formats.tsv'), 'utf8')
    .split('\n')
    .filter((row) => row !== '');
  assert.ok(rows.length >= 10);
  for (const row of rows) {
    const [name, format] = row.split('\t');
    assert.equal(configFormat(`/x/${name}`), format, name);
  }
});

test('a TOML file and the YAML file it replaces parse to the same document', () => {
  const toml = parseConfigText(`[plugins.demo]\nfrom = "./p"\n`, 'toml');
  const yaml = parseConfigText(`plugins:\n  demo:\n    from: ./p\n`, 'yaml');
  assert.deepEqual(plain(toml), plain(yaml));
});

test('an empty file is an empty document in either format', () => {
  assert.deepEqual(plain(parseConfigText('', 'toml')), {});
  assert.deepEqual(plain(parseConfigText('', 'yaml')), {});
});

test('the config is config.toml when there is one, else config.yaml, else config.toml as the place for a new one', () => {
  assert.equal(resolveConfigFile(dirWith({ 'config.toml': '' })), path.join(tmp, `case-${n - 1}`, 'config.toml'));
  assert.equal(resolveConfigFile(dirWith({ 'config.yaml': '' })), path.join(tmp, `case-${n - 1}`, 'config.yaml'));
  assert.equal(
    resolveConfigFile(dirWith({ 'config.toml': '', 'config.yaml': '' })),
    path.join(tmp, `case-${n - 1}`, 'config.toml')
  );
  assert.equal(resolveConfigFile(dirWith({})), path.join(tmp, `case-${n - 1}`, 'config.toml'));
});

test('a directory called config.toml is not a config', () => {
  const dir = dirWith({ 'config.yaml': '' });
  fs.mkdirSync(path.join(dir, 'config.toml'));
  assert.equal(resolveConfigFile(dir), path.join(dir, 'config.yaml'));
});

test('configFile follows the same rule in the config dir the environment names', () => {
  const dir = dirWith({ 'config.yaml': 'plugins: {}\n' });
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: dir }), path.join(dir, 'config.yaml'));
  fs.writeFileSync(path.join(dir, 'config.toml'), '');
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: dir }), path.join(dir, 'config.toml'));
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

test('a TOML config loads its plugins like a YAML one', async () => {
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

test('a YAML config is read as before and said to be deprecated, once', () => {
  const dir = dirWith({ 'config.yaml': `plugins:\n  demo:\n    from: ./p\n` });
  const file = path.join(dir, 'config.yaml');
  const first = stderrOf(() => readPluginList(file));
  assert.deepEqual(first.result, [{ name: 'demo', from: './p' }]);
  assert.match(first.err, /config\.yaml is a YAML config, which is deprecated — run: tagents config convert/);
  const second = stderrOf(() => readPluginList(file));
  assert.equal(second.err, '', 'a second read in the same process says nothing');
});

test('a TOML config on its own says nothing', () => {
  const dir = dirWith({ 'config.toml': `[plugins.demo]\nfrom = "./p"\n` });
  assert.equal(stderrOf(() => readPluginList(path.join(dir, 'config.toml'))).err, '');
});

test('a config.toml beside a config.yaml is read and the YAML one is named as ignored', () => {
  const dir = dirWith({
    'config.toml': `[plugins.fromtoml]\nfrom = "./a"\n`,
    'config.yaml': `plugins:\n  fromyaml:\n    from: ./b\n`,
  });
  const { result, err } = stderrOf(() => readPluginList(configFile({ TAGENTS_CONFIG_DIR: dir })));
  assert.deepEqual(result, [{ name: 'fromtoml', from: './a' }]);
  assert.match(err, /config\.toml: config\.yaml is also there — config\.toml is read and config\.yaml is ignored/);
});

test('readConfigFile on a missing file throws, so a caller decides what a missing file means', () => {
  assert.throws(() => readConfigFile(path.join(tmp, 'nowhere', 'config.toml')), { code: 'ENOENT' });
});
