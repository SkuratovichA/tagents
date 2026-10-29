// node --test service.test.ts
//
// The service against a fake feed (or the real one, where the stream switch is
// the point), a tmp state dir and config dir, and a recording notifier. Waiting
// is a bounded loop on something observable, never a fixed sleep.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, mock, test } from 'node:test';
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
import type { Exec } from '../src/exec.ts';
import type { Platform } from '../src/notifier.ts';
import { NotifyOptionsSchema } from '../src/options.ts';
import {
  LOCK_FILE,
  createNotifyService,
  psProcessStart,
  readLock,
  takeLock,
  type LockDeps,
  type ServiceDeps,
} from '../src/service.ts';
import { event, fakeClock, fakeFeed, fakeScreen, recordingNotifier, type FakeFeed } from './fakes.ts';

const started: ServiceHandle[] = [];
after(() => {
  for (const h of started) h.stop('test over');
});

/** What a fake process's start time reads: one per pid, so a reused pid is a pid whose start time is another. */
const startOf = (pid: number): Promise<string | null> => Promise.resolve(`T${pid}`);
/** The lock file a process with that pid (and, by default, its fake start time) writes. */
const lockOf = (pid: number, started: string = `T${pid}`): string => `${pid} ${started}\n`;

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

interface RigOptions<F extends AgentFeed> {
  /** The text of plugins/notify.yaml; omitted: no file, and no plugins dir either unless `plugins` is set. */
  readonly options?: string;
  readonly plugins?: boolean;
  readonly configDir?: string;
  readonly feed?: (dir: string) => F;
  readonly deps?: ServiceDeps;
  /** No platform factory: the service picks its own, from the os and the backend. */
  readonly real?: boolean;
}

/** The feed is the fake one unless the test brings its own: then it is whatever that test's factory returns. */
function rig<F extends AgentFeed = FakeFeed>(o: RigOptions<F> = {}) {
  const dir = tmpDir('notify-svc-state');
  const configDir = o.configDir ?? tmpDir('notify-svc-cfg');
  const optionsFile = path.join(configDir, 'plugins', 'notify.yaml');
  if (o.options !== undefined || o.plugins === true) fs.mkdirSync(path.dirname(optionsFile), { recursive: true });
  if (o.options !== undefined) fs.writeFileSync(optionsFile, o.options);
  const feed: F | FakeFeed = o.feed?.(dir) ?? fakeFeed(dir);
  const notifier = recordingNotifier();
  // A post that has begun but not finished is in flight: the drain tests need to know when that is.
  let postsBegun = 0;
  const post = notifier.post.bind(notifier);
  notifier.post = (notice) => {
    postsBegun += 1;
    return post(notice);
  };
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
    processStart: startOf,
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
    postsBegun: (): number => postsBegun,
    has: (text: string): boolean => logs.some((l) => l.includes(text)),
    async start(): Promise<ServiceHandle> {
      const h = await service.start(ctx);
      started.push(h);
      return h;
    },
  };
}

type FakeRig = ReturnType<typeof rig<FakeFeed>>;

/** A Stop, then a question for another pane behind it: when the question posts, the Stop has been dealt with. */
async function stopThenSentinel(r: FakeRig): Promise<void> {
  const before = r.notifier.posts.length;
  r.feed.emit(event());
  r.feed.emit(event({ event: 'Notification', sub: 'elicitation_dialog', key: '13', pane: '%13', sessionId: 'sess-2', text: '?' }));
  await until('the sentinel question', () => r.notifier.posts.some((n) => n.kind === 'question') && r.notifier.posts.length > before);
}

test('a lock held by another live process: the service logs it and is done at once', async () => {
  const r = rig();
  fs.writeFileSync(r.lock, lockOf(process.ppid));
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500), 'done resolves without anything stopping it');
  assert.ok(r.has(`another notify service holds ${r.lock} (pid ${process.ppid}); exiting`));
  assert.equal(r.feed.followers, 0, 'nothing is followed');
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.ppid), 'the lock is not touched');
});

test('a lock written in the old format, a bare pid, is still read: a live pid holds it', async () => {
  const r = rig();
  fs.writeFileSync(r.lock, `${process.ppid}\n`);
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500));
  assert.ok(r.has(`another notify service holds ${r.lock} (pid ${process.ppid}); exiting`));
  assert.equal(fs.readFileSync(r.lock, 'utf8'), `${process.ppid}\n`, 'the lock is not touched');
});

