// node --test exec.test.ts
//
// Real programs, none of them anything but what ships with macOS: the point of
// this module is what a child process does, and a fake would test the fake.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { tmpDir } from '@tagents/core';
import { execText } from '../src/exec.ts';

test('stdin goes in and stdout comes back', async () => {
  const r = await execText('/bin/cat', [], { input: 'round trip ✳\n', timeoutMs: 5000 });
  assert.deepEqual(r, { code: 0, stdout: 'round trip ✳\n', stderr: '', timedOut: false });
});

test('a program that is not given input does not wait for it', async () => {
  const r = await execText('/bin/cat', [], { timeoutMs: 5000 });
  assert.equal(r.code, 0);
  assert.equal(r.timedOut, false);
});

test('a non-zero exit is a result, with the code and stderr', async () => {
  const f = await execText('/usr/bin/false', [], { timeoutMs: 5000 });
  assert.equal(f.code, 1);
  assert.equal(f.timedOut, false);
  const s = await execText('/bin/sh', ['-c', 'echo oops >&2; exit 3'], { timeoutMs: 5000 });
  assert.equal(s.code, 3);
  assert.equal(s.stderr, 'oops\n');
});

test('a program that exits before it reads its input is not an error either', async () => {
  const r = await execText('/usr/bin/false', [], { input: 'x'.repeat(1 << 20), timeoutMs: 5000 });
  assert.equal(r.code, 1);
});

test('the env option replaces the environment', async () => {
  const r = await execText('/usr/bin/env', [], { env: { ONLY: 'this' }, timeoutMs: 5000 });
  assert.equal(r.stdout.trim(), 'ONLY=this');
});

test('a program that outlives the timeout is killed, and nothing is left running', async () => {
  const dir = tmpDir('notify-exec');
  const pidFile = path.join(dir, 'pid');
  try {
    const t0 = Date.now();
    // `exec` keeps the shell's pid for the sleep, so the pid in the file is the one that must die.
    const r = await execText('/bin/sh', ['-c', 'echo $$ > "$1"; exec /bin/sleep 10', '_', pidFile], { timeoutMs: 200 });
    assert.equal(r.timedOut, true);
    assert.equal(r.code, null);
    assert.ok(Date.now() - t0 < 2000, `took ${Date.now() - t0} ms`);
    const pid = Number(fs.readFileSync(pidFile, 'utf8').trim());
    assert.ok(Number.isInteger(pid) && pid > 1);
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a program that cannot be started rejects', async () => {
  await assert.rejects(execText('/nonexistent/program', [], { timeoutMs: 1000 }), { code: 'ENOENT' });
});
