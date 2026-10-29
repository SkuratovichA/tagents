// The notify plugin: what the host sees, and the five verbs a person types.
//
// Registering it in the config (`tagents plugin add`) gives `tagents notify <verb>`; the same verbs run from the package's own bin (main.ts), which is what the LaunchAgent starts. The service that actually posts notifications is `run`: under launchd it is the process, and a host that merely lists plugins never starts it.
//
// Every verb takes its directories from `deps.env` and not from the context, so
// a test points it at a temporary config and state dir without touching the
// process's own environment. In production `deps.env` is the process's, and the
// two agree.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { z } from 'zod';
import {
  configDir as configDirOf,
  definePlugin,
  eventsOn,
  findOnPath,
  isExecutableFile,
  labelsBySession,
  loadPluginOptions,
  readAgentState,
  runService,
  setEventsOn,
  stateDir as stateDirOf,
  type AgentEvent,
  type CliCommand,
  type CliCommandDef,
  type OptionsResult,
  type PluginContext,
  type PluginDef,
} from '@tagents/core';
import { buildNotice, eventFromRow } from './engine.ts';
import { describe } from './errors.ts';
import { execText, type Exec } from './exec.ts';
import type { NoticeKind } from './kinds.ts';
import type { Platform, RunSpec, ServiceManager } from './notifier.ts';
import { NotifyOptionsSchema, type NotifyOptions } from './options.ts';
import { BUNDLE_ID, MAIN_JS, appPath, logPath, resolveIcon, tagentsScript, type ResolvedIcon } from './paths.ts';
import { pickPlatform } from './platform/index.ts';
import { appState } from './platform/macos/app.ts';
import { helperStatus } from './platform/macos/helper.ts';
import { tmuxScreen } from './screen.ts';
import { LOCK_FILE, SERVICE_NAME, createNotifyService, holds, psProcessStart, readLock, systemBootMs } from './service.ts';

type Log = (...parts: string[]) => void;

export interface CommandDeps {
  readonly os?: NodeJS.Platform;
  readonly env?: NodeJS.ProcessEnv;
  readonly home?: string;
  readonly exec?: Exec;
  readonly platform?: (backend: NotifyOptions['backend'], log: Log) => Platform | null;
  /** Where a verb's answer goes: stdout, which a test replaces. The log lines go to stderr through the context. */
  readonly out?: (s: string) => void;
  /** The built entry the LaunchAgent runs: `dist/main.js` unless a test says otherwise. */
  readonly mainJs?: string;
  /** The pause `install` takes between two looks at the service it has just started; a test replaces it. */
  readonly sleep?: (ms: number) => Promise<void>;
  /** The wall clock the settle wait measures its 5 s against; a test replaces it. */
  readonly now?: () => number;
}

/** The README's "Allowing notifications" steps, word for word; a test pins the two together. */
export const ALLOWING_NOTIFICATIONS: readonly string[] = [
  '`tagents notify install` makes macOS ask whether "tagents" may send notifications: Allow.',
  'If the prompt was missed: System Settings → Notifications → tagents → Allow notifications.',
  'Alert Style, in System Settings → Notifications → tagents: "Persistent" keeps a notice on screen until you dismiss it, "Temporary" lets it disappear on its own (before macOS 26 they were called "Alerts" and "Banners").',
  'Focus and Do Not Disturb hide banners; the notices still land in Notification Center.',
  '`tagents notify status` must say `permission: authorized`.',
];

/** Where Settings opens on this app's notification settings, Alert Style among them. */
const alertStyleUrl = (bundleId: string): string =>
  `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=${bundleId}`;

/** How long `install` waits for launchd to start the job it has just bootstrapped, and how often it looks. */
const SETTLE_MS = 5000;
const SETTLE_STEP_MS = 100;

const KINDS = ['question', 'permission', 'turn_done', 'cache_expiring', 'session_end'] as const;
// Fails to compile when NoticeKind gains a member the `test` verb cannot pick.
const KINDS_COVER_EVERY_KIND: NoticeKind extends (typeof KINDS)[number] ? true : never = true;

const SAMPLE_TEXT: Readonly<Record<NoticeKind, string>> = {
  question: 'Which of the two approaches should I take?',
  permission: 'Claude needs your permission to use Bash',
  turn_done: 'The change is done and the tests pass.',
  cache_expiring: '',
  session_end: '',
};

/** Keeps each verb's own argument type inside its `run`, then stores it in the host's uniform shape. */
const verb = <S extends z.ZodType>(c: CliCommand<S>): CliCommandDef => c;

