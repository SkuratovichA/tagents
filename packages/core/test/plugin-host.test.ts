// The plugin host: what it loads, and — more importantly — what it does not.
//
// EXPLICIT LISTING ONLY. There is a plugin package sitting in this repo's fixtures; unless config.toml names it, the host must not find it. Scanning is how a machine ends up running code nobody chose.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { configDir, configFile, loadPlugins, readPluginList, resolvePackageDir } from '../src/host.ts';
import { definePlugin, PLUGIN_API_VERSION } from '../src/plugin.ts';
import { tmpDir } from '../src/testkit.ts';
import { FIXTURES } from './helpers.ts';

const PLUGINS = path.join(FIXTURES, 'plugin');
let tmp: string;

const writeConfig = (body: string): string => {
  const file = path.join(tmp, 'config.toml');
  fs.writeFileSync(file, body);
  return file;
};

before(() => {
  tmp = tmpDir('plugin-host-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test('the config dir follows TAGENTS_CONFIG_DIR, then XDG, then ~/.config', () => {
  assert.equal(configDir({ TAGENTS_CONFIG_DIR: '/x/tagents' }), '/x/tagents');
  assert.equal(configDir({ XDG_CONFIG_HOME: '/x/cfg' }), path.join('/x/cfg', 'tagents'));
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: '/x/tagents' }), '/x/tagents/config.toml');
});

test('no config file at all is no plugins, not an error', async () => {
  const missing = path.join(tmp, 'nowhere', 'config.toml');
  assert.deepEqual(readPluginList(missing), []);
  const loaded = await loadPlugins(missing);
  assert.deepEqual(loaded.plugins, []);
  assert.deepEqual(loaded.errors, []);
});

test('a config that cannot be read for any reason is no plugins', () => {
  const dir = path.join(tmp, 'a-directory.toml');
  fs.mkdirSync(dir, { recursive: true });
  assert.deepEqual(readPluginList(dir), []);
  if (process.getuid?.() === 0) return;
  const locked = writeConfig('[plugins.x]\nfrom = "/one"\n');
  fs.chmodSync(locked, 0o000);
  try {
    assert.deepEqual(readPluginList(locked), []);
  } finally {
    fs.chmodSync(locked, 0o600);
  }
});

test('a config that reads but does not parse throws, naming the file', () => {
  const toml = writeConfig('[plugins.x\nfrom = 1\n');
  assert.throws(() => readPluginList(toml), (e: unknown) => e instanceof Error && e.message.includes(toml));
  const yaml = path.join(tmp, 'broken.yaml');
  fs.writeFileSync(yaml, 'plugins:\n  x: [unclosed\n');
  assert.throws(() => readPluginList(yaml), (e: unknown) => e instanceof Error && e.message.includes(yaml));
});

test('a good TOML config lists its plugins', () => {
  const file = writeConfig('[plugins.a]\nfrom = "/one"\n\n[plugins.b]\nfrom = "/two"\n');
  assert.deepEqual(readPluginList(file), [{ name: 'a', from: '/one' }, { name: 'b', from: '/two' }]);
});

test('a config without a plugins table loads nothing', async () => {
  const file = writeConfig('[accounts]\npersonal = "~/.claude"\n');
  assert.deepEqual(readPluginList(file), []);
  assert.deepEqual((await loadPlugins(file)).plugins, []);
});

test('a listed plugin is imported through its package.json "tagents.entry"', async () => {
  const file = writeConfig(`[plugins.fixture]\nfrom = ${JSON.stringify(path.join(PLUGINS, 'good'))}\n`);
  assert.deepEqual(readPluginList(file), [{ name: 'fixture', from: path.join(PLUGINS, 'good') }]);
  const loaded = await loadPlugins(file);
  assert.deepEqual(loaded.errors, []);
  assert.equal(loaded.plugins.length, 1);
  const p = loaded.plugins[0];
  assert.equal(p?.def.name, 'fixture');
  assert.equal(p?.def.apiVersion, PLUGIN_API_VERSION);
  assert.equal(p?.entry, path.join(PLUGINS, 'good', 'lib', 'plugin.mjs'));
  assert.deepEqual(p?.def.commands?.map((c) => c.name), ['echo', 'greet', 'exits', 'boom', 'join']);
  assert.deepEqual(p?.def.services?.map((s) => s.name), ['ticker']);
  assert.deepEqual(p?.def.mcpTools?.map((m) => m.name), ['sessions_recent']);
});

