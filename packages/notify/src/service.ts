// The long-running service: one process per machine that follows the agents'
// event stream and posts what the engine decides to post.
//
// What makes it a service and not a loop is what it holds. A lock file in the
// state dir keeps two of them from posting every notice twice. The options file
// is watched, not polled, so a change reaches the running engine and an idle
// Mac costs nothing. And stopping it leaves nothing behind: the stream switch
// the hook reads goes off with the follower, the posts in flight finish, the
// lock is released, `done` resolves.
import { randomBytes } from 'node:crypto';
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
import { execText, type Exec } from './exec.ts';
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
  /** When a process started, as text, or null when that cannot be told. Asked only to take or judge the lock. */
  readonly processStart?: ProcessStart;
}

export type ProcessStart = (pid: number) => Promise<string | null>;

/** Epoch ms of the last boot: a lock older than that names a pid that may have been reused. */
export const systemBootMs = (): number => Date.now() - os.uptime() * 1000;

/**
 * `ps -o lstart=` for one pid, with a locale, UTC and no other environment: the
 * text is compared between two processes that may be started from different
 * places and at different times. launchd has no LANG and a terminal has one, a
 * TZ exported in a shell changes the clock ps prints, and `lstart` is local time
 * in any case, so a Mac that changes zone while its owner travels would print
 * the same start differently. The two texts must read alike. Null when ps
 * cannot say.
 */
