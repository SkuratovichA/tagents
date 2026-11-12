// The notify service's lock file and what is needed to judge it: who the lock names, and whether that process is still the one that wrote it. The service itself is the Rust binary's (`tagents-core notify run`), which takes the lock; `status` and `install` here only read it.
import fs from 'node:fs';
import os from 'node:os';
import { isAlive } from '@tagents/core';
import { execText, type Exec } from './exec.ts';

export const SERVICE_NAME = 'notify';
export const LOCK_FILE = 'notify.lock';

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

/**
 * What the lock file says now, in either format (`<pid>` or `<pid> <start time>`);
 * null when the file is gone. Whether the named process is still the holder is
 * not decided here: that takes the start time of the live pid, and the service
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