test('a live pid whose start time is not the one the lock recorded is a reused pid: the lock is taken over', async () => {
  const r = rig();
  fs.writeFileSync(r.lock, lockOf(process.ppid, 'Mon Jan  1 00:00:00 2024'));
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.pid));
  assert.ok(!r.has('another notify service'));
  assert.ok(r.has('started'));
});

test('when ps cannot name the holder, the age of the lock decides, as it did before start times', async () => {
  const blind = (pid: number): Promise<string | null> => (pid === process.ppid ? Promise.resolve(null) : startOf(pid));
  const fresh = rig({ deps: { processStart: blind } });
  fs.writeFileSync(fresh.lock, lockOf(process.ppid, 'whatever'));
  const held = await fresh.start();
  assert.ok(await settledWithin(held.done, 500));
  assert.ok(fresh.has(`another notify service holds ${fresh.lock}`));

  const old = rig({ deps: { processStart: blind, bootTime: () => Date.now() - 1000 } });
  fs.writeFileSync(old.lock, lockOf(process.ppid, 'whatever'));
  const before = new Date(Date.now() - 3_600_000);
  fs.utimesSync(old.lock, before, before);
  await old.start();
  assert.equal(fs.readFileSync(old.lock, 'utf8'), lockOf(process.pid));
});

test('the lock names our pid and our start time, and ps is asked only for the lock, never per event', async () => {
  const asked: number[] = [];
  const r = rig({
    deps: {
      processStart: (pid) => {
        asked.push(pid);
        return startOf(pid);
      },
    },
  });
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.pid));
  assert.deepEqual(asked, [process.pid], 'a free lock needs only our own start time');
  await stopThenSentinel(r);
  assert.deepEqual(asked, [process.pid], 'events asked ps nothing');
});

test('a lock with a dead pid is taken over', async () => {
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { stdio: 'ignore' });
  const gone = new Promise<void>((resolve) => child.once('exit', () => resolve()));
  const pid = child.pid;
  assert.ok(pid !== undefined);
  child.kill('SIGKILL');
  await gone;
  const r = rig();
  fs.writeFileSync(r.lock, lockOf(pid));
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.pid));
  assert.ok(r.has('started'));
});

test('an old-format lock from before the last boot is stale even when its pid is alive: the pid may have been reused', async () => {
  const r = rig({ deps: { bootTime: () => Date.now() - 1000 } });
  fs.writeFileSync(r.lock, `${process.ppid}\n`);
  const old = new Date(Date.now() - 3_600_000);
  fs.utimesSync(r.lock, old, old);
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.pid));
  assert.ok(!r.has('another notify service'));
});

test('an unparseable lock is taken over', async () => {
  const r = rig();
  fs.writeFileSync(r.lock, 'not a pid\n');
  await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.pid));
});