export function psProcessStart(exec: Exec = execText): ProcessStart {
  return async (pid) => {
    try {
      const r = await exec('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], { timeoutMs: 2000, env: { LC_ALL: 'C', TZ: 'UTC' } });
      const text = r.stdout.trim();
      return r.code === 0 && text !== '' ? text : null;
    } catch {
      return null;
    }
  };
}

const codeOf = (err: unknown): string | undefined => (err instanceof Error ? (err as NodeJS.ErrnoException).code : undefined);

export type LockResult = { readonly taken: true } | { readonly taken: false; readonly holder: number };

/** Who a lock names. `started` is null for a lock written before start times were recorded, or when ps could not tell. */
export interface LockHolder {
  readonly pid: number;
  readonly started: string | null;
}

export interface LockDeps {
  readonly self: LockHolder;
  readonly bootMs: number;
  readonly processStart: ProcessStart;
}

/** A lock file as read: its text, whom it names, and when it was written. */
export interface LockContent {
  /** The file's text exactly as read: two reads are the same lock only when this is equal. */
  readonly raw: string;
  /** The holder's pid; null when the file names none (empty or not a pid). */
  readonly pid: number | null;
  /** The holder's start time as ps printed it; null for the first format, a bare pid. */
  readonly started: string | null;
  readonly mtimeMs: number;
}

/** `<pid> <start time>`, or the bare `<pid>` of the first format, which stays readable. */
const LOCK_LINE = /^(\d+)(?:[ \t]+(\S[^\n]*))?$/;

const render = (h: LockHolder): string => `${h.pid}${h.started === null ? '' : ` ${h.started}`}\n`;

/**
 * What the lock file says now, in either format (`<pid>` or `<pid> <start time>`);
 * null when the file is gone. Whether the named process is still the holder is
 * not decided here: that takes the start time of the live pid, and `takeLock`
 * asks for it.
 */
export function readLock(file: string): LockContent | null {
  try {
    const mtimeMs = fs.statSync(file).mtimeMs;
    const raw = fs.readFileSync(file, 'utf8');
    const m = LOCK_LINE.exec(raw.trim());
    const pid = m === null ? null : Number(m[1]);
    return {
      raw,
      pid: pid !== null && Number.isSafeInteger(pid) && pid > 0 ? pid : null,
      started: m?.[2]?.trim() ?? null,
      mtimeMs,
    };
  } catch {
    return null;
  }
}

/**
 * Create the lock whole or not at all. The text goes into a temp file in the
 * same directory first and `link` puts it at the lock path, failing when
 * something is there: an `open` with `wx` followed by a `write` leaves the lock
 * empty for a moment, and a second process reading it then takes "no pid" for a
 * stale lock and removes the file that is being written.
 */
function createLock(file: string, self: LockHolder): boolean {
  const tmp = `${file}.${self.pid}.${randomBytes(4).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(tmp, render(self), { flag: 'wx' });
    fs.linkSync(tmp, file);
    return true;
  } catch (err) {
    if (codeOf(err) === 'EEXIST') return false;
    throw err;
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

/**
 * Is the process the lock names still the one that wrote it? A live pid is not
 * enough: pids are reused, and a service that took a stranger for its twin would
 * log "another service holds the lock" and stay off for good. The recorded start
 * time tells them apart. A lock without one, or a ps that cannot answer, falls
 * back on the lock's age against the last boot, which only catches a reboot.
 */
export async function holds(seen: LockContent, d: LockDeps): Promise<boolean> {
  if (seen.pid === null || seen.pid === d.self.pid || !isAlive(seen.pid)) return false;
  if (seen.started !== null) {
    const now = await d.processStart(seen.pid);
    if (now !== null) return now === seen.started;
  }
  return seen.mtimeMs >= d.bootMs;
}

/** A temp file `createLock` makes lives for the length of a write and a link; a minute is a crash. */
const TEMP_MAX_AGE_MS = 60_000;

/**
 * A process that dies between writing its temp file and linking it leaves the
 * file for good. Remove the temp files whose process is gone, or that are older
 * than a minute (a reused pid), with one look at the directory, when a lock is
 * taken and not otherwise.
 */
function sweepTempLocks(file: string): void {
  const base = path.basename(file);
  let names: string[];
  try {
    names = fs.readdirSync(path.dirname(file));
  } catch {
    return;
  }
  for (const name of names) {
    if (!name.startsWith(`${base}.`) || !name.endsWith('.tmp')) continue;
    const m = /^(\d+)\.[0-9a-f]{8}$/.exec(name.slice(base.length + 1, -'.tmp'.length));
    if (m === null) continue;
    const tmp = path.join(path.dirname(file), name);
    try {
      if (!isAlive(Number(m[1])) || Date.now() - fs.statSync(tmp).mtimeMs > TEMP_MAX_AGE_MS) fs.rmSync(tmp, { force: true });
    } catch {
      // Gone already, or not ours to remove: the next lock taken looks again.
    }
  }
}

export async function takeLock(file: string, d: LockDeps): Promise<LockResult> {
  sweepTempLocks(file);
  for (let attempt = 0; attempt < LOCK_TRIES; attempt += 1) {
    if (createLock(file, d.self)) return { taken: true };
    const seen = readLock(file);
    // It vanished between the link and the read: that is a free lock, not an old one.
    if (seen === null) continue;
    if (seen.pid !== null && (await holds(seen, d))) return { taken: false, holder: seen.pid };
    // Dead, unreadable, our own leftover, a reused pid, or from before the last boot. Judging
    // took a ps call, and meanwhile another process may have judged the same lock and put its
    // own there: remove the file only while it still says what was judged.
    if (readLock(file)?.raw === seen.raw) fs.rmSync(file, { force: true });
  }
  throw new Error(`cannot take ${file}: another process keeps recreating it`);
}

/** Unlink the lock only while it still names us: after a takeover it is somebody else's. */
function releaseLock(file: string): void {
  if (readLock(file)?.pid === process.pid) fs.rmSync(file, { force: true });
}

/** `releaseLock` for the paths that go on afterwards whatever happens: a lock that stays is logged, and never skips what follows. */
function releaseQuietly(file: string, log: Log): void {
  try {
    releaseLock(file);
  } catch (err) {
    log('could not release the lock', file, describe(err));
  }
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
  const bootTime = deps.bootTime ?? systemBootMs;
  const processStart = deps.processStart ?? psProcessStart();

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
      releaseQuietly(lockFile, log);
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

    const watchers: fs.FSWatcher[] = [];
    const optionsName = path.basename(pluginOptionsFile(ctx.configDir, SERVICE_NAME));
    const reload = (name: string | null): void => {
      if (name === null || name === optionsName) apply(load(), backend);
    };
    const watchPlugins = (dir: string): void => {
      const w = watchDir(dir, reload, log);
      if (w === null) return;
      watchers.push(w);
      // A write between the read at the top and this arming raised no event: read once more, now that
      // events would come. An unchanged file is ignored by `apply`, a changed one is one reload.
      apply(load(), backend);
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
        let adopted = false;
        /**
         * The directory exists now: watch it instead of its parent, and read the file that may have
         * come with it. Idempotent, because it runs for the event and for the look after the arming,
         * and a rename and a change both arrive for one mkdir.
         */
        const adopt = (): void => {
          if (adopted) return;
          let real: string;
          try {
            real = fs.realpathSync(path.join(ctx.configDir, PLUGIN_OPTIONS_DIR));
            if (!fs.statSync(real).isDirectory()) return;
          } catch {
            return;
          }
          adopted = true;
          if (waiting !== null) {
            waiting.close();
            watchers.splice(watchers.indexOf(waiting), 1);
          }
          watchPlugins(real);
        };
        const waiting: fs.FSWatcher | null = watchDir(
          realConfig,
          (name) => {
            if (name === null || name === PLUGIN_OPTIONS_DIR) adopt();
          },
          log
        );
        if (waiting !== null) {
          watchers.push(waiting);
          // A directory made after the look that failed above and before this watch was armed raised
          // no event, and nothing would ever announce it: look once more, now that events would come.
          adopt();
        }
      }
    }

    // Last, because the line marks the end of start: whoever waits for it, a reader of the log or a
    // test that signals the process, finds the lock, the stream, the engine and the watchers all up.
    log('started', `pid ${process.pid}`, `backend ${platform.name}`, `options ${first.file} (${optionsState})`);

    let stopped = false;
    let finish: () => void = () => undefined;
    const done = new Promise<void>((resolve) => {
      finish = resolve;
    });
    // Stopping is two steps. The engine stops taking events at once, and hands back the posts it has
    // in flight: a notice half posted when the process exits is a notice lost. The lock stays until
    // they have settled, so a restart cannot overlap them, and `done` resolves after it is released.
    const stop = (reason?: string): void => {
      if (stopped) return;
      stopped = true;
      log(`stopping (${reason ?? 'stop'})`);
      for (const w of watchers.splice(0)) w.close();
      engine
        .stop()
        .catch((err: unknown) => log('drain failed', describe(err)))
        .finally(() => {
          releaseQuietly(lockFile, log);
          finish();
        });
    };
    return {
      drain: () => {
        stop('drain');
        return done;
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
      const lock = await takeLock(lockFile, {
        self: { pid: process.pid, started: await processStart(process.pid) },
        bootMs: bootTime(),
        processStart,
      });
      if (!lock.taken) {
        log(`another notify service holds ${lockFile} (pid ${lock.holder}); exiting`);
        return finished();
      }
      try {
        return begin(ctx, log, lockFile);
      } catch (err) {
        releaseQuietly(lockFile, log);
        throw err;
      }
    },
  };
}
