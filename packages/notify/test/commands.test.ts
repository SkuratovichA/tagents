// node --test commands.test.ts
//
// The five verbs through `runPluginBin`, as the bin runs them, against a tmp
// config dir and state dir handed in through `deps.env`: nothing here reads or
// writes the real ones, and nothing patches the process's own environment.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createAgentFeed, createContext, eventsOn, runPluginBin, setEventsOn, tmpDir } from '@tagents/core';
import { SEND_MESSAGE_MAX, SEND_TITLE_MAX } from '../src/cli/spec.ts';
import type { Exec, ExecResult } from '../src/exec.ts';
import type { Platform, RunSpec, ServiceStatus } from '../src/notifier.ts';
import { tagentsScript } from '../src/paths.ts';
import { ALLOWING_NOTIFICATIONS, createNotifyPlugin } from '../src/plugin.ts';
import { LOCK_FILE } from '../src/service.ts';
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
  /** 'real': the plugin picks its own platform; an object: a fake with these members, whatever the backend. */
  readonly platform?: 'real' | Partial<Platform>;
  /** Each look at the fake service takes this long on the fake clock: `launchctl print` is not instant. */
  readonly statusMs?: number;
  /** Runs at each pause the install verb takes while it waits for the service to settle; `n` counts from 1. */
  readonly onSleep?: (n: number) => void;
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
  // The clock the settle wait measures its deadline on. Only a pause or a slow look moves it.
  let clock = 0;
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
        clock += o.statusMs ?? 0;
        return service.status;
      },
    },
    ...extra,
  });
  const outs: string[] = [];
  const errs: string[] = [];
  // No test waits for real: a pause is recorded, and the test decides what changes during it.
  const sleeps: number[] = [];
  const sleep = async (ms: number): Promise<void> => {
    sleeps.push(ms);
    clock += ms;
    o.onSleep?.(sleeps.length);
  };
  const wanted = o.platform;
  const platform = wanted === undefined || typeof wanted === 'string' ? undefined : (): Platform => fake(wanted);
  const plugin = createNotifyPlugin({
    os: o.os ?? 'darwin',
    env,
    home,
    out: (s) => outs.push(s),
    sleep,
    now: () => clock,
    mainJs: o.mainJs === null ? path.join(home, 'missing.js') : (o.mainJs ?? mainJs),
    ...(o.exec !== undefined ? { exec: o.exec } : {}),
    ...(platform !== undefined ? { platform } : {}),
  });
  return {
    plugin,
    config,
    state,
    home,
    env,
    service,
    sleeps,
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

test('send posts the message as the body of one notice through the backend and says shown', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('send', 'The', 'build', 'is', 'green'), 0, r.err());
  assert.equal(r.out(), 'shown\n');
  assert.equal(notifier.posts.length, 1);
  const notice = notifier.posts[0];
  assert.equal(notice?.kind, 'message');
  assert.equal(notice?.title, 'tagents');
  assert.equal(notice?.subtitle, '');
  assert.equal(notice?.body, 'The build is green');
});

test('send --title puts the title on the notice, and a message that is one argument stays whole', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('send', '--title=Deploy', 'staging is up, 3 checks passed'), 0, r.err());
  assert.equal(notifier.posts[0]?.title, 'Deploy');
  assert.equal(notifier.posts[0]?.body, 'staging is up, 3 checks passed');
});

test('two sends are two notices: neither replaces the other', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('send', 'first'), 0);
  assert.equal(await r.run('send', 'second'), 0);
  assert.equal(notifier.posts.length, 2);
  assert.notEqual(notifier.posts[0]?.id, notifier.posts[1]?.id);
});

test('send docks $TMUX_PANE on a click, as test does, and only raises the terminal outside tmux', async () => {
  const notifier = recordingNotifier();
  const inPane = rig({ os: 'linux', platform: { notifier }, exec: async () => result({ code: 1 }), env: { TMUX_PANE: '%7' } });
  assert.equal(await inPane.run('send', 'hello'), 0, inPane.err());
  assert.deepEqual(notifier.posts[0]?.click.argv.slice(1), ['--act', 'open', '%7', 'live', '', process.cwd()]);
  const outside = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await outside.run('send', 'hello'), 0, outside.err());
  assert.deepEqual(notifier.posts[1]?.click.argv, []);
});