test('our lock is removed on stop, and stopping twice is one stop', async () => {
  const r = rig();
  const h = await r.start();
  assert.equal(fs.readFileSync(r.lock, 'utf8'), lockOf(process.pid));
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

test('an invalid options file: each problem is logged once however often it is read, and the defaults still post a finished turn', async () => {
  const bad = 'events:\n  turn_done:\n    enabled: nope\nbogus: 1\n';
  // A second invalid file whose problems are not the first one's.
  const worse = 'events: 7\nclick: nope\n';
  const problemsOf = (text: string): readonly string[] => {
    const dir = tmpDir('notify-svc-probe');
    fs.mkdirSync(path.join(dir, 'plugins'));
    fs.writeFileSync(path.join(dir, 'plugins', 'notify.yaml'), text);
    const checked = loadPluginOptions(dir, 'notify', NotifyOptionsSchema);
    return checked.ok ? [] : checked.problems;
  };
  const badProblems = problemsOf(bad);
  const worseProblems = problemsOf(worse);
  assert.ok(badProblems.length >= 2 && worseProblems.length >= 2, 'both fixtures have at least two problems');
  assert.ok(badProblems.every((p) => !worseProblems.includes(p)), 'and no problem in common');

  const r = rig({ options: bad });
  // The watcher's own listener, kept: each read below is made by the test, right after its write, so
  // nothing depends on when the OS delivers an event, and every file is read before the next is written.
  const real = fs.watch;
  let changed: (() => void) | undefined;
  mock.method(fs, 'watch', (target: fs.PathLike, options: fs.WatchOptions & { encoding?: BufferEncoding }, listener: fs.WatchListener<string>) => {
    if (String(target) === fs.realpathSync(path.dirname(r.optionsFile))) changed = () => listener('change', path.basename(r.optionsFile));
    return real(target, options, listener);
  });
  try {
    await r.start();
  } finally {
    mock.restoreAll();
  }
  assert.ok(changed !== undefined, 'the options watch was armed');
  const read = (text: string): void => {
    writeAtomic(r.optionsFile, text);
    changed?.();
  };
  const logged = (problem: string): number => r.logs.filter((l) => l.endsWith(`options: ${problem}`)).length;
  const counts = (): number[] => [...badProblems, ...worseProblems].map(logged);
  const onceEach = (bads: number, worses: number): number[] => [...badProblems.map(() => bads), ...worseProblems.map(() => worses)];

  assert.deepEqual(counts(), onceEach(1, 0), 'the file the service started with: each problem once');
  read(`${bad}\n`);
  assert.deepEqual(counts(), onceEach(1, 0), 'the same problems read again: nothing new');
  read(worse);
  assert.deepEqual(counts(), onceEach(1, 1), 'other problems are news, once each');
  read(`${worse}\n`);
  assert.deepEqual(counts(), onceEach(1, 1), 'and not news twice');
  // The sentinel: a valid change, which is a reload.
  read('click: goto\n');
  assert.equal(r.logs.filter((l) => l.endsWith('options reloaded')).length, 1);
  assert.deepEqual(counts(), onceEach(1, 1));
});

test('with an invalid options file the defaults run: a Stop posts turn_done', async () => {
  const r = rig({ options: 'events: 7\n' });
  await r.start();
  r.feed.emit(event());
  await until('the notice', () => r.notifier.posts.length === 1);
  assert.equal(r.notifier.posts[0]?.kind, 'turn_done');
});

test('a reload takes effect on the next event: turn_done off posts nothing', async () => {
  const r = rig({ plugins: true });
  await r.start();
  r.feed.emit(event());
  await until('the first notice', () => r.notifier.posts.length === 1);
  await until('the reload', () => r.has('options reloaded'), () =>
    writeAtomic(r.optionsFile, 'events:\n  turn_done:\n    enabled: false\n')
  );
  await stopThenSentinel(r);
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
  const dir = path.dirname(r.optionsFile);
  // The OS starts the watch on the parent after fs.watch has returned, and a directory made before that raises
  // no event, however the service looks: so the directory is made again, with its file, until one is seen.
  await until('the reload', () => r.has('options reloaded'), () => {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });
    writeAtomic(r.optionsFile, 'events:\n  turn_done:\n    enabled: false\n');
  });
});

test('a directory created after the first look and before the watch on its parent is armed is found by the look after the arming', async () => {
  const r = rig();
  const parent = fs.realpathSync(r.configDir);
  const plugins = path.join(parent, 'plugins');
  const real = fs.watch;
  const watched: string[] = [];
  let parentListener: fs.WatchListener<string> | undefined;
  mock.method(fs, 'watch', (target: fs.PathLike, options: fs.WatchOptions & { encoding?: BufferEncoding }, listener: fs.WatchListener<string>) => {
    watched.push(String(target));
    if (String(target) === parent) {
      // The gap: the directory and its file appear before this watch exists, so no event will ever announce them.
      fs.mkdirSync(plugins);
      fs.writeFileSync(r.optionsFile, 'events:\n  turn_done:\n    enabled: false\n');
      parentListener = listener;
    }
    return real(target, options, listener);
  });
  try {
    await r.start();
    // The event the gap swallowed, arriving after all (twice, as a rename and a change do): nothing is set up again.
    parentListener?.('rename', 'plugins');
    parentListener?.('change', 'plugins');
  } finally {
    mock.restoreAll();
  }
  assert.ok(r.has('options reloaded'), 'the file that came with the directory is read');
  assert.deepEqual(watched.filter((w) => w === plugins), [plugins], 'the directory is watched once');
  await until('a change in the adopted directory', () => r.logs.filter((l) => l.endsWith('options reloaded')).length === 2, () =>
    writeAtomic(r.optionsFile, 'click: goto\n')
  );
});

