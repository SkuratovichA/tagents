// Holding the machine awake under a turn: `caffeinate -i -w <pid>` on macOS,
// switched off by TA_KEEP_AWAKE=0, and never a reason for a turn to fail. The
// timing half of the 01.10.2026 fix (awake time, not wall time) is in
// lifecycle.test.ts.
import assert from 'node:assert/strict';
import { ChildProcess, spawn, type SpawnOptions } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { ClaudeHeadlessDriver } from '../src/claude-driver.ts';
import { holdAwake, KEEP_AWAKE_ENV, keepAwakeWanted, type KeepAwake } from '../src/keep-awake.ts';
import { drained, fakeClaude, sleep, tmpDir } from '../src/testkit.ts';

let tmp: string;
before(() => {
  tmp = tmpDir('keep-awake-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/** A child that was never started and counts the kills it is sent. */
class FakeChild extends ChildProcess {
  kills = 0;
  override kill(): boolean {
    this.kills++;
    return true;
  }

  /** Its handle was never spawned: leave it alone. */
  override unref(): void {}
}

const failedLine = (why: string): string => `keep-awake: caffeinate failed (${why}) — the turn runs without it`;

test('wanted on macOS only, and TA_KEEP_AWAKE=0 turns it off', () => {
  assert.equal(keepAwakeWanted('darwin', {}), true);
  assert.equal(keepAwakeWanted('darwin', { [KEEP_AWAKE_ENV]: '1' }), true);
  assert.equal(keepAwakeWanted('darwin', { [KEEP_AWAKE_ENV]: '0' }), false);
  assert.equal(keepAwakeWanted('linux', {}), false);
});

test('holdAwake runs `caffeinate -i -w <pid>` with no stdio, and the release kills it', () => {
  const calls: Array<{ command: string; args: readonly string[]; options: SpawnOptions }> = [];
  const child = new FakeChild();
  const log: string[] = [];
  const release = holdAwake(4242, (l) => log.push(l), (command, args, options) => {
    calls.push({ command, args, options });
    return child;
  });
  assert.deepEqual(calls, [{ command: 'caffeinate', args: ['-i', '-w', '4242'], options: { stdio: 'ignore' } }]);
  assert.equal(child.kills, 0, 'held until released');
  release();
  assert.equal(child.kills, 1);
  assert.deepEqual(log, [], 'a hold that works says nothing');
});

test('a spawn that throws is one log line and a release that does nothing', () => {
  const log: string[] = [];
  const release = holdAwake(1, (l) => log.push(l), () => {
    throw new Error('spawn EAGAIN');
  });
  assert.doesNotThrow(release);
  assert.deepEqual(log, [failedLine('spawn EAGAIN')]);
});

test('a missing binary is one log line, not a throw', async () => {
  const missing = path.join(tmp, 'no-such-caffeinate');
  const log: string[] = [];
  const release = holdAwake(process.pid, (l) => log.push(l), (_command, args, options) => spawn(missing, args, options));
  await drained(() => log.length > 0, { what: 'the spawn error' });
  assert.deepEqual(log, [failedLine(`spawn ${missing} ENOENT`)]);
  assert.doesNotThrow(release);
});

test('the driver holds the machine awake for the child it spawned, and lets go when the turn ends', async () => {
  const held: number[] = [];
  let released = 0;
  const keepAwake: KeepAwake = (pid) => {
    held.push(pid);
    return () => {
      released++;
    };
  };
  const bin = fakeClaude({ result: { text: 'done' } }, fs.mkdtempSync(path.join(tmp, 'fake-'))).bin;
  const d = new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state'), keepAwake });
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin });
  const o = await d.prompt(ref, 'go', { timeoutMs: 60 * 1000 });
  assert.equal(o.kind, 'ok');
  assert.equal(held.length, 1);
  assert.ok((held[0] ?? 0) > 0 && held[0] !== process.pid, `the child's pid, got ${held[0]}`);
  assert.equal(released, 1, 'released exactly once, with the turn');
});

test('a keep-awake that fails leaves the turn a success with one line in its log', async () => {
  const keepAwake: KeepAwake = (pid, log) =>
    holdAwake(pid, log, () => {
      throw new Error('spawn ENOENT');
    });
  const bin = fakeClaude({ result: { text: 'done' } }, fs.mkdtempSync(path.join(tmp, 'fake-'))).bin;
  const lines: string[] = [];
  const d = new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state'), keepAwake });
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin });
  const o = await d.prompt(ref, 'go', { timeoutMs: 60 * 1000, log: (l) => lines.push(l) });
  assert.equal(o.kind, 'ok');
  assert.deepEqual(lines, [failedLine('spawn ENOENT')]);
});

test('keepAwake: null turns it off', async () => {
  const bin = fakeClaude({ result: { text: 'done' } }, fs.mkdtempSync(path.join(tmp, 'fake-'))).bin;
  const lines: string[] = [];
  const d = new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state'), keepAwake: null });
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin });
  const o = await d.prompt(ref, 'go', { timeoutMs: 60 * 1000, log: (l) => lines.push(l) });
  assert.equal(o.kind, 'ok');
  assert.deepEqual(lines, []);
});

test('a real caffeinate holds while the watched process lives and leaves on its own after it', { skip: process.platform !== 'darwin' && 'caffeinate is macOS-only' }, async () => {
  const watched = spawn('sleep', ['30'], { stdio: 'ignore' });
  const kids: ChildProcess[] = [];
  const log: string[] = [];
  try {
    assert.ok(watched.pid !== undefined);
    holdAwake(watched.pid, (l) => log.push(l), (command, args, options) => {
      const c = spawn(command, args, options);
      kids.push(c);
      return c;
    });
    const caffeinate = kids[0];
    assert.ok(caffeinate);
    await sleep(200);
    assert.equal(caffeinate.exitCode, null, 'it holds while the watched process lives');
    watched.kill();
    await drained(() => caffeinate.exitCode !== null || caffeinate.signalCode !== null, { what: 'caffeinate to leave' });
    assert.deepEqual(log, []);
  } finally {
    watched.kill();
    for (const k of kids) k.kill();
  }
});