test('send hands a title with quotes, an equals sign and a newline to the backend as it was given', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  const title = 'He said "stop" it\'s a=b\nsecond line';
  assert.equal(await r.run('send', `--title=${title}`, 'a "quoted" body', 'with\na newline'), 0, r.err());
  assert.equal(notifier.posts[0]?.title, title);
  assert.equal(notifier.posts[0]?.body, 'a "quoted" body with\na newline');
});

test('send takes a title of 256 characters and refuses one of 257, naming the limit, and posts nothing', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('send', `--title=${'t'.repeat(SEND_TITLE_MAX)}`, 'hello'), 0, r.err());
  assert.equal(notifier.posts.length, 1);
  assert.equal(await r.run('send', `--title=${'t'.repeat(SEND_TITLE_MAX + 1)}`, 'hello'), 2);
  assert.match(r.err(), new RegExp(`title is over ${SEND_TITLE_MAX} characters`));
  assert.equal(notifier.posts.length, 1, 'the refused call posted nothing');
});

test('send takes a message of 2048 characters, the words counted with the spaces between them, and refuses one of 2049, naming the limit', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  const half = 'm'.repeat((SEND_MESSAGE_MAX - 1) / 2);
  assert.equal(await r.run('send', half, `${half}m`), 0, r.err());
  assert.equal(notifier.posts[0]?.body.length, SEND_MESSAGE_MAX);
  assert.equal(await r.run('send', half, `${half}mm`), 2);
  assert.match(r.err(), new RegExp(`message is over ${SEND_MESSAGE_MAX} characters`));
  assert.equal(notifier.posts.length, 1, 'the refused call posted nothing');
});

test('the limits count characters, not bytes or UTF-16 units: 256 emoji are a title that fits', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('send', `--title=${'😀'.repeat(SEND_TITLE_MAX)}`, 'hello'), 0, r.err());
  assert.equal(await r.run('send', `--title=${'😀'.repeat(SEND_TITLE_MAX + 1)}`, 'hello'), 2);
  assert.equal(notifier.posts.length, 1);
});

test('send without a message is a usage error and posts nothing', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await r.run('send'), 2);
  assert.doesNotMatch(r.err(), /unknown command/, 'send is a verb, and it is the missing message that is refused');
  assert.equal(notifier.posts.length, 0);
});

test('send says dropped with the reason and exits 1, and with the none backend says nothing posts', async () => {
  const notifier = recordingNotifier();
  notifier.result = { shown: false, why: 'notifications are off' };
  const dropped = rig({ os: 'linux', platform: { notifier } });
  assert.equal(await dropped.run('send', 'hello'), 1);
  assert.equal(dropped.out(), 'dropped: notifications are off\n');
  const none = rig({ os: 'linux', options: 'backend: none\n', platform: 'real' });
  assert.equal(await none.run('send', 'hello'), 1);
  assert.match(none.out(), /^error: backend is none/);
});