const DEFAULT_OPTIONS = NotifyOptionsSchema.parse({});

// What launchd runs, with the little environment it will have: it inherits
// nothing from the shell that ran `install`, so what the service needs (node,
// tmux, a UTF-8 locale, the state and config the shell used) is written down.
function runSpecFor(env: NodeJS.ProcessEnv, home: string, mainJs: string): { readonly spec: RunSpec; readonly tmux: string | null } {
  const tmuxFile = findOnPath('tmux', env['PATH']);
  const tmux = tmuxFile === null ? null : path.dirname(tmuxFile);
  const dirs = [path.dirname(process.execPath), ...(tmux === null ? [] : [tmux]), '/usr/bin', '/bin', '/usr/sbin', '/sbin'];
  const set = (k: string): string | undefined => {
    const v = env[k];
    return v !== undefined && v !== '' ? v : undefined;
  };
  const out: Record<string, string> = {
    PATH: [...new Set(dirs)].join(path.delimiter),
    HOME: set('HOME') ?? home,
    LANG: set('LANG') ?? 'en_US.UTF-8',
  };
  for (const k of [
    'LC_ALL',
    'LC_CTYPE',
    'TA_STATE_DIR',
    'TAGENTS_CONFIG_DIR',
    'XDG_CONFIG_HOME',
    'TA_CONFIG',
    'TMUX_TMPDIR',
    'TAGENTS_LOCALE',
    'TA_NOTIFY_APP',
  ]) {
    const v = set(k);
    if (v !== undefined) out[k] = v;
  }
  // Decided here and carried, not looked up again by the service on its own PATH: see `tagentsScript`.
  out['TA_NOTIFY_TAGENTS'] = tagentsScript(env);
  return { spec: { program: process.execPath, args: [mainJs, 'run'], env: out, logFile: logPath(home) }, tmux };
}

/**
 * What to tell a person whose notices go away by themselves (`banner`) or are never drawn (`none`). macOS leaves the
 * choice to the person, so the hint names the setting; `alert` stays until dismissed and needs none.
 */
function alertStyleHint(style: string, bundleId: string): string | null {
  const where = `System Settings → Notifications → tagents, or open "${alertStyleUrl(bundleId || BUNDLE_ID)}"`;
  if (style === 'banner') {
    return `hint: notices disappear on their own. To keep them on screen until you dismiss them, set Alert Style to "Persistent" (called Alerts before macOS 26) in ${where}`;
  }
  if (style === 'none') {
    return `hint: the alert style is none, so nothing is shown on screen at all. Set Alert Style to "Temporary" or "Persistent" (called Banners and Alerts before macOS 26) in ${where}`;
  }
  return null;
}

interface StatusReport {
  readonly lines: readonly string[];
  readonly ok: boolean;
  readonly permission: string;
  readonly running: boolean;
  /** What keeps `ok` false, apart from the service: `install` names these when it exits 1. */
  readonly problems: readonly string[];
}

