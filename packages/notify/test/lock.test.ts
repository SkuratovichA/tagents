// node --test lock.test.ts
//
// The lock file `status` and `install` read, and the judgement of whether the process it names is still the service that wrote it. Taking the lock is the Rust binary's.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { tmpDir } from '@tagents/core';
import type { Exec } from '../src/exec.ts';
import { LOCK_FILE, holds, psProcessStart, readLock, type LockContent, type LockDeps } from '../src/lock.ts';

test('psProcessStart asks ps for the start time in a fixed locale and time zone and trims it', async () => {
  const calls: { file: string; args: readonly string[]; env: NodeJS.ProcessEnv | undefined }[] = [];
  const exec: Exec = (file, args, o) => {
    calls.push({ file, args, env: o.env });
    return Promise.resolve({ code: 0, stdout: 'Sat Oct 17 10:23:45 2026\n', stderr: '', timedOut: false });
  };
  assert.equal(await psProcessStart(exec)(123), 'Sat Oct 17 10:23:45 2026');
  assert.deepEqual(calls, [{ file: '/bin/ps', args: ['-o', 'lstart=', '-p', '123'], env: { LC_ALL: 'C', TZ: 'UTC' } }]);
});

test('psProcessStart is null when ps finds no such process, prints nothing, or cannot run', async () => {
  const answer = (code: number | null, stdout: string): Exec => () => Promise.resolve({ code, stdout, stderr: '', timedOut: false });
  assert.equal(await psProcessStart(answer(1, ''))(123), null, 'no such pid');
  assert.equal(await psProcessStart(answer(0, '  \n'))(123), null, 'empty output');
  assert.equal(await psProcessStart(answer(null, 'Sat Oct 17 10:23:45 2026\n'))(123), null, 'killed at the deadline');
  assert.equal(await psProcessStart(() => Promise.reject(new Error('spawn /bin/ps ENOENT')))(123), null, 'no ps');
});

test('psProcessStart on real processes: our own start time is stable, and a pid that is gone has none', async () => {
  const start = psProcessStart();
  const mine = await start(process.pid);
  assert.ok(mine !== null && mine.length > 0, 'ps names our start time');
  assert.equal(await start(process.pid), mine, 'the same text every time');
  const gone = spawnSync(process.execPath, ['-e', '']).pid;
  assert.equal(await start(gone), null);
});

test('readLock reads both formats: a bare pid, and a pid with the start time ps printed', () => {
  const file = path.join(tmpDir('notify-lock'), LOCK_FILE);
  assert.equal(readLock(file), null, 'no file');
  fs.writeFileSync(file, '4242\n');
  assert.deepEqual({ pid: readLock(file)?.pid, started: readLock(file)?.started }, { pid: 4242, started: null });
  fs.writeFileSync(file, '4242 Sat Oct  3 10:23:45 2026\n');
  assert.deepEqual({ pid: readLock(file)?.pid, started: readLock(file)?.started }, { pid: 4242, started: 'Sat Oct  3 10:23:45 2026' });
  for (const junk of ['', 'not a pid\n', '42abc\n', '0\n', '-5\n']) {
    fs.writeFileSync(file, junk);
    assert.equal(readLock(file)?.pid, null, JSON.stringify(junk));
  }
});

// Our parent is alive and is not us.
const OTHER = process.ppid;
const lock = (pid: number | null, started: string | null, mtimeMs = Date.now()): LockContent => ({ raw: '', pid, started, mtimeMs });
const deps = (processStart: LockDeps['processStart'], bootMs = 0): LockDeps => ({ self: { pid: process.pid, started: 'T' }, bootMs, processStart });

test('a live process other than us holds the lock when its start time is the one recorded', async () => {
  assert.equal(await holds(lock(OTHER, 'T1'), deps(() => Promise.resolve('T1'))), true);
});

test('a live pid whose start time is not the recorded one is a reused pid and holds nothing', async () => {
  assert.equal(await holds(lock(OTHER, 'T1'), deps(() => Promise.resolve('T2'))), false);
});

test('when ps cannot name the holder, or the lock has no start time, the age of the lock against the last boot decides', async () => {
  const blind = (): Promise<string | null> => Promise.resolve(null);
  assert.equal(await holds(lock(OTHER, 'T1', Date.now()), deps(blind, Date.now() - 1000)), true, 'written after the boot');
  assert.equal(await holds(lock(OTHER, null, Date.now() - 3_600_000), deps(blind, Date.now() - 1000)), false, 'written before the boot');
});

test('no pid, our own pid and a dead pid hold nothing', async () => {
  const any = (): Promise<string | null> => Promise.resolve('T1');
  assert.equal(await holds(lock(null, null), deps(any)), false);
  assert.equal(await holds(lock(process.pid, 'T'), deps(any)), false);
  const gone = spawnSync(process.execPath, ['-e', '']).pid;
  assert.equal(await holds(lock(gone, 'T1'), deps(any)), false);
});