test('status prints every key and exits 0 when the service runs, the permission is granted and the options are valid', async () => {
  const exec: Exec = async (file) =>
    file === 'ps' ? result({ stdout: '  20480\n' }) : file === '/bin/sh' ? result({ stdout: 'stale\n' }) : result({ code: 1 });
  const r = rig({ exec, env: { TA_NOTIFY_APP: '/tmp/Fake.app' }, platform: { permission: async () => 'authorized' } });
  setEventsOn(true, r.state);
  assert.equal(await r.run('status'), 0, r.out() + r.err());
  const out = r.out();
  for (const key of ['platform', 'backend', 'app', 'icon', 'permission', 'click', 'service', 'stream', 'options']) {
    assert.match(out, new RegExp(`^${key}: `, 'm'), key);
  }
  assert.match(out, /^platform: darwin$/m);
  assert.match(out, /^backend: auto \(resolved to fake\)$/m);
  assert.match(out, /^app: \/tmp\/Fake\.app \(stale\)$/m);
  assert.match(out, /^icon: none$/m);
  assert.match(out, /^click: .*\/tagents \(ok\)$/m);
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
  const block = /Allowing notifications:\n\n((?:\d+\. .+\n)+)/.exec(readme)?.[1];
  assert.ok(block !== undefined, 'the README has the numbered list after "Allowing notifications:"');
  const steps = block.trimEnd().split('\n').map((l) => l.replace(/^\d+\. /, ''));
  assert.deepEqual(steps, [...ALLOWING_NOTIFICATIONS], 'the whole list, so a step added to one side is caught');
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
      XDG_CONFIG_HOME: '/x/config',
      TA_CONFIG: '/x/config.yaml',
      TAGENTS_LOCALE: 'ru',
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
      XDG_CONFIG_HOME: '/x/config',
      TA_CONFIG: '/x/config.yaml',
      TAGENTS_LOCALE: 'ru',
      TA_NOTIFY_APP: '/tmp/Fake.app',
      TA_NOTIFY_TAGENTS: tagentsScript({}),
    },
    'LANG defaults to UTF-8, an empty TMUX_TMPDIR is left out, the config home and the locale the service would otherwise lose are forwarded, and with no tagents on PATH the click script is the package\'s own'
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
  assert.equal(await denied.run('install'), 1, 'the final status is not ok');
  assert.match(denied.err(), /install finished, but the permission is denied/);
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

// The real macOS platform over a fake exec: the build script, the helper and launchctl all answer from here, so
// nothing builds, nothing posts and nothing reaches launchd. Every call is kept, in order, `[file, ...args]`.
interface MacosExecOptions {
  readonly alertStyle?: string;
  readonly bundleId?: string;
  readonly permission?: string;
  /** What `build.sh --check` answers. */
  readonly app?: 'up to date' | 'stale' | 'missing';
  /** The build fails whenever it is given an icon, as it does for a picture it cannot decode. */
  readonly failBuildWithIcon?: boolean;
}

function macosExec(o: MacosExecOptions = {}): { readonly exec: Exec; readonly calls: (readonly string[])[] } {
  const calls: (readonly string[])[] = [];
  const exec: Exec = async (file, args) => {
    calls.push([file, ...args]);
    if (file === '/bin/sh') {
      if (args.includes('--check')) return result({ stdout: `${o.app ?? 'stale'}\n` });
      return o.failBuildWithIcon === true && args.includes('--icon') ? result({ code: 1, stderr: 'iconutil: cannot read picture\n' }) : result();
    }
    if (file === '/usr/bin/xcrun') return result();
    if (file.endsWith('/tagents-notify')) {
      return result({ stdout: `${JSON.stringify({ ok: true, status: o.permission ?? 'authorized', alertStyle: o.alertStyle ?? 'alert', ...(o.bundleId === undefined ? {} : { bundleId: o.bundleId }) })}\n` });
    }
    if (file === '/bin/launchctl') return args[0] === 'print' ? result({ stdout: '\tstate = running\n\tpid = 4242\n' }) : result();
    if (file === 'ps') return result({ stdout: '  20480\n' });
    return result({ code: 1 });
  };
  return { exec, calls };
}

function macosRig(o: MacosExecOptions & { readonly options?: string; readonly env?: NodeJS.ProcessEnv } = {}) {
  const dir = tmpDir('notify-cmd-macos');
  const app = path.join(dir, 'TagentsNotify.app');
  const { exec, calls } = macosExec(o);
  const r = rig({ platform: 'real', exec, env: { TA_NOTIFY_APP: app, ...o.env }, ...(o.options !== undefined ? { options: o.options } : {}) });
  setEventsOn(true, r.state);
  /** The arguments of each call of the build script, the script's own path left off. */
  const builds = (): (readonly string[])[] => calls.filter((c) => c[0] === '/bin/sh').map((c) => c.slice(2));
  return { ...r, dir, app, calls, builds };
}

const lines = (out: string): string[] => out.split('\n');

test('the icon option, relative to the options file, reaches the build and its check, and install says which icon the app has', async () => {
  const t = macosRig({ options: 'icon: mine.png\n' });
  const png = path.join(t.config, 'plugins', 'mine.png');
  fs.writeFileSync(png, 'png');
  assert.equal(await t.run('install'), 0, t.err());
  // The check before the build, the build, and the check the closing status makes of the app it just built.
  assert.deepEqual(t.builds(), [['--check', '--icon', png, t.app], ['--icon', png, t.app], ['--check', '--icon', png, t.app]]);
  assert.ok(lines(t.out()).includes(`icon: ${png}`), t.out());
});

test('without the option the icon is notify-icon.png beside the app when there is one, else the app has none', async () => {
  const none = macosRig();
  assert.equal(await none.run('install'), 0, none.err());
  assert.deepEqual(none.builds(), [['--check', none.app], [none.app], ['--check', none.app]]);
  assert.ok(lines(none.out()).includes('icon: none'), none.out());

  const beside = macosRig();
  const png = path.join(beside.dir, 'notify-icon.png');
  fs.writeFileSync(png, 'png');
  assert.equal(await beside.run('status'), 0, beside.out() + beside.err());
  assert.ok(lines(beside.out()).includes(`icon: ${png}`), beside.out());
  assert.deepEqual(beside.builds(), [['--check', '--icon', png, beside.app]], 'status asks about the app the install would build');
});

test('a configured icon that is not a file is a problem line in status and in install, and the app is built without it', async () => {
  const problemOf = (config: string): string =>
    `icon ${path.join(config, 'plugins', 'gone.png')} does not exist; the app is built without an icon`;
  const t = macosRig({ options: 'icon: gone.png\n' });
  const problem = problemOf(t.config);

  assert.equal(await t.run('status'), 0, 'the notices still arrive, so the exit code is not about the icon');
  assert.ok(lines(t.out()).includes('icon: none'), t.out());
  assert.ok(lines(t.out()).includes(`  ${problem}`), t.out());

  const installed = macosRig({ options: 'icon: gone.png\n' });
  assert.equal(await installed.run('install'), 0, installed.err());
  const installedProblem = problemOf(installed.config);
  assert.ok(installed.err().includes(installedProblem), installed.err());
  assert.ok(lines(installed.out()).includes(`  ${installedProblem}`), installed.out());
  assert.deepEqual(installed.builds(), [['--check', installed.app], [installed.app], ['--check', installed.app]]);
});

const settingsUrl = (id: string): string => `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=${id}`;
const ALERT_SETTINGS_URL = settingsUrl('io.github.skuratovicha.tagents-notify');
const hintOf = (out: string): string | undefined => lines(out).find((l) => l.startsWith('hint: '));

test('alert style banner: status and install say how to make notices stay, with the Settings link', async () => {
  for (const verb of ['status', 'install']) {
    const t = macosRig({ alertStyle: 'banner' });
    assert.equal(await t.run(verb), 0, `${verb}: ${t.out()}${t.err()}`);
    assert.match(t.out(), /^permission: authorized \(alert style: banner\)$/m);
    const hint = hintOf(t.out());
    assert.ok(hint !== undefined, `${verb}: ${t.out()}`);
    assert.ok(hint.includes('Alert Style') && hint.includes('"Persistent" (called Alerts before macOS 26)'), hint);
    assert.ok(hint.includes(ALERT_SETTINGS_URL), hint);
  }
});

test('the hint links to the bundle id the helper reported, and to the base id when it reported none', async () => {
  const reported = macosRig({ alertStyle: 'banner', bundleId: 'io.github.skuratovicha.tagents-notify.i0a1b2c3d' });
  await reported.run('status');
  const hint = hintOf(reported.out());
  assert.ok(hint !== undefined && hint.includes(settingsUrl('io.github.skuratovicha.tagents-notify.i0a1b2c3d')), hint);
  assert.ok(!hint.includes(`${ALERT_SETTINGS_URL}"`), hint);
  const silent = macosRig({ alertStyle: 'banner' });
  await silent.run('status');
  assert.ok(hintOf(silent.out())?.includes(`${ALERT_SETTINGS_URL}"`), silent.out());
});

test('alert style none: the hint says nothing is shown on screen at all', async () => {
  for (const verb of ['status', 'install']) {
    const t = macosRig({ alertStyle: 'none' });
    await t.run(verb);
    const hint = hintOf(t.out());
    assert.ok(hint !== undefined, `${verb}: ${t.out()}`);
    assert.ok(hint.includes('nothing is shown on screen at all'), hint);
    assert.ok(hint.includes(ALERT_SETTINGS_URL), hint);
  }
});

test('alert style alert: no hint, because the notices already stay', async () => {
  for (const verb of ['status', 'install']) {
    const t = macosRig({ alertStyle: 'alert' });
    assert.equal(await t.run(verb), 0, `${verb}: ${t.out()}${t.err()}`);
    assert.equal(hintOf(t.out()), undefined, t.out());
    assert.ok(!t.out().includes('Persistent') || verb === 'install', 'only the install steps may mention it');
    assert.ok(!t.out().includes(ALERT_SETTINGS_URL), t.out());
  }
});

test('without permission the style is not the problem, so there is no style hint', async () => {
  const t = macosRig({ alertStyle: 'none', permission: 'notDetermined' });
  await t.run('status');
  assert.match(t.out(), /^permission: notDetermined \(alert style: none\)$/m);
  assert.equal(hintOf(t.out()), undefined, t.out());
});

test('test docks $TMUX_PANE even when no state row exists for that pane, with an empty session id', async () => {
  const notifier = recordingNotifier();
  const r = rig({ os: 'linux', platform: { notifier }, exec: async () => result({ code: 1 }), env: { TMUX_PANE: '%7' } });
  assert.equal(fs.readdirSync(r.state).length, 0, 'no row for pane 7');
  assert.equal(await r.run('test'), 0, r.err());
  const click = notifier.posts[0]?.click;
  assert.ok(click !== undefined);
  // The click's lookup by session id finds no record for a made-up one and docks nothing; an empty id skips it.
  assert.deepEqual(click.argv.slice(1), ['--act', 'open', '%7', 'live', '', process.cwd()]);
});

test('with click: focus the script is not used, so status does not call it missing', async () => {
  const r = rig({ options: 'click: focus\n', env: { TA_NOTIFY_TAGENTS: '/nonexistent/tagents' } });
  await r.run('status');
  assert.ok(lines(r.out()).includes('click: /nonexistent/tagents (not used: click is focus)'), r.out());
});

test('status says whether the script a click runs is there, and install warns when it is not', async () => {
  const dir = tmpDir('notify-cmd-script');
  const script = path.join(dir, 'tagents');
  const ok = rig({ env: { TA_NOTIFY_TAGENTS: script }, platform: { setup: async () => 'authorized', permission: async () => 'authorized' } });
  fs.writeFileSync(script, '#!/bin/sh\n');
  fs.chmodSync(script, 0o755);
  await ok.run('status');
  assert.ok(lines(ok.out()).includes(`click: ${script} (ok)`), ok.out());
  await ok.run('install');
  assert.ok(!ok.err().includes(script), ok.err());

  fs.chmodSync(script, 0o644);
  const missing = rig({ env: { TA_NOTIFY_TAGENTS: path.join(dir, 'gone', 'tagents') }, platform: { setup: async () => 'authorized', permission: async () => 'authorized' } });
  await missing.run('status');
  assert.ok(lines(missing.out()).includes(`click: ${path.join(dir, 'gone', 'tagents')} (missing)`), missing.out());
  assert.equal(await missing.run('install'), 0);
  assert.match(missing.err(), /click: .*gone\/tagents is not an executable file: a click raises the terminal and docks nothing/);

  const notExecutable = rig({ env: { TA_NOTIFY_TAGENTS: script }, platform: { setup: async () => 'authorized' } });
  await notExecutable.run('status');
  assert.ok(lines(notExecutable.out()).includes(`click: ${script} (missing)`), 'present but not executable counts as missing');

  const focus = rig({ options: 'click: focus\n', env: { TA_NOTIFY_TAGENTS: path.join(dir, 'gone', 'tagents') }, platform: { setup: async () => 'authorized' } });
  await focus.run('install');
  assert.ok(!focus.err().includes('docks nothing'), 'click: focus never runs the script');
});

function deadPid(): number {
  const child = spawnSync(process.execPath, ['-e', ''], { encoding: 'utf8' });
  assert.ok(child.pid > 0);
  return child.pid;
}

/** A live process that is not this one, as a foreground `tagents notify run` in another terminal would be. */
function liveProcess(): { readonly pid: number; readonly stop: () => void } {
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { stdio: 'ignore' });
  assert.ok(child.pid !== undefined);
  return { pid: child.pid, stop: () => void child.kill('SIGKILL') };
}

