// node --test commands.test.ts
//
// The five verbs through `runPluginBin`, as the bin runs them, against a tmp
// config dir and state dir handed in through `deps.env`: nothing here reads or
// writes the real ones, and nothing patches the process's own environment.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { eventsOn, runPluginBin, setEventsOn, tmpDir } from '@tagents/core';
import type { Exec, ExecResult } from '../src/exec.ts';
import type { Platform, RunSpec, ServiceStatus } from '../src/notifier.ts';
import { ALLOWING_NOTIFICATIONS, createNotifyPlugin } from '../src/plugin.ts';
import { recordingNotifier } from './fakes.ts';

const README = path.join(fileURLToPath(new URL('..', import.meta.url)), 'README.md');
const result = (over: Partial<ExecResult> = {}): ExecResult => ({ code: 0, stdout: '', stderr: '', timedOut: false, ...over });

interface FakeService {
  readonly installed: RunSpec[];
  uninstalls: number;
  status: ServiceStatus;
}

interface RigOptions {
  readonly os?: NodeJS.Platform;
  readonly options?: string;
  /** undefined: the plugin picks its own platform; a function: this one, whatever the backend. */
  readonly platform?: 'real' | Partial<Platform>;
  readonly env?: NodeJS.ProcessEnv;
  readonly exec?: Exec;
  readonly mainJs?: string | null;
  readonly service?: Partial<ServiceStatus>;
}

function rig(o: RigOptions = {}) {
  const config = tmpDir('notify-cmd-cfg');
  const state = tmpDir('notify-cmd-state');
  const home = tmpDir('notify-cmd-home');
  if (o.options !== undefined) {
    fs.mkdirSync(path.join(config, 'plugins'));
    fs.writeFileSync(path.join(config, 'plugins', 'notify.yaml'), o.options);
  }
  const mainJs = path.join(home, 'main.js');
  if (o.mainJs !== null) fs.writeFileSync(o.mainJs ?? mainJs, '');
  const env: NodeJS.ProcessEnv = { TAGENTS_CONFIG_DIR: config, TA_STATE_DIR: state, HOME: home, PATH: '/nonexistent', ...o.env };
  const service: FakeService = {
    installed: [],
    uninstalls: 0,
    status: { installed: true, running: true, pid: 4242, detail: 'loaded, running, pid 4242', ...o.service },
  };
  const fake = (extra: Partial<Platform>): Platform => ({
    name: 'fake',
    notifier: recordingNotifier(),
    service: {
      async install(run) {
        service.installed.push(run);
      },
      async uninstall() {
        service.uninstalls += 1;
      },
      async status() {
        return service.status;
      },
    },
    ...extra,
  });
  const outs: string[] = [];
  const errs: string[] = [];
  const wanted = o.platform;
  const platform = wanted === undefined || typeof wanted === 'string' ? undefined : (): Platform => fake(wanted);
  const plugin = createNotifyPlugin({
    os: o.os ?? 'darwin',
    env,
    home,
    out: (s) => outs.push(s),
    mainJs: o.mainJs === null ? path.join(home, 'missing.js') : (o.mainJs ?? mainJs),
    ...(o.exec !== undefined ? { exec: o.exec } : {}),
    ...(platform !== undefined ? { platform } : {}),
  });
  return {
    config,
    state,
    home,
    env,
    service,
    outs,
    errs,
    out: (): string => outs.join(''),
    err: (): string => errs.join(''),
    run: (...argv: string[]): Promise<number> => runPluginBin(plugin, argv, { out: (s) => outs.push(s), err: (s) => errs.push(s) }),
  };
}

test('install off darwin says there is no backend and exits 2', async () => {
  const r = rig({ os: 'linux' });
  assert.equal(await r.run('install'), 2);
  assert.match(r.err(), /no notification backend for linux yet/);
  assert.equal(r.service.installed.length, 0);
});

test('install refuses without a build, and with the none backend', async () => {
  const unbuilt = rig({ mainJs: null, platform: {} });
  assert.equal(await unbuilt.run('install'), 1);
  assert.match(unbuilt.err(), /run pnpm build first/);
  const none = rig({ options: 'backend: none\n', platform: 'real' });
  assert.equal(await none.run('install'), 1);
  assert.match(none.err(), /backend is none/);
});

test('test --kind question posts through the log backend and says shown', async () => {
  const r = rig({ os: 'linux', options: 'backend: log\n', platform: 'real' });
  assert.equal(await r.run('test', '--kind', 'question'), 0, r.err());
  assert.equal(r.out(), 'shown\n');
  const line = r.errs.find((l) => l.includes('post tagents-s-test question'));
  assert.ok(line !== undefined, r.err());
  assert.match(line, /click=terminal/, 'a synthetic event has no pane to dock');
  assert.match(line, /Which of the two approaches should I take\?/);
});

