// Where the folder and the index come from, in the order a person expects.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { DB_BASENAME, configuredDir, expandHome, resolveDb, resolveDir } from '../src/paths.ts';
import { copyKnowledge, removeDir, runCli, tmpDir } from './helpers.ts';

test('~ is expanded, and only at the start', () => {
  assert.equal(expandHome('~/notes', '/Users/demo'), '/Users/demo/notes');
  assert.equal(expandHome('~', '/Users/demo'), '/Users/demo');
  assert.equal(expandHome('/abs/~/notes', '/Users/demo'), '/abs/~/notes');
  assert.equal(expandHome('relative/notes', '/Users/demo'), 'relative/notes');
});

test('knowledge.dir is read from config.yaml, relative to the config', () => {
  const root = tmpDir('config');
  try {
    const config = path.join(root, 'config.yaml');
    copyKnowledge(path.join(root, 'knowledge'));
    fs.writeFileSync(config, 'plugins:\n  something:\n    from: ./x\nknowledge:\n  dir: ./knowledge\n');
    assert.equal(configuredDir(config), path.join(root, 'knowledge'));

    fs.writeFileSync(config, 'plugins: {}\n');
    assert.equal(configuredDir(config), null);
    assert.equal(configuredDir(path.join(root, 'no-such-config.yaml')), null);

    fs.writeFileSync(config, 'knowledge:\n  dir: ~/knowledge\n');
    assert.equal(configuredDir(config), path.join(os.homedir(), 'knowledge'));
  } finally {
    removeDir(root);
  }
});

test('the environment beats the config, and an explicit path beats both', () => {
  const root = tmpDir('precedence');
  try {
    const fromConfig = copyKnowledge(path.join(root, 'from-config'));
    const fromEnv = copyKnowledge(path.join(root, 'from-env'));
    const explicit = copyKnowledge(path.join(root, 'explicit'));
    fs.writeFileSync(path.join(root, 'config.yaml'), `knowledge:\n  dir: ${fromConfig}\n`);
    const env = { TAGENTS_CONFIG_DIR: root };

    assert.deepEqual(resolveDir(null, env), { ok: true, dir: fromConfig });
    assert.deepEqual(resolveDir(null, { ...env, TAGENTS_KNOWLEDGE_DIR: fromEnv }), {
      ok: true,
      dir: fromEnv,
    });
    assert.deepEqual(resolveDir(explicit, { ...env, TAGENTS_KNOWLEDGE_DIR: fromEnv }), {
      ok: true,
      dir: explicit,
    });

    const unset = resolveDir(null, { TAGENTS_CONFIG_DIR: path.join(root, 'empty') });
    assert.equal(unset.ok, false);
    assert.equal(unset.ok === false && unset.reason, 'unset');

    const missing = resolveDir(path.join(root, 'nowhere'), env);
    assert.equal(missing.ok, false);
    assert.equal(missing.ok === false && missing.reason, 'missing');
  } finally {
    removeDir(root);
  }
});

test('the index defaults next to the config, and moves with the env', () => {
  const env = { TAGENTS_CONFIG_DIR: '/tmp/tagents-config' };
  assert.equal(resolveDb(null, env), path.join('/tmp/tagents-config', DB_BASENAME));
  assert.equal(resolveDb(null, { ...env, TAGENTS_KNOWLEDGE_DB: '/tmp/other.sqlite' }), '/tmp/other.sqlite');
  assert.equal(resolveDb('/tmp/explicit.sqlite', { ...env, TAGENTS_KNOWLEDGE_DB: '/tmp/other.sqlite' }), '/tmp/explicit.sqlite');
});

test('the CLI finds the folder through config.yaml alone', () => {
  const root = tmpDir('cli-config');
  try {
    copyKnowledge(path.join(root, 'knowledge'));
    fs.writeFileSync(path.join(root, 'config.yaml'), 'knowledge:\n  dir: ./knowledge\n');
    const r = runCli(['list', '--kind', 'map'], { TAGENTS_CONFIG_DIR: root });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /^mashina-karta/);
    // The index landed next to the config, because nobody said otherwise.
    assert.ok(fs.existsSync(path.join(root, DB_BASENAME)));
  } finally {
    removeDir(root);
  }
});