const STARTED = 'Mon Jan  1 00:00:00 2024';
const psSays = (text: string): Exec => async (file) => (file === '/bin/ps' ? result({ stdout: `${text}\n` }) : result({ code: 1 }));

test('uninstall leaves the stream on while another live process holds the lock, in either lock format', async () => {
  const other = liveProcess();
  try {
    for (const content of [`${other.pid} ${STARTED}\n`, `${other.pid}\n`]) {
      const r = rig({ platform: {}, service: { pid: process.pid }, exec: psSays(STARTED) });
      setEventsOn(true, r.state);
      fs.writeFileSync(path.join(r.state, LOCK_FILE), content);
      assert.equal(await r.run('uninstall'), 0, r.err());
      assert.equal(r.service.uninstalls, 1);
      assert.equal(eventsOn(r.state), true, `a foreground \`run\` is following it: ${JSON.stringify(content)}`);
      assert.ok(lines(r.out()).includes(`stream: left on, pid ${other.pid} holds ${path.join(r.state, LOCK_FILE)}`), r.out());
    }
  } finally {
    other.stop();
  }
});

test('uninstall switches the stream off when the pid in the lock is alive but is another process now', async () => {
  const stranger = liveProcess();
  try {
    const r = rig({ platform: {}, service: { pid: process.pid }, exec: psSays('Tue Feb  2 11:11:11 2025') });
    setEventsOn(true, r.state);
    fs.writeFileSync(path.join(r.state, LOCK_FILE), `${stranger.pid} ${STARTED}\n`);
    assert.equal(await r.run('uninstall'), 0, r.err());
    assert.equal(eventsOn(r.state), false, 'the start time differs, so the pid was reused');
  } finally {
    stranger.stop();
  }
});