test('test with a pane takes the event from that pane\'s state row', async () => {
  const row = '1700000000\tdone\tsess-77\t/work/ticket\t\t\n';
  const withPane = rig({ os: 'linux', options: 'backend: log\n', platform: 'real', exec: async () => result({ code: 1 }), env: { TMUX_PANE: '%12' } });
  fs.writeFileSync(path.join(withPane.state, '12.tsv'), row);
  assert.equal(await withPane.run('test'), 0, withPane.err());
  const line = withPane.errs.find((l) => l.includes('post tagents-12 turn_done'));
  assert.ok(line !== undefined, withPane.err());
  assert.match(line, /--act open %12 live sess-77 \/work\/ticket/, 'the click docks that pane');
});

test('test says dropped with the reason and exits 1', async () => {
  const notifier = recordingNotifier();
  notifier.result = { shown: false, why: 'notifications are off' };
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('test', '--kind', 'cache_expiring'), 1);
  assert.equal(r.out(), 'dropped: notifications are off\n');
  assert.equal(notifier.posts[0]?.kind, 'cache_expiring');
});

test('test with an unsupported platform prints the error and exits 1', async () => {
  const r = rig({ os: 'linux', platform: 'real' });
  assert.equal(await r.run('test'), 1);
  assert.match(r.out(), /^error: no notification backend for linux yet/);
});

test('status prints every key and exits 0 when the service runs, the permission is granted and the options are valid', async () => {
  const exec: Exec = async (file) =>
    file === 'ps' ? result({ stdout: '  20480\n' }) : file === '/bin/sh' ? result({ stdout: 'stale\n' }) : result({ code: 1 });
  const r = rig({ exec, env: { TA_NOTIFY_APP: '/tmp/Fake.app' }, platform: { permission: async () => 'authorized' } });
  setEventsOn(true, r.state);
  assert.equal(await r.run('status'), 0, r.out() + r.err());
  const out = r.out();
  for (const key of ['platform', 'backend', 'app', 'permission', 'service', 'stream', 'options']) {
    assert.match(out, new RegExp(`^${key}: `, 'm'), key);
  }
  assert.match(out, /^platform: darwin$/m);
  assert.match(out, /^backend: auto \(resolved to fake\)$/m);
  assert.match(out, /^app: \/tmp\/Fake\.app \(stale\)$/m);
  assert.match(out, /^permission: authorized$/m);
  assert.match(out, /^service: loaded, running, pid 4242, rss 20 MB$/m);
  assert.match(out, /^stream: on$/m);
  assert.match(out, /^options: .*notify\.yaml not found \(defaults\)$/m);
});

test('status exits 1 for a stopped service, a missing permission, a stream that is off, or bad options', async () => {
  const stopped = rig({ platform: { permission: async () => 'authorized' }, service: { running: false, detail: 'installed, not loaded' } });
  assert.equal(await stopped.run('status'), 1);
  assert.match(stopped.out(), /^service: installed, not loaded$/m);
  assert.match(stopped.out(), /^stream: off$/m);

  const denied = rig({ platform: { permission: async () => 'denied' } });
  assert.equal(await denied.run('status'), 1);
  assert.match(denied.out(), /^permission: denied$/m);

  const broken = rig({ platform: { permission: () => Promise.reject(new Error('helper missing')) } });
  assert.equal(await broken.run('status'), 1);
  assert.match(broken.out(), /^permission: unknown: helper missing$/m);

  const invalid = rig({ options: 'events: 7\n', platform: { permission: async () => 'authorized' } });
  assert.equal(await invalid.run('status'), 1);
  assert.match(invalid.out(), /^options: .*notify\.yaml invalid$/m);
  assert.match(invalid.out(), /^ {2}events/m, 'the problem is on a line of its own');
});

test('the install steps are the README\'s, word for word', () => {
  const readme = fs.readFileSync(README, 'utf8');
  const section = readme.slice(readme.indexOf('Allowing notifications:'));
  const steps = [...section.matchAll(/^\d+\. (.+)$/gm)].map((m) => m[1]).slice(0, ALLOWING_NOTIFICATIONS.length);
  assert.deepEqual(steps, [...ALLOWING_NOTIFICATIONS]);
});

function tmuxDir(): string {
  const dir = tmpDir('notify-cmd-bin');
  fs.writeFileSync(path.join(dir, 'tmux'), '#!/bin/sh\n');
  fs.chmodSync(path.join(dir, 'tmux'), 0o755);
  return dir;
}