export function createNotifyPlugin(deps: CommandDeps = {}): PluginDef {
  const osName = deps.os ?? process.platform;
  const env = deps.env ?? process.env;
  const home = deps.home ?? os.homedir();
  const exec = deps.exec ?? execText;
  const mainJs = deps.mainJs ?? MAIN_JS;
  const out = deps.out ?? ((s: string): void => void process.stdout.write(s));
  const sleep = deps.sleep ?? ((ms: number): Promise<void> => delay(ms));
  const now = deps.now ?? Date.now;
  const processStart = psProcessStart(deps.exec);
  const lockFile = (): string => path.join(stateDirOf(env), LOCK_FILE);
  const say = (...lines: readonly string[]): void => out(lines.map((l) => `${l}\n`).join(''));

  const make = (backend: NotifyOptions['backend'], log: Log, icon: string | null = null): Platform | null =>
    (deps.platform ??
      ((b, l) =>
        pickPlatform(osName, b, {
          log: l,
          env,
          home,
          ...(icon !== null ? { icon } : {}),
          ...(deps.exec !== undefined ? { exec: deps.exec } : {}),
        })))(backend, log);
  const load = (): OptionsResult<NotifyOptions> => loadPluginOptions(configDirOf(env), SERVICE_NAME, NotifyOptionsSchema);
  const effective = (r: OptionsResult<NotifyOptions>): NotifyOptions => (r.ok ? r.value : DEFAULT_OPTIONS);
  /** The service manager does not depend on the backend: `none` must not make an installed LaunchAgent unreachable. */
  const serviceOf = (o: NotifyOptions, log: Log): Platform | null => make(o.backend, log) ?? make('log', log);

  async function rssMb(pid: number): Promise<string> {
    try {
      const r = await exec('ps', ['-o', 'rss=', '-p', String(pid)], { timeoutMs: 3000 });
      const kb = Number.parseInt(r.stdout.trim(), 10);
      return Number.isInteger(kb) ? `, rss ${Math.round(kb / 1024)} MB` : '';
    } catch {
      return '';
    }
  }

  // What `status` prints and `install` ends with: the same function, so the two cannot disagree.
  // `iconUsed` is what `install` settled on when the build refused the configured icon; it replaces the option.
  async function statusReport(log: Log, iconUsed?: ResolvedIcon): Promise<StatusReport> {
    const r = load();
    const o = effective(r);
    const icon = iconUsed ?? resolveIcon(o.icon, r.file, env, home);
    const platform = make(o.backend, log, icon.file);
    const lines: string[] = [];
    const kv = (k: string, v: string): void => void lines.push(`${k}: ${v}`);
    kv('platform', osName);
    kv('backend', `${o.backend} (resolved to ${platform?.name ?? 'none'})`);

    if (osName === 'darwin') {
      const app = appPath(env, home);
      try {
        kv('app', `${app} (${await appState(app, icon.file ?? undefined, deps.exec)})`);
      } catch (e) {
        kv('app', `${app} (unknown: ${describe(e)})`);
      }
      kv('icon', icon.file ?? 'none');
      if (icon.problem !== undefined) lines.push(`  ${icon.problem}`);
    }

    const problems: string[] = [];
    let permission = 'not needed';
    let permissionOk = true;
    try {
      if (platform?.name === 'macos') {
        const h = await helperStatus(appPath(env, home), deps.exec);
        permission = h.status;
        kv('permission', `${h.status} (alert style: ${h.alertStyle})`);
        // Before authorization the style is none for a reason the permission line already gives.
        const hint = h.status === 'authorized' ? alertStyleHint(h.alertStyle, h.bundleId) : null;
        if (hint !== null) lines.push(hint);
      } else if (platform?.permission !== undefined) {
        permission = await platform.permission();
        kv('permission', permission);
      } else {
        kv('permission', permission);
      }
      permissionOk = platform?.permission === undefined && platform?.name !== 'macos' ? true : permission === 'authorized';
    } catch (e) {
      permission = `unknown: ${describe(e)}`;
      permissionOk = false;
      kv('permission', permission);
    }
    if (!permissionOk) problems.push(`the permission is ${permission}`);

    const script = tagentsScript(env);
    kv('click', `${script} (${o.click === 'focus' ? 'not used: click is focus' : isExecutableFile(script) ? 'ok' : 'missing'})`);

    let running = false;
    const service = serviceOf(o, log)?.service ?? null;
    if (service === null) {
      kv('service', `no service manager on ${osName}`);
    } else {
      try {
        const s = await service.status();
        running = s.running;
        kv('service', s.detail + (s.running && s.pid !== undefined ? await rssMb(s.pid) : ''));
      } catch (e) {
        kv('service', `unknown: ${describe(e)}`);
      }
    }

    kv('stream', eventsOn(stateDirOf(env)) ? 'on' : 'off');
    if (r.ok) {
      kv('options', `${r.file} ${r.found ? 'found' : 'not found (defaults)'}`);
    } else {
      kv('options', `${r.file} invalid`);
      for (const p of r.problems) lines.push(`  ${p}`);
      problems.push(`${r.file} is invalid`);
    }
    return { lines, ok: running && permissionOk && r.ok, permission, running, problems };
  }

  function installSteps(permission: string): readonly string[] {
    // The prompt appears once, so a person who is not yet authorized is past step 1: Settings is what helps.
    const order = permission === 'authorized' ? [0, 1, 2, 3, 4] : [1, 0, 2, 3, 4];
    return [
      'Allowing notifications:',
      ...order.map((i, n) => `${n + 1}. ${ALLOWING_NOTIFICATIONS[i] ?? ''}`),
    ];
  }

  /**
   * launchd starts the job it has just bootstrapped on its own time, so a status read at once can say "not running"
   * and "stream: off" about a service a few hundred milliseconds from both. Waits, bounded, until the service runs
   * and the stream is on; false when the bound passed first.
   *
   * This is the one timer outside clock.ts and launchd.ts: a one-shot wait in a CLI verb that ends, not polling in
   * the service, and launchd.ts cannot do it because the stream is the service's own doing and not launchd's.
   */
  async function settle(service: ServiceManager): Promise<boolean> {
    // A deadline and not a count of pauses: each look is a `launchctl print`, and slow ones must not stretch the 5 s.
    const deadline = now() + SETTLE_MS;
    for (;;) {
      try {
        if ((await service.status()).running && eventsOn(stateDirOf(env))) return true;
      } catch {
        // The report that follows shows what `status` says about the service.
      }
      if (now() >= deadline) return false;
      await sleep(SETTLE_STEP_MS);
    }
  }

  /**
   * The pid of a live notify service other than `booted`, the one launchd runs, when it holds the lock; null when
   * the lock is free, stale, a reused pid, or the booted service's own. The same judgement the service makes when it
   * takes the lock, so the two cannot disagree about who is running.
   */
  async function otherHolder(booted: number | undefined): Promise<number | null> {
    const seen = readLock(lockFile());
    if (seen === null || seen.pid === null || seen.pid === booted) return null;
    const live = await holds(seen, { self: { pid: process.pid, started: null }, bootMs: systemBootMs(), processStart });
    return live ? seen.pid : null;
  }

  async function sampleEvent(kind: NoticeKind): Promise<AgentEvent> {
    const dir = stateDirOf(env);
    const pane = env['TMUX_PANE'] ?? '';
    const text = SAMPLE_TEXT[kind];
    const row = pane === '' ? undefined : readAgentState(dir).find((x) => x.key === pane.replace(/^%/, ''));
    if (row !== undefined) return { ...eventFromRow(row, labelsBySession(dir)), at: Date.now(), text };
    // No hook has recorded this pane, as in a plain shell pane, but the click still docks the pane the command ran in.
    return {
      at: Date.now(),
      event: 'Stop',
      key: 's-test',
      // Empty and not made up: the click's lookup by session id finds no record for a made-up one and docks nothing.
      sessionId: '',
      agentId: '',
      pane,
      cwd: process.cwd(),
      transcript: '',
      configDir: '',
      tool: '',
      sub: '',
      text,
      label: '',
    };
  }

  const plugin: PluginDef = definePlugin({
    name: 'notify',
    apiVersion: 1,
    services: [
      createNotifyService({
        os: osName,
        env,
        ...(deps.platform !== undefined ? { platform: deps.platform } : {}),
      }),
    ],
    commands: [
      verb({
        name: 'run',
        describe: 'Run the notification service in the foreground.',
        args: z.object({}),
        async run(_a, ctx: PluginContext): Promise<number> {
          // 0 is for a service that deliberately does not run (another one holds the lock, backend none, an unsupported
          // OS) and for one a signal stopped: the LaunchAgent's `SuccessfulExit: false` never restarts those. A start
          // that throws exits 1, which launchd does restart, so a failure that passes is not left dead until login.
          try {
            const running = await runService(plugin, SERVICE_NAME, ctx, { signals: true });
            await running.done;
          } catch (e) {
            ctx.log(`the notify service stopped: ${describe(e)}`);
            return 1;
          }
          return 0;
        },
      }),
      verb({
        name: 'install',
        describe: 'Install the service, build the helper app and ask for permission.',
        args: z.object({}),
        async run(_a, ctx): Promise<number> {
          if (osName !== 'darwin') {
            ctx.log(`no notification backend for ${osName} yet`);
            return 2;
          }
          if (!fs.existsSync(mainJs)) {
            ctx.log(`${mainJs} does not exist; run pnpm build first`);
            return 1;
          }
          const r = load();
          if (!r.ok) for (const p of r.problems) ctx.log(`options: ${p}`);
          const o = effective(r);
          let icon = resolveIcon(o.icon, r.file, env, home);
          if (icon.problem !== undefined) ctx.log(icon.problem);
          const platform = make(o.backend, ctx.log, icon.file);
          if (platform === null) {
            ctx.log(`backend is none in ${r.file}: nothing to install`);
            return 1;
          }
          if (platform.service === null) {
            ctx.log(`the ${platform.name} backend has no service manager on ${osName}`);
            return 1;
          }
          let service: ServiceManager = platform.service;
          let permission = 'not needed';
          if (platform.setup !== undefined) {
            try {
              permission = await platform.setup(ctx.log);
            } catch (e) {
              // The build script reads the picture, so one it cannot decode fails the build. The icon is a nicety:
              // say which one and build without it. A build that fails again without it is the real error.
              if (icon.file === null) throw e;
              const reason = describe(e).split('\n').map((l) => l.trim()).findLast((l) => l !== '') ?? 'the build failed';
              const problem = `icon ${icon.file} could not be used (${reason}); the app is built without an icon`;
              icon = { file: null, problem };
              ctx.log(problem);
              const plain = make(o.backend, ctx.log);
              if (plain?.setup === undefined || plain.service === null) throw e;
              service = plain.service;
              permission = await plain.setup(ctx.log);
            }
          }
          say(`permission: ${permission}`);

          const { spec, tmux } = runSpecFor(env, home, mainJs);
          if (tmux === null) ctx.log('no tmux on PATH: the service cannot tell whether a pane is on screen');
          const script = tagentsScript(env);
          if (o.click !== 'focus' && !isExecutableFile(script)) {
            ctx.log(`click: ${script} is not an executable file: a click raises the terminal and docks nothing (TA_NOTIFY_TAGENTS names another)`);
          }
          await service.install(spec);
          if (!(await settle(service))) {
            ctx.log(`the service did not settle within ${SETTLE_MS / 1000} s; the status below is what it shows now`);
          }

          const report = await statusReport(ctx.log, icon);
          say(...report.lines, ...installSteps(permission));
          if (report.ok) return 0;
          const causes = [...report.problems];
          if (!report.running) {
            const other = await otherHolder(undefined);
            causes.unshift(
              other === null ? 'the service is not running' : `the service is not running: pid ${other} holds ${lockFile()}`
            );
          }
          ctx.log(`install finished, but ${causes.join('; ')}`);
          return 1;
        },
      }),
      verb({
        name: 'uninstall',
        describe: 'Stop and remove the service.',
        args: z.object({ purge: z.boolean().default(false) }),
        async run(a, ctx): Promise<number> {
          const service = osName === 'darwin' ? (serviceOf(effective(load()), ctx.log)?.service ?? null) : null;
          if (service === null) {
            say(`nothing to uninstall on ${osName}`);
            return 0;
          }
          // The pid launchd is about to stop: a lock that names it is that service's own, and goes with it.
          const booted = await service.status().then(
            (s) => s.pid,
            () => undefined
          );
          await service.uninstall();
          say('service: removed');
          const holder = await otherHolder(booted);
          if (holder !== null) {
            // A `tagents notify run` in a terminal is following the stream; switching it off would end its notices.
            say(`stream: left on, pid ${holder} holds ${lockFile()}`);
          } else {
            setEventsOn(false, stateDirOf(env));
            say('stream: off');
          }
          if (a.purge) {
            const app = appPath(env, home);
            fs.rmSync(app, { recursive: true, force: true });
            say(`app: removed ${app}`);
          }
          return 0;
        },
      }),
      verb({
        name: 'status',
        describe: 'Show whether notifications will arrive.',
        args: z.object({}),
        async run(_a, ctx): Promise<number> {
          const report = await statusReport(ctx.log);
          say(...report.lines);
          return report.ok ? 0 : 1;
        },
      }),
      verb({
        name: 'test',
        describe: 'Post one sample notice through the backend.',
        args: z.object({ kind: z.enum(KINDS).default('turn_done') }),
        async run(a, ctx): Promise<number> {
          void KINDS_COVER_EVERY_KIND;
          const r = load();
          if (!r.ok) for (const p of r.problems) ctx.log(`options: ${p}`);
          const o = effective(r);
          const platform = make(o.backend, ctx.log);
          if (platform === null) {
            say('error: backend is none, nothing posts');
            return 1;
          }
          const e = await sampleEvent(a.kind);
          const extra = a.kind === 'cache_expiring' ? { idleMin: 50, leftMin: 10 } : {};
          try {
            const notice = await buildNotice(a.kind, e, extra, { skipVisible: false, click: o.click }, {
              screen: tmuxScreen(deps.exec),
              labelsDir: stateDirOf(env),
              tagents: tagentsScript(env),
              hostname: os.hostname,
              env,
              log: ctx.log,
            });
            const posted = await platform.notifier.post(notice);
            say(posted.shown ? 'shown' : `dropped: ${posted.why ?? 'no reason given'}`);
            return posted.shown ? 0 : 1;
          } catch (e2) {
            say(`error: ${describe(e2)}`);
            return 1;
          }
        },
      }),
    ],
  });
  return plugin;
}

export default createNotifyPlugin();
