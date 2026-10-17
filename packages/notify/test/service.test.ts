// node --test service.test.ts
//
// The service against a fake feed (or the real one, where the stream switch is
// the point), a tmp state dir and config dir, and a recording notifier. Waiting
// is a bounded loop on something observable, never a fixed sleep.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, test } from 'node:test';
import {
  createAgentFeed,
  createContext,
  definePlugin,
  eventsOn,
  loadPluginOptions,
  tmpDir,
  writeAtomic,
  type AgentFeed,
  type ServiceHandle,
} from '@tagents/core';
import type { Platform } from '../src/notifier.ts';
import { NotifyOptionsSchema } from '../src/options.ts';
import { LOCK_FILE, createNotifyService, type ServiceDeps } from '../src/service.ts';
import { event, fakeClock, fakeFeed, fakeScreen, recordingNotifier } from './fakes.ts';

const started: ServiceHandle[] = [];
after(() => {
  for (const h of started) h.stop('test over');
});

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Polls every 20 ms, up to 3 s, and fails with `what` when the condition never
 * holds. `act` runs on the first pass and every 100 ms after: a file watcher
 * takes a moment to be armed, and a write that lands before it is lost, so the
 * action that should trigger it is repeated until it did. Each action here is
 * idempotent: the same options again is ignored, and a stray extra line is one
 * more notice of the same kind.
 */
async function until(what: string, cond: () => boolean, act?: () => void): Promise<void> {
  for (let n = 0; n <= 150; n += 1) {
    if (n % 5 === 0) act?.();
    if (cond()) return;
    await sleep(20);
  }
  assert.fail(`timed out waiting for ${what}`);
}

async function settledWithin(p: Promise<void> | undefined, ms: number): Promise<boolean> {
  if (p === undefined) return false;
  return Promise.race([p.then(() => true), sleep(ms).then(() => false)]);
}

interface RigOptions {
  /** The text of plugins/notify.yaml; omitted: no file, and no plugins dir either unless `plugins` is set. */
  readonly options?: string;
  readonly plugins?: boolean;
  readonly configDir?: string;
  readonly feed?: (dir: string) => AgentFeed;
  readonly deps?: ServiceDeps;
  /** No platform factory: the service picks its own, from the os and the backend. */
  readonly real?: boolean;
}

function rig(o: RigOptions = {}) {
  const dir = tmpDir('notify-svc-state');
  const configDir = o.configDir ?? tmpDir('notify-svc-cfg');
  const optionsFile = path.join(configDir, 'plugins', 'notify.yaml');
  if (o.options !== undefined || o.plugins === true) fs.mkdirSync(path.dirname(optionsFile), { recursive: true });
  if (o.options !== undefined) fs.writeFileSync(optionsFile, o.options);
  const feed = o.feed?.(dir) ?? fakeFeed(dir);
  const notifier = recordingNotifier();
  const logs: string[] = [];
  const platform: Platform = { name: 'log', notifier, service: null };
  const ctx = createContext({
    plugin: definePlugin({ name: 'notify', apiVersion: 1 }),
    log: (...p) => logs.push(p.join(' ')),
    configDir,
    agents: feed,
  });
  const service = createNotifyService({
    ...(o.real === true ? {} : { platform: () => platform }),
    screen: fakeScreen(),
    clock: fakeClock(),
    hostname: () => 'mbp',
    env: { PATH: '/usr/bin:/bin' },
    bootTime: () => 0,
    ...o.deps,
  });
  return {
    dir,
    configDir,
    optionsFile,
    feed,
    notifier,
    logs,
    lock: path.join(dir, LOCK_FILE),
    has: (text: string): boolean => logs.some((l) => l.includes(text)),
    async start(): Promise<ServiceHandle> {
      const h = await service.start(ctx);
      started.push(h);
      return h;
    },
    /** A Stop, then a question for another pane behind it: when the question posts, the Stop has been dealt with. */
    async stopThenSentinel(): Promise<void> {
      const fake = feed as ReturnType<typeof fakeFeed>;
      const before = notifier.posts.length;
      fake.emit(event());
      fake.emit(event({ event: 'Notification', sub: 'elicitation_dialog', key: '13', pane: '%13', sessionId: 'sess-2', text: '?' }));
      await until('the sentinel question', () => notifier.posts.some((n) => n.kind === 'question') && notifier.posts.length > before);
    },
  };
}

