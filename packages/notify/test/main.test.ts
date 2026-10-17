// node --test main.test.ts
//
// The bin as launchd would meet it: a real process, from the TypeScript source
// (node strips the types), with no arguments and with a verb that does not exist.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const MAIN = path.join(fileURLToPath(new URL('../src', import.meta.url)), 'main.ts');

function run(...args: string[]) {
  return spawnSync(process.execPath, [MAIN, ...args], { encoding: 'utf8', timeout: 30_000 });
}

test('no verb: exit 2 and the five verbs are listed', () => {
  const r = run();
  assert.equal(r.status, 2, r.stderr);
  for (const verb of ['run', 'install', 'uninstall', 'status', 'test']) {
    assert.match(r.stderr, new RegExp(`\\b${verb}\\b`), verb);
  }
});

test('a verb that does not exist: exit 2', () => {
  const r = run('bogus');
  assert.equal(r.status, 2, r.stderr);
  assert.match(r.stderr, /bogus/);
});