test('a file that changes between the first read and the arming of the watch on its directory is read once more', async () => {
  const first = 'events:\n  turn_done:\n    enabled: true\n';
  // `during` is written into the options file just before the watch on the plugins directory is armed.
  async function startWith(during: string): Promise<FakeRig> {
    const r = rig({ options: first });
    const real = fs.watch;
    mock.method(fs, 'watch', (target: fs.PathLike, options: fs.WatchOptions & { encoding?: BufferEncoding }, listener: fs.WatchListener<string>) => {
      if (String(target) === fs.realpathSync(path.dirname(r.optionsFile))) fs.writeFileSync(r.optionsFile, during);
      return real(target, options, listener);
    });
    try {
      await r.start();
    } finally {
      mock.restoreAll();
    }
    return r;
  }
  const reloads = (r: FakeRig): number => r.logs.filter((l) => l.endsWith('options reloaded')).length;
  const changed = await startWith('events:\n  turn_done:\n    enabled: false\n');
  assert.equal(reloads(changed), 1, 'the change the watch could not see is applied, once');
  const unchanged = await startWith(first);
  assert.equal(reloads(unchanged), 0, 'the same file read again is no reload');
});

test('with no config dir at all the service runs and says reload is off', async () => {
  const r = rig({ configDir: path.join(tmpDir('notify-svc-none'), 'missing') });
  await r.start();
  assert.ok(r.has('options reload is off'));
  assert.ok(r.has('started'));
  const at = (text: string): number => r.logs.findIndex((l) => l.includes(text));
  assert.ok(at('options reload is off') < at('started'), 'started is said last: a caller that waits for it may signal at once');
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

test('the options may move to notify.toml while the service runs: that file is reloaded too, and wins over notify.yaml', async () => {
  const r = rig({ options: 'click: goto\n' });
  await r.start();
  await until('the reload', () => r.has('options reloaded'), () =>
    writeAtomic(path.join(path.dirname(r.optionsFile), 'notify.toml'), '[events.turn_done]\nenabled = false\n')
  );
  await stopThenSentinel(r);
  assert.deepEqual(
    r.notifier.posts.map((n) => n.kind),
    ['question'],
    'the toml turned turn_done off, the yaml beside it left it on: the Stop posted nothing'
  );
});

test('a symlinked notify.toml is noticed when the link is replaced, not when its target is edited', async () => {
  const r = rig({ plugins: true });
  const optionsDir = path.dirname(r.optionsFile);
  const away = tmpDir('notify-svc-target');
  const target = path.join(away, 'options.toml');
  const link = path.join(optionsDir, 'notify.toml');
  fs.writeFileSync(target, 'click = "goto"\n');
  fs.symlinkSync(target, link);
  await r.start();
  const reloads = (): number => r.logs.filter((l) => l.endsWith('options reloaded')).length;
  const kinds = (): string[] => r.notifier.posts.map((n) => n.kind);
  const turnDoneOff = '[events.turn_done]\nenabled = false\n';

  // The directory that is watched holds the link, not the target: this edit raises no event there.
  fs.writeFileSync(target, turnDoneOff);
  fs.writeFileSync(path.join(optionsDir, 'unrelated.toml'), '');
  await stopThenSentinel(r);
  assert.equal(reloads(), 0, 'the edit of the target is not a reload');
  assert.deepEqual(kinds(), ['turn_done', 'question'], 'the old values are in force: the Stop still posts');

  // Replacing the link is a rename in the watched directory.
  const next = path.join(away, 'next.toml');
  fs.writeFileSync(next, turnDoneOff);
  let n = 0;
  await until('the reload', () => reloads() === 1, () => {
    n += 1;
    const fresh = path.join(optionsDir, `notify.toml.${n}`);
    fs.symlinkSync(next, fresh);
    fs.renameSync(fresh, link);
  });
  await stopThenSentinel(r);
  assert.deepEqual(kinds(), ['turn_done', 'question', 'question'], 'the new values apply: the second Stop posted nothing');
});

test('linux with the auto backend: the service says there is no backend, follows nothing and releases the lock', async () => {
  const r = rig({ real: true, deps: { os: 'linux' } });
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500));
  assert.ok(r.has('no notification backend for linux yet; exiting'));
  assert.equal(r.feed.followers, 0);
  assert.equal(fs.existsSync(r.lock), false, 'the lock is released');
});