test('a lock held by another live process: the service logs it and is done at once', async () => {
  const r = rig();
  fs.writeFileSync(r.lock, `${process.ppid}\n`);
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500), 'done resolves without anything stopping it');
  assert.ok(r.has(`another notify service holds ${r.lock} (pid ${process.ppid}); exiting`));
  assert.equal((r.feed as ReturnType<typeof fakeFeed>).followers, 0, 'nothing is followed');
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.ppid}\n`, 'the lock is not touched');
});

test('a lock with a dead pid is taken over', async () => {
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { stdio: 'ignore' });
  const gone = new Promise<void>((resolve) => child.once('exit', () => resolve()));
  const pid = child.pid;
  assert.ok(pid !== undefined);
  child.kill('SIGKILL');
  await gone;
  const r = rig();
  fs.writeFileSync(r.lock, `${pid}\n`);
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.pid}\n`);
  assert.ok(r.has('started'));
});

test('a lock from before the last boot is stale even when its pid is alive: the pid may have been reused', async () => {
  const r = rig({ deps: { bootTime: () => Date.now() - 1000 } });
  fs.writeFileSync(r.lock, `${process.ppid}\n`);
  const old = new Date(Date.now() - 3_600_000);
  fs.utimesSync(r.lock, old, old);
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.pid}\n`);
  assert.ok(!r.has('another notify service'));
});

test('an unparseable lock is taken over', async () => {
  const r = rig();
  fs.writeFileSync(r.lock, 'not a pid\n');
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.pid}\n`);
});

test('our lock is removed on stop, and stopping twice is one stop', async () => {
  const r = rig();
  const h = await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.pid}\n`);
  h.stop('SIGTERM');
  assert.ok(await settledWithin(h.done, 500));
  assert.equal(fs.existsSync(r.lock), false);
  h.stop('SIGTERM');
  await h.drain();
  assert.equal(r.logs.filter((l) => l.includes('stopping (')).length, 1);
  assert.ok(r.has('stopping (SIGTERM)'));
});

test('a lock someone else took over survives our stop', async () => {
  const r = rig();
  const h = await r.start();
  fs.writeFileSync(r.lock, `${process.ppid}\n`);
  h.stop('SIGTERM');
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.ppid}\n`);
});

test('an invalid options file: each problem is logged once, and the defaults still post a finished turn', async () => {
  const bad = 'events:\n  turn_done:\n    enabled: nope\nbogus: 1\n';
  const r = rig({ options: bad });
  const checked = loadPluginOptions(r.configDir, 'notify', NotifyOptionsSchema);
  assert.ok(!checked.ok && checked.problems.length >= 2, 'the fixture has at least two problems');
  await r.start();
  for (const p of checked.ok ? [] : checked.problems) {
    assert.equal(r.logs.filter((l) => l.endsWith(`options: ${p}`)).length, 1, p);
  }
  // The same bad file written again, then a good one: the problems are not logged twice.
  // A negative has no event to wait for: the file is rewritten with the same problems, and a short window lets the watcher read it.
  writeAtomic(r.optionsFile, `${bad}\n`);
  await sleep(300);
  await until('the reload', () => r.has('options reloaded'), () => writeAtomic(r.optionsFile, 'click: goto\n'));
  for (const p of checked.ok ? [] : checked.problems) {
    assert.equal(r.logs.filter((l) => l.endsWith(`options: ${p}`)).length, 1, `${p} again`);
  }
});

test('with an invalid options file the defaults run: a Stop posts turn_done', async () => {
  const r = rig({ options: 'events: 7\n' });
  await r.start();
  (r.feed as ReturnType<typeof fakeFeed>).emit(event());
  await until('the notice', () => r.notifier.posts.length === 1);
  assert.equal(r.notifier.posts[0]?.kind, 'turn_done');
});

