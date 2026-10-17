// The long-running service: one process per machine that follows the agents'
// event stream and posts what the engine decides to post.
//
// What makes it a service and not a loop is what it holds. A lock file in the
// state dir keeps two of them from posting every notice twice. The options file
// is watched, not polled, so a change reaches the running engine and an idle
// Mac costs nothing. And stopping it leaves nothing behind: the stream switch
// the hook reads goes off with the follower, the lock is released, `done`
// resolves.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  PLUGIN_OPTIONS_DIR,
  isAlive,
  loadPluginOptions,
  pluginOptionsFile,
  type OptionsResult,
  type PluginContext,
  type ServiceDef,
  type ServiceHandle,
} from '@tagents/core';
import { systemClock, type Clock } from './clock.ts';
import { describe } from './errors.ts';
import { createEngine } from './engine.ts';
import type { Platform } from './notifier.ts';
import { NotifyOptionsSchema, type NotifyOptions } from './options.ts';
import { tagentsScript } from './paths.ts';
import { pickPlatform } from './platform/index.ts';
import { tmuxScreen, type ScreenProbe } from './screen.ts';

export const SERVICE_NAME = 'notify';
export const LOCK_FILE = 'notify.lock';

/** Every pass through the lock loop costs one, the takeover pass included. */
const LOCK_TRIES = 3;

type Log = (...parts: string[]) => void;

export interface ServiceDeps {
  readonly os?: NodeJS.Platform;
  readonly platform?: (backend: NotifyOptions['backend'], log: Log) => Platform | null;
  readonly screen?: ScreenProbe;
  readonly clock?: Clock;
  readonly hostname?: () => string;
  readonly env?: NodeJS.ProcessEnv;
  /** Epoch ms of the last boot: a lock older than that names a pid that may have been reused. */
  readonly bootTime?: () => number;
}

const codeOf = (err: unknown): string | undefined => (err instanceof Error ? (err as NodeJS.ErrnoException).code : undefined);

type LockResult = { readonly taken: true } | { readonly taken: false; readonly holder: number };

/** The pid in the lock file, or null when the file is gone or holds no pid. */
function readPid(file: string): number | null {
  try {
    const n = Number.parseInt(fs.readFileSync(file, 'utf8').trim(), 10);
    return Number.isInteger(n) && n > 0 ? n : null;
  } catch {
    return null;
  }
}

function takeLock(file: string, bootMs: number): LockResult {
  for (let attempt = 0; attempt < LOCK_TRIES; attempt += 1) {
    try {
      const fd = fs.openSync(file, 'wx');
      try {
        fs.writeSync(fd, `${process.pid}\n`);
      } finally {
        fs.closeSync(fd);
      }
      return { taken: true };
    } catch (err) {
      if (codeOf(err) !== 'EEXIST') throw err;
    }
    let mtimeMs: number;
    try {
      mtimeMs = fs.statSync(file).mtimeMs;
    } catch {
      // It vanished between the open and the stat: that is a free lock, not an old one.
      continue;
    }
    const pid = readPid(file);
    if (pid !== null && pid !== process.pid && isAlive(pid) && mtimeMs >= bootMs) return { taken: false, holder: pid };
    // Dead, unreadable, our own leftover, or from before the last boot.
    fs.rmSync(file, { force: true });
  }
  throw new Error(`cannot take ${file}: another process keeps recreating it`);
}

/** Unlink the lock only while it still names us: after a takeover it is somebody else's. */
function releaseLock(file: string): void {
  if (readPid(file) === process.pid) fs.rmSync(file, { force: true });
}

function watchDir(dir: string, onName: (name: string | null) => void, log: Log): fs.FSWatcher | null {
  try {
    // Not persistent: the follower keeps the process alive, and a watcher left
    // open by mistake must not.
    const w = fs.watch(dir, { persistent: false }, (_event, name) => onName(name));
    w.on('error', (err) => {
      log('options watch failed', dir, describe(err));
      w.close();
    });
    return w;
  } catch (err) {
    log('options watch failed', dir, describe(err));
    return null;
  }
}

const finished = (): ServiceHandle => ({ drain: () => Promise.resolve(), stop: () => undefined, done: Promise.resolve() });

