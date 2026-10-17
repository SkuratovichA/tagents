// Every path that is relative to the package, from one module.
//
// It sits directly under `src/` so that `new URL('..', import.meta.url)` is
// `packages/notify/` both when the file runs from `src/` (tests) and from
// `dist/` (installed); a file one level deeper would resolve differently in
// the two trees.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOnPath } from '@tagents/core';

export const PACKAGE_DIR: string = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
export const BUILD_SCRIPT: string = path.join(PACKAGE_DIR, 'macos', 'build.sh');
export const MAIN_JS: string = path.join(PACKAGE_DIR, 'dist', 'main.js');
/**
 * The helper app's CFBundleIdentifier (`macos/Info.plist`), which System Settings knows its notification settings by.
 * The LaunchAgent's label is the same string, so that Login Items files the job under the app.
 */
export const BUNDLE_ID = 'io.github.skuratovicha.tagents-notify';
/** The icon an unset `icon` option looks for, in the directory that holds the app. */
export const DEFAULT_ICON_FILE = 'notify-icon.png';

/**
 * The `tagents` script a click runs: `TA_NOTIFY_TAGENTS` when set, else the first `tagents` on PATH, as found (a symlink
 * stays the symlink), else the one at the repo root. tagents re-installs the global tmux focus hooks pointing at
 * whichever script ran, so a click must run the one the person's dashboard runs, which is the one on their PATH.
 */
export function tagentsScript(env: NodeJS.ProcessEnv = process.env): string {
  const o = env['TA_NOTIFY_TAGENTS'];
  if (o !== undefined && o !== '') return o;
  const onPath = env['PATH'] === undefined ? null : findOnPath('tagents', env['PATH']);
  return onPath ?? path.join(PACKAGE_DIR, '..', '..', 'tagents');
}

/** The helper app: `TA_NOTIFY_APP` when set, else the per-user Application Support copy. */
export function appPath(env: NodeJS.ProcessEnv = process.env, home: string = os.homedir()): string {
  const o = env['TA_NOTIFY_APP'];
  return o !== undefined && o !== ''
    ? o
    : path.join(home, 'Library', 'Application Support', 'tagents', 'TagentsNotify.app');
}

/** A regular file this process may read; a symlink is followed, so one that dangles is not a file. */
const readableFile = (file: string): boolean => {
  try {
    if (!fs.statSync(file).isFile()) return false;
    fs.accessSync(file, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
};

export interface ResolvedIcon {
  /** The PNG the app is built from; null: build it without an icon. */
  readonly file: string | null;
  /** Set when the `icon` option names something that is not a file. */
  readonly problem?: string;
}

/**
 * The icon the `icon` option asks for: an absolute path, `~/` under `home`, or
 * a path relative to the directory of the options file (the cwd of a LaunchAgent
 * says nothing about where the person wrote it). Unset, it is `notify-icon.png`
 * next to the app, when that exists. An option that names no file is a problem
 * to show, not an error: the app is then built without an icon.
 */
export function resolveIcon(
  icon: string | undefined,
  optionsFile: string,
  env: NodeJS.ProcessEnv = process.env,
  home: string = os.homedir()
): ResolvedIcon {
  if (icon === undefined) {
    const beside = path.join(path.dirname(appPath(env, home)), DEFAULT_ICON_FILE);
    return { file: readableFile(beside) ? beside : null };
  }
  const file = icon.startsWith('~/')
    ? path.join(home, icon.slice(2))
    : path.resolve(path.dirname(optionsFile), icon);
  if (readableFile(file)) return { file };
  const why = !fs.existsSync(file) ? 'does not exist' : fs.statSync(file).isFile() ? 'is not readable' : 'is not a file';
  return { file: null, problem: `icon ${file} ${why}; the app is built without an icon` };
}

export function plistPath(home: string = os.homedir()): string {
  return path.join(home, 'Library', 'LaunchAgents', `${BUNDLE_ID}.plist`);
}

export function logPath(home: string = os.homedir()): string {
  return path.join(home, 'Library', 'Logs', 'tagents', 'notify.log');
}