test('a reload takes effect on the next event: turn_done off posts nothing', async () => {
  const r = rig({ plugins: true });
  await r.start();
  (r.feed as ReturnType<typeof fakeFeed>).emit(event());
  await until('the first notice', () => r.notifier.posts.length === 1);
  await until('the reload', () => r.has('options reloaded'), () =>
    writeAtomic(r.optionsFile, 'events:\n  turn_done:\n    enabled: false\n')
  );
  await r.stopThenSentinel();
  assert.deepEqual(
    r.notifier.posts.map((n) => n.kind),
    ['turn_done', 'question'],
    'the second Stop posted nothing'
  );
});

test('a reload to the value already running is ignored, and a changed backend waits for a restart', async () => {
  const r = rig({ plugins: true });
  await r.start();
  const reloads = (): number => r.logs.filter((l) => l.endsWith('options reloaded')).length;
  await until('the backend line', () => r.has('backend changes take effect after a restart (tagents notify install)'), () =>
    writeAtomic(r.optionsFile, 'backend: log\n')
  );
  assert.equal(reloads(), 1);
  // The same value in other words is no change; the next real change is the second reload.
  await until('the second reload', () => reloads() === 2, () => {
    writeAtomic(r.optionsFile, 'backend: "log"\n');
    writeAtomic(r.optionsFile, 'backend: log\nclick: goto\n');
  });
  assert.equal(reloads(), 2);
});

test('the options directory may appear after the service started', async () => {
  const r = rig();
  await r.start();
  fs.mkdirSync(path.dirname(r.optionsFile), { recursive: true });
  await until('the reload', () => r.has('options reloaded'), () =>
    writeAtomic(r.optionsFile, 'events:\n  turn_done:\n    enabled: false\n')
  );
});

test('with no config dir at all the service runs and says reload is off', async () => {
  const r = rig({ configDir: path.join(tmpDir('notify-svc-none'), 'missing') });
  await r.start();
  assert.ok(r.has('options reload is off'));
  assert.ok(r.has('started'));
});

test('the options watch follows a symlinked config dir to the real one', async () => {
  const real = tmpDir('notify-svc-real');
  const link = path.join(tmpDir('notify-svc-link'), 'tagents');
  fs.symlinkSync(real, link);
  fs.mkdirSync(path.join(real, 'plugins'));
  const r = rig({ configDir: link });
  await r.start();
  await until('the reload', () => r.has('options reloaded'), () =>
    writeAtomic(path.join(real, 'plugins', 'notify.yaml'), 'click: goto\n')
  );
});

test('linux with the auto backend: the service says there is no backend, follows nothing and releases the lock', async () => {
  const r = rig({ real: true, deps: { os: 'linux' } });
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500));
  assert.ok(r.has('no notification backend for linux yet; exiting'));
  assert.equal((r.feed as ReturnType<typeof fakeFeed>).followers, 0);
  assert.equal(fs.existsSync(r.lock), false, 'the lock is released');
});

test('backend none: nothing to post, the service is done and the lock is released', async () => {
  const r = rig({ real: true, options: 'backend: none\n', deps: { os: 'darwin' } });
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500));
  assert.ok(r.has('backend none: nothing to post; exiting'));
  assert.equal((r.feed as ReturnType<typeof fakeFeed>).followers, 0);
  assert.equal(fs.existsSync(r.lock), false);
});

test('the real stream: events.on exists while running and is gone after stop, and a line in events.tsv is a notice', async () => {
  const r = rig({ feed: (dir) => createAgentFeed(dir) });
  const h = await r.start();
  assert.equal(eventsOn(r.dir), true);
  // at event key sessionId agent pane cwd transcript config tool sub text label
  await until('the notice', () => r.notifier.posts.length >= 1, () =>
    fs.appendFileSync(path.join(r.dir, 'events.tsv'), '1760000000\tStop\t12\tsess-1\t\t%12\t/tmp/x\t\t\t\t\t\t\n')
  );
  assert.equal(r.notifier.posts[0]?.kind, 'turn_done');
  assert.equal(r.notifier.posts[0]?.thread, 'sess-1');
  h.stop('SIGTERM');
  assert.equal(eventsOn(r.dir), false);
});