test('uninstall switches the stream off when the lock names the service it booted out, in either lock format', async () => {
  for (const content of [`${process.pid}\n`, `${process.pid} 1700000000000\n`]) {
    const r = rig({ platform: {}, service: { pid: process.pid } });
    setEventsOn(true, r.state);
    fs.writeFileSync(path.join(r.state, LOCK_FILE), content);
    assert.equal(await r.run('uninstall'), 0, r.err());
    assert.equal(eventsOn(r.state), false, JSON.stringify(content));
    assert.match(r.out(), /^stream: off$/m);
  }
});

test('uninstall switches the stream off when the lock is dead, unreadable or absent', async () => {
  for (const content of [`${deadPid()} 1700000000000\n`, 'garbage\n', '', null]) {
    const r = rig({ platform: {}, service: { pid: process.pid + 1 } });
    setEventsOn(true, r.state);
    if (content !== null) fs.writeFileSync(path.join(r.state, LOCK_FILE), content);
    assert.equal(await r.run('uninstall'), 0, r.err());
    assert.equal(eventsOn(r.state), false, JSON.stringify(content));
  }
});

const RUNNING: ServiceStatus = { installed: true, running: true, pid: 4242, detail: 'loaded, running, pid 4242' };

test('install returns as soon as the service runs and the stream is on, and prints that state', async () => {
  let settle: () => void = () => undefined;
  const r = rig({
    platform: { setup: async () => 'authorized', permission: async () => 'authorized' },
    service: { running: false, detail: 'loaded, not running (last exit 0)' },
    onSleep: (n) => {
      if (n === 3) settle();
    },
  });
  settle = () => {
    r.service.status = RUNNING;
    setEventsOn(true, r.state);
  };
  assert.equal(await r.run('install'), 0, r.err());
  assert.deepEqual(r.sleeps, [100, 100, 100], 'it checked, paused 100 ms, three times, and stopped waiting');
  assert.match(r.out(), /^service: loaded, running, pid 4242/m);
  assert.match(r.out(), /^stream: on$/m);
  assert.ok(!r.err().includes('did not settle'), r.err());
});

