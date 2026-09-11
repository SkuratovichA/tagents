// The plugin host: what it loads, and — more importantly — what it does not.
//
// EXPLICIT LISTING ONLY. There is a plugin package sitting in this repo's
// fixtures; unless config.yaml names it, the host must not find it. Scanning is
// how a machine ends up running code nobody chose.
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
  const file = path.join(tmp, 'config.yaml');
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
  assert.equal(configFile({ TAGENTS_CONFIG_DIR: '/x/tagents' }), '/x/tagents/config.yaml');
});

test('no config file at all is no plugins, not an error', async () => {
  const missing = path.join(tmp, 'nowhere', 'config.yaml');
  assert.deepEqual(readPluginList(missing), []);
  const loaded = await loadPlugins(missing);
  assert.deepEqual(loaded.plugins, []);
  assert.deepEqual(loaded.errors, []);
});

test('a config without a plugins: key loads nothing', async () => {
  const file = writeConfig('accounts:\n  personal: ~/.claude\n');
  assert.deepEqual(readPluginList(file), []);
  assert.deepEqual((await loadPlugins(file)).plugins, []);
});

test('a listed plugin is imported through its package.json "tagents.entry"', async () => {
  const file = writeConfig(`plugins:\n  fixture:\n    from: ${path.join(PLUGINS, 'good')}\n`);
  assert.deepEqual(readPluginList(file), [{ name: 'fixture', from: path.join(PLUGINS, 'good') }]);
  const loaded = await loadPlugins(file);
  assert.deepEqual(loaded.errors, []);
  assert.equal(loaded.plugins.length, 1);
  const p = loaded.plugins[0];
  assert.equal(p?.def.name, 'fixture');
  assert.equal(p?.def.apiVersion, PLUGIN_API_VERSION);
  assert.equal(p?.entry, path.join(PLUGINS, 'good', 'lib', 'plugin.mjs'));
  assert.deepEqual(p?.def.commands?.map((c) => c.name), ['echo']);
  assert.deepEqual(p?.def.services?.map((s) => s.name), ['ticker']);
  assert.deepEqual(p?.def.mcpTools?.map((m) => m.name), ['sessions_recent']);
});

test('a relative from: resolves against the config file, not the cwd', () => {
  const rel = path.relative(tmp, path.join(PLUGINS, 'good'));
  assert.equal(resolvePackageDir(rel.startsWith('.') ? rel : `./${rel}`, tmp), path.join(PLUGINS, 'good'));
});

test('a plugin the config does not name is not loaded, however close it sits', async () => {
  const file = writeConfig(`plugins:\n  fixture:\n    from: ${path.join(PLUGINS, 'good')}\n`);
  const loaded = await loadPlugins(file);
  assert.equal(loaded.plugins.length, 1, 'the sibling fixtures under the same directory stay untouched');
  assert.ok(fs.existsSync(path.join(PLUGINS, 'bad-version', 'package.json')));
});

test('one broken plugin is reported, and the working ones still load', async () => {
  const file = writeConfig(
    `plugins:\n` +
      `  fixture:\n    from: ${path.join(PLUGINS, 'good')}\n` +
      `  no-entry:\n    from: ${path.join(PLUGINS, 'no-entry')}\n` +
      `  future:\n    from: ${path.join(PLUGINS, 'bad-version')}\n` +
      `  absent:\n    from: ${path.join(tmp, 'not-here')}\n`
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
