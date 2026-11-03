// The options of the fake `claude` that a turn's parity scenarios lean on: each does what its name says, on a real process and its real pipes.
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { fakeClaude, tmpDir, type FakeScript } from '../src/testkit.ts';

let tmp: string;
before(() => {
  tmp = tmpDir('fake-claude-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/** A real `claude` process of this script, with its pipes, and how it left once it has. */
interface Run {
  readonly child: ChildProcess;
  readonly exited: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  readonly closed: Promise<void>;
  readonly stdout: () => string;
}

function start(script: FakeScript): Run {
  const fake = fakeClaude(script, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const child = spawn(fake.bin, [], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout?.on('data', (d: Buffer) => {
    out += d.toString();
  });
  return {
    child,
    exited: new Promise((resolve) => child.once('exit', (code, signal) => resolve({ code, signal }))),
    closed: new Promise((resolve) => child.once('close', () => resolve())),
    stdout: () => out,
  };
}

test('pidFile holds the pid of the process', async () => {
  const pidFile = path.join(tmp, 'pid');
  const run = start({ pidFile, result: { text: 'r' } });
  await run.closed;
  assert.equal(fs.readFileSync(pidFile, 'utf8'), String(run.child.pid));
});

test('killSelf ends the process by that signal, after what its script printed', async () => {
  const run = start({ killSelf: 'SIGTERM', exitCode: 3, result: { text: 'the last line' } });
  assert.deepEqual(await run.exited, { code: null, signal: 'SIGTERM' });
  await run.closed;
  assert.match(run.stdout(), /"result":"the last line"/);
});

test('grandchildMs leaves a process holding stdout after the exit', async () => {
  // The sleep starts just before the exit, so its pipe outlives the exit by the sleep's length. The look at the pipe comes well before that.
  const run = start({ grandchildMs: 3000, result: { text: 'r' } });
  assert.deepEqual(await run.exited, { code: 0, signal: null });
  await sleep(300);
  assert.equal(run.child.stdout?.readableEnded, false, 'the pipe is still open after the process left');
  await run.closed;
  assert.equal(run.child.stdout?.readableEnded, true);
});

test('without grandchildMs the pipe ends with the process', async () => {
  const run = start({ result: { text: 'r' } });
  await run.exited;
  await run.closed;
  assert.equal(run.child.stdout?.readableEnded, true);
});
