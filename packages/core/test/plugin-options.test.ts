// A plugin's options live in <configDir>/plugins/<name>.toml and are read through one function that never throws: a missing file is the defaults, a broken one is a list of problems a person can fix.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { z } from 'zod';
import { loadPluginOptions, pluginOptionsFile } from '../src/plugin-options.ts';
import { tmpDir } from '../src/testkit.ts';

const schema = z.object({ sound: z.string().default('ping'), volume: z.number().default(1) });

let tmp: string;
before(() => {
  tmp = tmpDir('plugin-options-test');
  fs.mkdirSync(path.join(tmp, 'plugins'));
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const write = (name: string, body: string): void => fs.writeFileSync(path.join(tmp, 'plugins', `${name}.toml`), body);

test('the options file is <configDir>/plugins/<name>.toml, the place a new one goes', () => {
  assert.equal(pluginOptionsFile('/c', 'notify'), '/c/plugins/notify.toml');
});

test('a <name>.yaml beside it is not looked at', () => {
  fs.writeFileSync(path.join(tmp, 'plugins', 'onlyyaml.yaml'), 'sound: glass\n');
  assert.equal(pluginOptionsFile(tmp, 'onlyyaml'), path.join(tmp, 'plugins', 'onlyyaml.toml'));
  const r = loadPluginOptions(tmp, 'onlyyaml', schema);
  assert.deepEqual(r, { ok: true, value: { sound: 'ping', volume: 1 }, file: path.join(tmp, 'plugins', 'onlyyaml.toml'), found: false });
});

test('a TOML options file is read', () => {
  write('tomlonly', 'sound = "glass"\nvolume = 2\n');
  const r = loadPluginOptions(tmp, 'tomlonly', schema);
  assert.deepEqual(r, { ok: true, value: { sound: 'glass', volume: 2 }, file: path.join(tmp, 'plugins', 'tomlonly.toml'), found: true });
});

test('broken TOML is one problem that names the file', () => {
  write('brokentoml', 'sound = \n');
  const r = loadPluginOptions(tmp, 'brokentoml', schema);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.problems.length, 1);
  assert.ok(r.problems[0]?.startsWith(`${r.file}: `));
});

test('a missing file gives the schema defaults and found: false', () => {
  const r = loadPluginOptions(tmp, 'absent', schema);
  assert.deepEqual(r, { ok: true, value: { sound: 'ping', volume: 1 }, file: pluginOptionsFile(tmp, 'absent'), found: false });
});

test('a valid file gives the parsed value and found: true', () => {
  write('valid', 'sound = "glass"\n');
  const r = loadPluginOptions(tmp, 'valid', schema);
  assert.deepEqual(r, { ok: true, value: { sound: 'glass', volume: 1 }, file: pluginOptionsFile(tmp, 'valid'), found: true });
});

test('an empty file is the defaults, found', () => {
  write('empty', '');
  const r = loadPluginOptions(tmp, 'empty', schema);
  assert.equal(r.ok && r.found, true);
  assert.deepEqual(r.ok && r.value, { sound: 'ping', volume: 1 });
});

test('a schema mismatch is one problem per issue, worded path: message', () => {
  write('wrong', 'sound = 3\nvolume = "loud"\n');
  const r = loadPluginOptions(tmp, 'wrong', schema);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.problems.length, 2);
  assert.ok(r.problems[0]?.startsWith('sound: '));
  assert.ok(r.problems[1]?.startsWith('volume: '));
});
