// node --test main.test.ts
//
// The bin as launchd would meet it: a real process, from the TypeScript source
// (node strips the types), with no arguments, with a verb that does not exist,
// and with `run`, whose exit code is the contract with the LaunchAgent: it
// respawns the service on anything but 0, so every way the service can end by
// itself, or by SIGTERM, has to end in 0.
import assert from 'node:assert/strict';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { eventsOn, tmpDir } from '@tagents/core';
import { LOCK_FILE, psProcessStart } from '../src/service.ts';

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

const running: ChildProcess[] = [];
after(() => {
  for (const c of running) c.kill('SIGKILL');
});

interface Sandbox {
  readonly state: string;
  readonly lock: string;
  readonly env: NodeJS.ProcessEnv;
}

/**
 * Every place the service touches is a temp dir: nothing of the real state dir,
 * config dir, helper app, home or tmux server is reachable. `backend: log` (or
 * `none`) keeps the notification centre and launchd out of it.
 */
function sandbox(options: string): Sandbox {
  const state = tmpDir('notify-main-state');
  const config = tmpDir('notify-main-cfg');
  fs.mkdirSync(path.join(config, 'plugins'));
  fs.writeFileSync(path.join(config, 'plugins', 'notify.toml'), options);
  return {
    state,
    lock: path.join(state, LOCK_FILE),
    env: {
      PATH: process.env['PATH'] ?? '/usr/bin:/bin',
      HOME: tmpDir('notify-main-home'),
      TA_STATE_DIR: state,
      TAGENTS_CONFIG_DIR: config,
      TA_NOTIFY_APP: path.join(tmpDir('notify-main-app'), 'TagentsNotify.app'),
      TMUX_TMPDIR: tmpDir('notify-main-tmux'),
    },
  };
}

interface Run {
  readonly child: ChildProcess;
  /** Everything the process has written so far, stdout and stderr together. */
  readonly output: () => string;
  readonly exited: Promise<{ readonly code: number | null; readonly signal: NodeJS.Signals | null }>;
}

function runVerb(sb: Sandbox): Run {
  const child = spawn(process.execPath, [MAIN, 'run'], { env: sb.env, stdio: ['ignore', 'pipe', 'pipe'] });
  running.push(child);
  let text = '';
  child.stdout?.on('data', (d: Buffer) => (text += d.toString('utf8')));
  child.stderr?.on('data', (d: Buffer) => (text += d.toString('utf8')));
  const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    child.once('exit', (code, signal) => resolve({ code, signal }));
  });
  return { child, output: () => text, exited };
}

/** Polls every 20 ms, up to 20 s: a process starting under load is slow, a hung one is not waited for forever. */
async function until(what: string, cond: () => boolean): Promise<void> {
  for (let n = 0; n < 1000; n += 1) {
    if (cond()) return;
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
  }
  assert.fail(`timed out waiting for ${what}`);
}

async function exitsWithin(r: Run, ms: number): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<'timeout'>((resolve) => {
    timer = setTimeout(() => resolve('timeout'), ms);
  });
  try {
    const result = await Promise.race([r.exited, timeout]);
    assert.ok(result !== 'timeout', `the process is still running:\n${r.output()}`);
    return result;
  } finally {
    clearTimeout(timer);
  }
}

test('run, with the lock held by a live process of the start time it recorded: exit 0 at once, lock untouched', async () => {
  const sb = sandbox('backend = "log"\n');
  const start = await psProcessStart()(process.pid);
  assert.ok(start !== null, 'ps names our start time');
  const held = `${process.pid} ${start}\n`;
  fs.writeFileSync(sb.lock, held);
  const r = runVerb(sb);
  const end = await exitsWithin(r, 20_000);
  assert.deepEqual(end, { code: 0, signal: null }, r.output());
  assert.match(r.output(), new RegExp(`another notify service holds .*${LOCK_FILE} \\(pid ${process.pid}\\)`));
  assert.equal(fs.readFileSync(sb.lock, 'utf8'), held, 'the lock is not touched');
});

test('run, then SIGTERM: exit 0, and neither the lock nor events.on is left', async () => {
  const sb = sandbox('backend = "log"\n');
  const r = runVerb(sb);
  await until('the service to start', () => r.output().includes('started'));
  assert.ok(fs.existsSync(sb.lock), 'the lock is held while it runs');
  assert.equal(eventsOn(sb.state), true, 'the stream switch is on while it runs');
  r.child.kill('SIGTERM');
  const end = await exitsWithin(r, 20_000);
  assert.deepEqual(end, { code: 0, signal: null }, r.output());
  assert.equal(fs.existsSync(sb.lock), false);
  assert.equal(eventsOn(sb.state), false);
});

test('run with backend none: nothing to post, exit 0, no lock left', async () => {
  const sb = sandbox('backend = "none"\n');
  const r = runVerb(sb);
  const end = await exitsWithin(r, 20_000);
  assert.deepEqual(end, { code: 0, signal: null }, r.output());
  assert.match(r.output(), /backend none: nothing to post; exiting/);
  assert.equal(fs.existsSync(sb.lock), false);
});

// The defaults pick the macOS backend, which the other platforms do not have: there the service leaves at once.
test('run with an invalid options file: it keeps running on the defaults until SIGTERM, then exits 0', { skip: process.platform !== 'darwin' }, async () => {
  const sb = sandbox('events = 7\n');
  const r = runVerb(sb);
  await until('the service to start', () => r.output().includes('started'));
  assert.match(r.output(), /options: /, 'the problem is logged');
  assert.equal(r.child.exitCode, null, 'the service did not leave');
  assert.ok(fs.existsSync(sb.lock));
  r.child.kill('SIGTERM');
  const end = await exitsWithin(r, 20_000);
  assert.deepEqual(end, { code: 0, signal: null }, r.output());
  assert.equal(fs.existsSync(sb.lock), false);
});
