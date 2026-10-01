// Keep the Mac from idling to sleep under a running turn.
//
// 01.10.2026: a turn started at 19:23Z on a MacBook on battery was killed at
// 21:00Z as "timed out after 90 min" having been awake for about five of those
// minutes — the rest was Deep Idle sleep, with a wake of 10-70 s every quarter
// hour. The driver now counts awake time only (claude-driver.ts); this holds an
// idle-sleep assertion for as long as the claude child lives, so the turn is not
// put to sleep in the first place.
//
// `caffeinate -i -w <pid>`: -i is "an assertion to prevent the system from idle
// sleeping", -w releases it "once the process exits" (man caffeinate). It is not
// a promise. -i does not keep a machine with a closed lid awake, and whether an
// assertion taken during a dark wake holds that wake is unverified. -s would
// block sleep outright, but it "is valid only when system is running on AC
// power", and the incident was on battery.
//
// Best effort by contract: a missing binary or a failed spawn is one log line,
// never a failed turn.
import { spawn as nodeSpawn, type ChildProcess, type SpawnOptions } from 'node:child_process';

/** The off switch: TA_KEEP_AWAKE=0 in the environment of the process running turns. */
export const KEEP_AWAKE_ENV = 'TA_KEEP_AWAKE';

/** child_process.spawn as far as holdAwake uses it — a test passes a fake. */
export type Spawner = (command: string, args: readonly string[], options: SpawnOptions) => ChildProcess;

/** Hold the machine awake while `pid` lives. Returns the release. Must not throw, and neither may the release. */
export type KeepAwake = (pid: number, log: (line: string) => void) => () => void;

/** On macOS, unless TA_KEEP_AWAKE=0. */
export function keepAwakeWanted(platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env): boolean {
  return platform === 'darwin' && env[KEEP_AWAKE_ENV] !== '0';
}

/** `caffeinate -i -w <pid>`: the assertion goes when `pid` does, or when the release kills it first. */
export function holdAwake(pid: number, log: (line: string) => void, spawn: Spawner = nodeSpawn): () => void {
  const failed = (why: string): void => log(`keep-awake: caffeinate failed (${why}) — the turn runs without it`);
  let child: ChildProcess;
  try {
    child = spawn('caffeinate', ['-i', '-w', String(pid)], { stdio: 'ignore' });
  } catch (e) {
    failed((e as Error).message);
    return () => undefined;
  }
  // ENOENT and friends arrive here, after the spawn, not as a throw.
  child.on('error', (e) => failed(e.message));
  // Nothing waits for it: -w ends it with the turn's child in any case.
  child.unref();
  return () => {
    try {
      child.kill();
    } catch {
      // Already gone: the assertion went with it.
    }
  };
}
