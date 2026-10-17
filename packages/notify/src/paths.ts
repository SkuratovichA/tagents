// Every path that is relative to the package, from one module.
//
// It sits directly under `src/` so that `new URL('..', import.meta.url)` is
// `packages/notify/` both when the file runs from `src/` (tests) and from
// `dist/` (installed); a file one level deeper would resolve differently in
// the two trees.
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const PACKAGE_DIR: string = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
export const BUILD_SCRIPT: string = path.join(PACKAGE_DIR, 'macos', 'build.sh');
export const MAIN_JS: string = path.join(PACKAGE_DIR, 'dist', 'main.js');
export const LAUNCHD_LABEL = 'io.github.skuratovicha.tagents-notify';

/** The `tagents` launcher script: `TA_NOTIFY_TAGENTS` when set, else the one at the repo root. */
export function tagentsScript(env: NodeJS.ProcessEnv = process.env): string {
  const o = env['TA_NOTIFY_TAGENTS'];
  return o !== undefined && o !== '' ? o : path.join(PACKAGE_DIR, '..', '..', 'tagents');
}

/** The helper app: `TA_NOTIFY_APP` when set, else the per-user Application Support copy. */
export function appPath(env: NodeJS.ProcessEnv = process.env, home: string = os.homedir()): string {
  const o = env['TA_NOTIFY_APP'];
  return o !== undefined && o !== ''
    ? o
    : path.join(home, 'Library', 'Application Support', 'tagents', 'TagentsNotify.app');
}

export function plistPath(home: string = os.homedir()): string {
  return path.join(home, 'Library', 'LaunchAgents', `${LAUNCHD_LABEL}.plist`);
}

export function logPath(home: string = os.homedir()): string {
  return path.join(home, 'Library', 'Logs', 'tagents', 'notify.log');
}