export function createNotifyService(deps: ServiceDeps = {}): ServiceDef {
  const osName = deps.os ?? process.platform;
  const env = deps.env ?? process.env;
  const bootTime = deps.bootTime ?? ((): number => Date.now() - os.uptime() * 1000);

  /** Everything after the lock is ours: options, platform, engine, watchers. */
  function begin(ctx: PluginContext, log: Log, lockFile: string): ServiceHandle {
    const defaults = NotifyOptionsSchema.parse({});
    let current: NotifyOptions = defaults;
    let problemsSeen = '';
    let optionsState = 'found';

    /** Apply what the file says now. A problem is logged once, however often the file is read. */
    function apply(r: OptionsResult<NotifyOptions>, running: string | null): void {
      if (!r.ok) {
        optionsState = 'invalid';
        const key = r.problems.join('\n');
        if (key !== problemsSeen) for (const p of r.problems) log(`options: ${p}`);
        problemsSeen = key;
        current = defaults;
        return;
      }
      problemsSeen = '';
      optionsState = r.found ? 'found' : 'not found';
      if (JSON.stringify(r.value) === JSON.stringify(current)) return;
      current = r.value;
      if (running !== null) {
        log('options reloaded');
        if (r.value.backend !== running) log('backend changes take effect after a restart (tagents notify install)');
      }
    }

    const load = (): OptionsResult<NotifyOptions> => loadPluginOptions(ctx.configDir, SERVICE_NAME, NotifyOptionsSchema);
    const first = load();
    apply(first, null);

    const backend = current.backend;
    const leave = (why: string): ServiceHandle => {
      log(`${why}; exiting`);
      releaseLock(lockFile);
      return finished();
    };

    const platform = (deps.platform ?? ((b, l) => pickPlatform(osName, b, { log: l, env })))(backend, log);
    if (platform === null) return leave('backend none: nothing to post');
    if (platform.name === 'unsupported') return leave(`no notification backend for ${osName} yet`);

    const engine = createEngine({
      feed: ctx.agents,
      notifier: platform.notifier,
      options: () => current,
      screen: deps.screen ?? tmuxScreen(),
      clock: deps.clock ?? systemClock,
      log,
      tagents: tagentsScript(env),
      hostname: deps.hostname ?? os.hostname,
      env,
    });
    engine.start();
    log('started', `pid ${process.pid}`, `backend ${platform.name}`, `options ${first.file} (${optionsState})`);

    const watchers: fs.FSWatcher[] = [];
    const optionsName = path.basename(pluginOptionsFile(ctx.configDir, SERVICE_NAME));
    const reload = (name: string | null): void => {
      if (name === null || name === optionsName) apply(load(), backend);
    };
    const watchPlugins = (dir: string): void => {
      const w = watchDir(dir, reload, log);
      if (w !== null) watchers.push(w);
    };
    // ~/.config/tagents is usually a symlink into a dotfiles repo, and a watch
    // on the link sees nothing: the real directory is what changes.
    try {
      watchPlugins(fs.realpathSync(path.join(ctx.configDir, PLUGIN_OPTIONS_DIR)));
    } catch {
      let realConfig: string | null = null;
      try {
        realConfig = fs.realpathSync(ctx.configDir);
      } catch {
        log(`options reload is off: ${ctx.configDir} does not exist`);
      }
      if (realConfig !== null) {
        const waiting: fs.FSWatcher | null = watchDir(
          realConfig,
          (name) => {
            if (waiting === null || (name !== null && name !== PLUGIN_OPTIONS_DIR)) return;
            let real: string;
            try {
              real = fs.realpathSync(path.join(ctx.configDir, PLUGIN_OPTIONS_DIR));
              if (!fs.statSync(real).isDirectory()) return;
            } catch {
              return;
            }
            waiting.close();
            watchers.splice(watchers.indexOf(waiting), 1);
            watchPlugins(real);
            // The file may have come with the directory.
            apply(load(), backend);
          },
          log
        );
        if (waiting !== null) watchers.push(waiting);
      }
    }

    let stopped = false;
    let finish: () => void = () => undefined;
    const done = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const stop = (reason?: string): void => {
      if (stopped) return;
      stopped = true;
      log(`stopping (${reason ?? 'stop'})`);
      for (const w of watchers.splice(0)) w.close();
      engine.stop();
      releaseLock(lockFile);
      finish();
    };
    return {
      drain: () => {
        stop('drain');
        return Promise.resolve();
      },
      stop,
      done,
    };
  }

  return {
    name: SERVICE_NAME,
    async start(ctx: PluginContext): Promise<ServiceHandle> {
      const log: Log = (...p) => ctx.log(new Date().toISOString(), ...p);
      fs.mkdirSync(ctx.agents.dir, { recursive: true });
      const lockFile = path.join(ctx.agents.dir, LOCK_FILE);
      const lock = takeLock(lockFile, bootTime());
      if (!lock.taken) {
        log(`another notify service holds ${lockFile} (pid ${lock.holder}); exiting`);
        return finished();
      }
      try {
        return begin(ctx, log, lockFile);
      } catch (err) {
        releaseLock(lockFile);
        throw err;
      }
    },
  };
}