test('a relative from resolves against the config file, not the cwd', () => {
  const rel = path.relative(tmp, path.join(PLUGINS, 'good'));
  assert.equal(resolvePackageDir(rel.startsWith('.') ? rel : `./${rel}`, tmp), path.join(PLUGINS, 'good'));
});

test('a plugin the config does not name is not loaded, however close it sits', async () => {
  const file = writeConfig(`[plugins.fixture]\nfrom = ${JSON.stringify(path.join(PLUGINS, 'good'))}\n`);
  const loaded = await loadPlugins(file);
  assert.equal(loaded.plugins.length, 1, 'the sibling fixtures under the same directory stay untouched');
  assert.ok(fs.existsSync(path.join(PLUGINS, 'bad-version', 'package.json')));
});

test('one broken plugin is reported, and the working ones still load', async () => {
  const file = writeConfig(
    `[plugins.fixture]\nfrom = ${JSON.stringify(path.join(PLUGINS, 'good'))}\n` +
      `[plugins.no-entry]\nfrom = ${JSON.stringify(path.join(PLUGINS, 'no-entry'))}\n` +
      `[plugins.future]\nfrom = ${JSON.stringify(path.join(PLUGINS, 'bad-version'))}\n` +
      `[plugins.absent]\nfrom = ${JSON.stringify(path.join(tmp, 'not-here'))}\n`
  );
  const loaded = await loadPlugins(file);
  assert.deepEqual(loaded.plugins.map((p) => p.name), ['fixture']);
  assert.deepEqual(loaded.errors.map((e) => e.name), ['no-entry', 'future', 'absent']);
  assert.match(loaded.errors[0]?.error ?? '', /has no "tagents"/);
  assert.match(loaded.errors[1]?.error ?? '', /apiVersion: 1/);
  assert.match(loaded.errors[2]?.error ?? '', /no package.json/);
});

test('definePlugin is the identity, and it types what it returns', () => {
  const def = definePlugin({ name: 'x', apiVersion: 1 });
  assert.deepEqual(def, { name: 'x', apiVersion: 1 });
});

test('a relative from that misses lexically resolves through a symlinked config dir', () => {
  const real = path.join(tmp, 'sym-real', 'dotfiles', 'config');
  const link = path.join(tmp, 'sym-home', 'tagents');
  fs.mkdirSync(real, { recursive: true });
  fs.mkdirSync(path.join(tmp, 'sym-real', 'dotfiles', 'pkg'));
  fs.writeFileSync(path.join(tmp, 'sym-real', 'dotfiles', 'pkg', 'package.json'), '{}');
  fs.mkdirSync(path.dirname(link), { recursive: true });
  fs.symlinkSync(real, link);
  assert.equal(
    fs.realpathSync(resolvePackageDir('../pkg', link)),
    fs.realpathSync(path.join(tmp, 'sym-real', 'dotfiles', 'pkg'))
  );
  assert.equal(resolvePackageDir('../pkg', link), path.join(fs.realpathSync(tmp), 'sym-real', 'dotfiles', 'pkg'));
});

test('a lexical hit still wins over the real directory', () => {
  const real = path.join(tmp, 'both-real', 'dot', 'config');
  const link = path.join(tmp, 'both-home', 'tagents');
  fs.mkdirSync(real, { recursive: true });
  fs.mkdirSync(path.join(tmp, 'both-real', 'dot', 'pkg'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'both-real', 'dot', 'pkg', 'package.json'), '{}');
  fs.mkdirSync(path.join(tmp, 'both-home', 'pkg'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'both-home', 'pkg', 'package.json'), '{}');
  fs.symlinkSync(real, link);
  assert.equal(resolvePackageDir('../pkg', link), path.join(tmp, 'both-home', 'pkg'));
});

test('a miss on both sides keeps the lexical path the person wrote', () => {
  assert.equal(resolvePackageDir('./nowhere', tmp), path.join(tmp, 'nowhere'));
});

test('a package name resolves as before', () => {
  const dir = resolvePackageDir('zod', path.join(PLUGINS, 'good'));
  assert.equal(path.basename(dir), 'zod');
});