test('install writes the run spec: node, the built entry, the dirs the service needs and the environment it will not inherit', async () => {
  const bin = tmuxDir();
  const notExecutable = tmpDir('notify-cmd-plain');
  fs.writeFileSync(path.join(notExecutable, 'tmux'), '');
  const r = rig({
    platform: { setup: async () => 'authorized', permission: async () => 'authorized' },
    env: {
      PATH: [notExecutable, bin, '/usr/bin'].join(path.delimiter),
      LC_ALL: 'en_US.UTF-8',
      TMUX_TMPDIR: '',
      TA_NOTIFY_APP: '/tmp/Fake.app',
    },
  });
  assert.equal(await r.run('install'), 0, r.err());
  const spec = r.service.installed[0];
  assert.ok(spec !== undefined);
  assert.equal(spec.program, process.execPath);
  assert.deepEqual(spec.args, [path.join(r.home, 'main.js'), 'run']);
  assert.equal(spec.logFile, path.join(r.home, 'Library', 'Logs', 'tagents', 'notify.log'));
  assert.equal(
    spec.env['PATH'],
    [...new Set([path.dirname(process.execPath), bin, '/usr/bin', '/bin', '/usr/sbin', '/sbin'])].join(path.delimiter),
    'the first executable tmux, not the plain file before it'
  );
  assert.deepEqual(
    { ...spec.env, PATH: '' },
    {
      PATH: '',
      HOME: r.home,
      LANG: 'en_US.UTF-8',
      LC_ALL: 'en_US.UTF-8',
      TA_STATE_DIR: r.state,
      TAGENTS_CONFIG_DIR: r.config,
      TA_NOTIFY_APP: '/tmp/Fake.app',
    },
    'LANG defaults to UTF-8, an empty TMUX_TMPDIR is left out'
  );
  assert.ok(!r.err().includes('no tmux'));
});

test('install without tmux on PATH warns that the service cannot tell what is on screen', async () => {
  const r = rig({ platform: { setup: async () => 'authorized' }, env: { LANG: 'ru_RU.UTF-8' } });
  assert.equal(await r.run('install'), 0);
  assert.match(r.err(), /no tmux on PATH/);
  assert.equal(r.service.installed[0]?.env['LANG'], 'ru_RU.UTF-8');
  assert.ok(!r.service.installed[0]?.env['PATH']?.includes('nonexistent'));
});

test('install ends with the status and the four steps, and puts System Settings first when not authorized', async () => {
  const granted = rig({ platform: { setup: async () => 'authorized', permission: async () => 'authorized' } });
  assert.equal(await granted.run('install'), 0);
  const g = granted.out();
  assert.match(g, /^platform: darwin$/m);
  assert.ok(g.indexOf('1. `tagents notify install`') < g.indexOf('2. If the prompt was missed'));
  for (const step of ALLOWING_NOTIFICATIONS) assert.ok(g.includes(step), step);

  const denied = rig({ platform: { setup: async () => 'denied', permission: async () => 'denied' } });
  assert.equal(await denied.run('install'), 0);
  const d = denied.out();
  assert.match(d, /^permission: denied$/m);
  assert.ok(d.indexOf('1. If the prompt was missed: System Settings') > 0, 'the Settings step is the first of the list');
  assert.ok(d.indexOf('System Settings') < d.indexOf('makes macOS ask'));
});

test('uninstall --purge removes the service, switches the stream off and deletes the app', async () => {
  const app = path.join(tmpDir('notify-cmd-app'), 'TagentsNotify.app');
  fs.mkdirSync(path.join(app, 'Contents'), { recursive: true });
  const r = rig({ platform: {}, env: { TA_NOTIFY_APP: app } });
  setEventsOn(true, r.state);
  assert.equal(await r.run('uninstall', '--purge'), 0, r.err());
  assert.equal(r.service.uninstalls, 1);
  assert.equal(eventsOn(r.state), false);
  assert.equal(fs.existsSync(app), false);
  assert.match(r.out(), /^service: removed$/m);
  assert.match(r.out(), /^stream: off$/m);
  assert.match(r.out(), new RegExp(`^app: removed ${app}$`, 'm'));
});

test('uninstall without --purge keeps the app, and off darwin there is nothing to uninstall', async () => {
  const app = path.join(tmpDir('notify-cmd-app'), 'TagentsNotify.app');
  fs.mkdirSync(app);
  const r = rig({ platform: {}, env: { TA_NOTIFY_APP: app } });
  assert.equal(await r.run('uninstall'), 0);
  assert.equal(fs.existsSync(app), true);
  const linux = rig({ os: 'linux', platform: {} });
  assert.equal(await linux.run('uninstall', '--purge'), 0);
  assert.equal(linux.service.uninstalls, 0);
  assert.match(linux.out(), /nothing to uninstall on linux/);
});

test('uninstall still reaches the service when the backend is none', async () => {
  const r = rig({ options: 'backend: none\n', platform: {} });
  assert.equal(await r.run('uninstall'), 0);
  assert.equal(r.service.uninstalls, 1);
});