test('install waits at most 5 s, then prints what it saw and exits 1 naming the service', async () => {
  const r = rig({
    platform: { setup: async () => 'authorized', permission: async () => 'authorized' },
    service: { running: false, detail: 'loaded, not running (last exit 0)' },
  });
  assert.equal(await r.run('install'), 1);
  assert.equal(r.sleeps.length, 50);
  assert.ok(r.sleeps.every((ms) => ms === 100));
  assert.match(r.err(), /did not settle within 5 s/);
  assert.match(r.err(), /install finished, but the service is not running$/m);
  assert.match(r.out(), /^service: loaded, not running/m);
  assert.match(r.out(), /^stream: off$/m);
});

test('the settle wait is 5 s of wall time: looks that take long use it up', async () => {
  const r = rig({
    platform: { setup: async () => 'authorized', permission: async () => 'authorized' },
    service: { running: false, detail: 'loaded, not running (last exit 0)' },
    statusMs: 2000,
  });
  assert.equal(await r.run('install'), 1);
  assert.deepEqual(r.sleeps, [100, 100], 'looks at 0, 2.1 and 4.2 s; the third ends past 5 s');
  assert.match(r.err(), /did not settle within 5 s/);
});

test('install names the pid that holds the lock when the service it started is not the one running', async () => {
  const other = liveProcess();
  try {
    const r = rig({
      platform: { setup: async () => 'authorized', permission: async () => 'authorized' },
      service: { running: false, detail: 'loaded, not running (last exit 0)' },
    });
    fs.writeFileSync(path.join(r.state, LOCK_FILE), `${other.pid}\n`);
    assert.equal(await r.run('install'), 1);
    assert.match(r.err(), new RegExp(`the service is not running: pid ${other.pid} holds ${path.join(r.state, LOCK_FILE)}`));
  } finally {
    other.stop();
  }
});