test('backend none: nothing to post, the service is done and the lock is released', async () => {
  const r = rig({ real: true, options: 'backend: none\n', deps: { os: 'darwin' } });
  const h = await r.start();
  assert.ok(await settledWithin(h.done, 500));
  assert.ok(r.has('backend none: nothing to post; exiting'));
  assert.equal(r.feed.followers, 0);
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

test('stopping while a post is in flight: done waits for the post, the stream is off at once, and the lock goes last', async () => {
  const r = rig({ feed: (dir) => createAgentFeed(dir) });
  const h = await r.start();
  const held = r.notifier.hold();
  await until('the post in flight', () => r.postsBegun() >= 1, () =>
    fs.appendFileSync(path.join(r.dir, 'events.tsv'), '1760000000\tStop\t12\tsess-1\t\t%12\t/tmp/x\t\t\t\t\t\t\n')
  );
  let over = false;
  void h.done?.then(() => {
    over = true;
  });
  h.stop('SIGTERM');
  assert.equal(eventsOn(r.dir), false, 'no new events are taken while the last post finishes');
  // Let everything that can settle on its own settle: the post cannot, so nothing may have finished.
  for (let n = 0; n < 5; n += 1) await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(over, false, 'done waits for the post');
  assert.equal(fs.existsSync(r.lock), true, 'the lock is kept while the post is out');
  held.release();
  assert.ok(await settledWithin(h.done, 2000), 'done resolves once the post has settled');
  assert.ok(r.notifier.posts.length >= 1, 'the post landed');
  assert.equal(fs.existsSync(r.lock), false);
  assert.equal(eventsOn(r.dir), false);
});

test('drain() resolves only after the post in flight has settled, and leaves no lock behind', async () => {
  const r = rig();
  const h = await r.start();
  const held = r.notifier.hold();
  r.feed.emit(event());
  await until('the post in flight', () => r.postsBegun() === 1);
  let drained = false;
  const draining = h.drain().then(() => {
    drained = true;
  });
  for (let n = 0; n < 5; n += 1) await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(drained, false, 'drain waits for the post');
  assert.equal(fs.existsSync(r.lock), true);
  held.release();
  await draining;
  assert.equal(r.notifier.posts.length, 1, 'the post landed');
  assert.equal(fs.existsSync(r.lock), false);
  assert.ok(await settledWithin(h.done, 500));
});

test('a stream that will not close: the failure is logged, and the lock is still released and done still resolves', async () => {
  const r = rig({
    feed: (dir) => {
      const feed = fakeFeed(dir);
      const follow = feed.follow.bind(feed);
      feed.follow = (onEvent, onError, onDead) => {
        const follower = follow(onEvent, onError, onDead);
        return {
          close() {
            follower.close();
            throw new Error('the watch would not close');
          },
        };
      };
      return feed;
    },
  });
  const h = await r.start();
  h.stop('SIGTERM');
  assert.ok(await settledWithin(h.done, 2000), 'done resolves although the cleanup failed');
  assert.ok(r.has('drain failed') && r.has('the watch would not close'), 'the error is logged');
  assert.equal(fs.existsSync(r.lock), false, 'the lock is released');
});

test('a lock that cannot be removed: the failure is logged, done still resolves, and the lock is left as it was', async () => {
  const r = rig();
  const h = await r.start();
  const real = fs.rmSync;
  mock.method(fs, 'rmSync', (target: fs.PathLike, options?: fs.RmOptions) => {
    if (String(target) === r.lock) throw Object.assign(new Error(`EACCES: permission denied, unlink '${r.lock}'`), { code: 'EACCES' });
    real(target, options);
  });
  try {
    h.stop('SIGTERM');
    assert.ok(await settledWithin(h.done, 2000), 'done resolves although the lock stays');
  } finally {
    mock.restoreAll();
  }
  assert.ok(r.has('could not release the lock') && r.has('EACCES'), 'the failure is logged');
  assert.equal(fs.existsSync(r.lock), true);
});

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

// Pid 1 always exists, and kill(1, 0) answers EPERM for it, which isAlive counts as alive: a live process that is not us.
const INIT = 1;

function holder(pid: number, processStart: LockDeps['processStart'] = startOf): LockDeps {
  return { self: { pid, started: `T${pid}` }, bootMs: 0, processStart };
}

function staleLock(): { dir: string; file: string } {
  const dir = tmpDir('notify-lock');
  const file = path.join(dir, LOCK_FILE);
  // Our parent is alive, but this lock recorded another start time for its pid: the pid was reused.
  fs.writeFileSync(file, lockOf(process.ppid, 'before the reboot'));
  return { dir, file };
}

test('taking the lock sweeps the temp files a crash left behind: a dead pid, or older than a minute, and nothing else', async () => {
  const dir = tmpDir('notify-lock');
  const file = path.join(dir, LOCK_FILE);
  const gone = spawnSync(process.execPath, ['-e', '']).pid;
  const make = (name: string, ageMs = 0): string => {
    fs.writeFileSync(path.join(dir, name), 'x');
    if (ageMs > 0) {
      const then = new Date(Date.now() - ageMs);
      fs.utimesSync(path.join(dir, name), then, then);
    }
    return name;
  };
  make(`${LOCK_FILE}.${gone}.0a1b2c3d.tmp`);
  make(`${LOCK_FILE}.${process.pid}.0a1b2c3e.tmp`, 120_000);
  const fresh = make(`${LOCK_FILE}.${process.pid}.0a1b2c3f.tmp`);
  const events = make('events.tsv');
  const lookalike = make(`${LOCK_FILE}.${gone}.tmp`);
  assert.deepEqual(await takeLock(file, holder(process.pid)), { taken: true });
  assert.deepEqual(fs.readdirSync(dir).sort(), [LOCK_FILE, fresh, events, lookalike].sort());
});

test('two takeovers racing over one stale lock end with exactly one holder', async () => {
  const { dir, file } = staleLock();
  const a = holder(INIT);
  const b = holder(process.pid);
  // Both read the stale lock, both wait on ps, both go on to remove it: the one that is late must find the new lock.
  const [ra, rb] = await Promise.all([takeLock(file, a), takeLock(file, b)]);
  assert.equal([ra, rb].filter((r) => r.taken).length, 1, JSON.stringify([ra, rb]));
  const [winner, loser] = ra.taken ? [a, rb] : [b, ra];
  assert.deepEqual(loser, { taken: false, holder: winner.self.pid });
  assert.equal(fs.readFileSync(file, 'utf8'), lockOf(winner.self.pid), 'the file names the winner');
  assert.deepEqual(fs.readdirSync(dir), [LOCK_FILE], 'no temp file is left behind');
});

test('a takeover that judged the lock stale does not remove the lock somebody else put there since', async () => {
  const { file } = staleLock();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const slow: LockDeps['processStart'] = (pid) => (pid === process.ppid ? gate.then(() => startOf(pid)) : startOf(pid));
  const late = takeLock(file, holder(process.pid, slow));
  // While the late one is still asking ps about the old holder, another takeover completes.
  assert.deepEqual(await takeLock(file, holder(INIT)), { taken: true });
  release();
  assert.deepEqual(await late, { taken: false, holder: INIT });
  assert.equal(fs.readFileSync(file, 'utf8'), lockOf(INIT), 'the new holder keeps its lock');
});

test('the lock is linked into place from a finished file: it is never visible empty', async () => {
  const dir = tmpDir('notify-lock');
  const file = path.join(dir, LOCK_FILE);
  const real = fs.linkSync;
  const links: { src: string; dst: string; text: string }[] = [];
  mock.method(fs, 'linkSync', (src: fs.PathLike, dst: fs.PathLike) => {
    links.push({ src: String(src), dst: String(dst), text: fs.readFileSync(src, 'utf8') });
    real(src, dst);
  });
  try {
    assert.deepEqual(await takeLock(file, holder(process.pid)), { taken: true });
  } finally {
    mock.restoreAll();
  }
  assert.equal(links.length, 1);
  assert.equal(links[0]?.dst, file);
  assert.notEqual(links[0]?.src, file, 'the source is another file in the same directory');
  assert.equal(path.dirname(links[0]?.src ?? ''), dir);
  assert.equal(links[0]?.text, lockOf(process.pid), 'complete at the moment it appeared');
  assert.deepEqual(fs.readdirSync(dir), [LOCK_FILE], 'the temp file is gone');
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