test('install does the build, the authorization, the service install, the settle wait and the status, in that order', async () => {
  const t = macosRig();
  assert.equal(await t.run('install'), 0, t.err());
  const label = ([file = '', ...args]: readonly string[]): string => {
    if (file === '/bin/sh') return args.includes('--check') ? 'check' : 'build';
    if (file.endsWith('/tagents-notify')) return `helper ${args[0]}`;
    if (file === '/bin/launchctl') return `launchctl ${args[0]}`;
    return file;
  };
  const seen = t.calls.map(label);
  // The first `launchctl print` after the bootstrap comes before the status's `helper status`: only the settle wait
  // looks at the service before the status does, because the status reads the permission before the service.
  let at = -1;
  for (const step of ['build', 'helper authorize', 'launchctl bootstrap', 'launchctl print', 'helper status']) {
    const next = seen.indexOf(step, at + 1);
    assert.ok(next > at, `${step} comes after the step before it in ${seen.join(', ')}`);
    at = next;
  }
});

test('install builds the app without an icon the build refuses, and says which icon it was', async () => {
  const t = macosRig({ options: 'icon: bad.png\n', failBuildWithIcon: true });
  const png = path.join(t.config, 'plugins', 'bad.png');
  fs.writeFileSync(png, 'not a picture');
  assert.equal(await t.run('install'), 0, t.err());
  assert.ok(t.err().includes(`icon ${png} could not be used (iconutil: cannot read picture); the app is built without an icon`), t.err());
  assert.deepEqual(t.builds(), [['--check', '--icon', png, t.app], ['--icon', png, t.app], ['--check', t.app], [t.app], ['--check', t.app]]);
  assert.ok(lines(t.out()).includes('icon: none'), t.out());
  assert.ok(lines(t.out()).some((l) => l.startsWith('  icon ') && l.includes('could not be used')), t.out());
});

test('install does not wait when the service already runs and the stream is on', async () => {
  const r = rig({ platform: { setup: async () => 'authorized', permission: async () => 'authorized' } });
  setEventsOn(true, r.state);
  assert.equal(await r.run('install'), 0, r.err());
  assert.deepEqual(r.sleeps, []);
});

test('run exits 1 when the service cannot start, so that launchd starts it again', async () => {
  const r = rig();
  // A state directory under a regular file: the service's first step, creating it, throws.
  const blocker = path.join(r.state, 'blocker');
  fs.writeFileSync(blocker, '');
  const logs: string[] = [];
  const log = (...parts: string[]): void => void logs.push(parts.join(' '));
  const ctx = createContext({ plugin: r.plugin, log, configDir: r.config, agents: createAgentFeed(path.join(blocker, 'state')) });
  const run = r.plugin.commands?.find((c) => c.name === 'run');
  assert.ok(run !== undefined);
  assert.equal(await run.run({}, ctx), 1);
  assert.match(logs.join('\n'), /the notify service stopped: .*(ENOTDIR|not a directory)/);
});

test('install gives the service the tagents on the installer\'s PATH, as found, and status shows the same script', async () => {
  const bin = tmpDir('notify-cmd-tagents');
  fs.writeFileSync(path.join(bin, 'real'), '#!/bin/sh\n');
  fs.chmodSync(path.join(bin, 'real'), 0o755);
  fs.symlinkSync(path.join(bin, 'real'), path.join(bin, 'tagents'));
  const r = rig({ platform: { setup: async () => 'authorized', permission: async () => 'authorized' }, env: { PATH: [bin, '/usr/bin'].join(path.delimiter) } });
  assert.equal(await r.run('install'), 0, r.err());
  assert.equal(r.service.installed[0]?.env['TA_NOTIFY_TAGENTS'], path.join(bin, 'tagents'), 'the link the dashboard runs, not its target');
  assert.ok(lines(r.out()).includes(`click: ${path.join(bin, 'tagents')} (ok)`), r.out());
});

test('an explicit TA_NOTIFY_TAGENTS wins over the PATH, and with no tagents on PATH the package\'s own is carried', async () => {
  const bin = tmpDir('notify-cmd-tagents');
  fs.writeFileSync(path.join(bin, 'tagents'), '#!/bin/sh\n');
  fs.chmodSync(path.join(bin, 'tagents'), 0o755);
  const platform = { setup: async () => 'authorized', permission: async () => 'authorized' };
  const explicit = rig({ platform, env: { PATH: bin, TA_NOTIFY_TAGENTS: '/chosen/tagents' } });
  await explicit.run('install');
  assert.equal(explicit.service.installed[0]?.env['TA_NOTIFY_TAGENTS'], '/chosen/tagents');
  assert.ok(lines(explicit.out()).includes('click: /chosen/tagents (missing)'), explicit.out());

  const none = rig({ platform, env: { PATH: tmpDir('notify-cmd-empty') } });
  await none.run('install');
  assert.equal(none.service.installed[0]?.env['TA_NOTIFY_TAGENTS'], tagentsScript({}));
});
