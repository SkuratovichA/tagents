// The event stream hooks/tmux-agent-state.sh appends to while the switch is on.
//
// The hook only writes <state dir>/events.tsv while <state dir>/events.on
// exists, one tab separated line per event, written with a single O_APPEND
// printf and terminated by a newline. This module reads that file back:
// parseEventLine for one line, followAgentEvents for the file as it grows, and
// createAgentFeed for what a plugin holds (the state rows plus the stream, with
// the switch flipped for as long as somebody listens).
//
// UNITS. AgentEvent.at is epoch MILLISECONDS (the hook writes seconds, the
// parser multiplies), while AgentStateRow.at in agent-state.ts is epoch SECONDS.
// A consumer that arms a deadline from both must convert one of them.
//
// The follower never polls. It holds the file open, watches the FILE (kqueue on
// macOS, so it wakes on appends to events.tsv and not on the state records
// written next to it) and on each wake reads from its offset to the end of the
// file. Its one timer is the 2 s grace after it rotated the file itself.
import fs from 'node:fs';
import path from 'node:path';
import { readAgentState, stateDir, type AgentStateRow } from './agent-state.ts';

export const EVENTS_FILE = 'events.tsv';
export const EVENTS_SWITCH = 'events.on';
export const EVENTS_ROTATE_BYTES = 1_048_576;

const HOOK_EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'Notification',
  'Stop',
  'SubagentStop',
  'SessionEnd',
] as const;

export type AgentHookEvent = (typeof HOOK_EVENTS)[number];

const HOOK_EVENT_NAMES: ReadonlySet<string> = new Set(HOOK_EVENTS);

function isHookEvent(s: string): s is AgentHookEvent {
  return HOOK_EVENT_NAMES.has(s);
}

export interface AgentEvent {
  /** Epoch MILLISECONDS. AgentStateRow.at is epoch seconds. */
  readonly at: number;
  readonly event: AgentHookEvent;
  /** The pane number without its '%', or 's-<session id>' for a session with no pane. */
  readonly key: string;
  readonly sessionId: string;
  /** '' for the main agent. */
  readonly agentId: string;
  /** '%12', or '' when the session has no pane. */
  readonly pane: string;
  readonly cwd: string;
  readonly transcript: string;
  /** CLAUDE_CONFIG_DIR of the session ('' = the default account). */
  readonly configDir: string;
  readonly tool: string;
  readonly sub: string;
  readonly text: string;
  /** TA_LABEL. */
  readonly label: string;
}

const TAB = '\t';
const FIELDS = 13;

/**
 * One line of events.tsv. null when the line is malformed (fewer than 13 fields,
 * an `at` that is not a number) or names an event the hook does not write. A
 * trailing '\r' is tolerated, and so is a newer hook with more than 13 fields.
 */
export function parseEventLine(line: string): AgentEvent | null {
  const f = line.replace(/\r$/, '').split(TAB);
  if (f.length < FIELDS) return null;
  const rawAt = f[0] ?? '';
  const at = Number(rawAt);
  const event = f[1] ?? '';
  if (rawAt.trim() === '' || !Number.isFinite(at) || !isHookEvent(event)) return null;
  return {
    at: at * 1000,
    event,
    key: f[2] ?? '',
    sessionId: f[3] ?? '',
    agentId: f[4] ?? '',
    pane: f[5] ?? '',
    cwd: f[6] ?? '',
    transcript: f[7] ?? '',
    configDir: f[8] ?? '',
    tool: f[9] ?? '',
    sub: f[10] ?? '',
    text: f[11] ?? '',
    label: f[12] ?? '',
  };
}

/** Create the file if it is missing, never touch one that exists. */
function touch(file: string): void {
  fs.closeSync(fs.openSync(file, 'a', 0o600));
}

export function eventsOn(dir: string = stateDir()): boolean {
  return fs.existsSync(path.join(dir, EVENTS_SWITCH));
}

/**
 * on: create events.on, and an empty events.tsv when there is none, so a
 * follower started a moment later has a file to watch. off: remove events.on
 * and nothing else — the log stays for whoever reads it next.
 */
export function setEventsOn(on: boolean, dir: string = stateDir()): void {
  if (on) {
    fs.mkdirSync(dir, { recursive: true });
    touch(path.join(dir, EVENTS_SWITCH));
    touch(path.join(dir, EVENTS_FILE));
  } else {
    fs.rmSync(path.join(dir, EVENTS_SWITCH), { force: true });
  }
}

export interface EventFollower {
  /** Idempotent. Nothing is delivered after it, and no timer or handle is left. */
  close(): void;
}

export interface FollowOptions {
  /** Default stateDir(). */
  readonly dir?: string;
  /**
   * Where a failed read, a watcher error and an exception thrown by onEvent go.
   * Without it they are dropped: a follower that dies on one bad wake is worse
   * than one that misses it.
   */
  readonly onError?: (e: Error) => void;
  /** Default EVENTS_ROTATE_BYTES. */
  readonly rotateBytes?: number;
}

/** How long the old file stays open after the follower rotated it. */
const ROTATE_GRACE_MS = 2000;
const CHUNK_BYTES = 64 * 1024;
const NO_BYTES = Buffer.alloc(0);

/** An open file and how far into it the follower has read. */
interface Cursor {
  readonly fd: number;
  readonly ino: number;
  offset: number;
  /** The bytes after the last newline. Bytes, not text: a read can end mid-character. */
  rest: Buffer;
}

function closeQuietly(fd: number): void {
  try {
    fs.closeSync(fd);
  } catch {
    // already gone: nothing left to release
  }
}

/**
 * Deliver every event appended to events.tsv from now on, once each, in file
 * order. Starts at the current end of the file (no backlog), creating the file
 * and the directory when missing; a failure to do that, or to start the watcher,
 * throws.
 *
 * It survives truncation (size below the offset: restart at 0), replacement and
 * deletion (the old file is drained, then the path is reopened, created if need
 * be, from 0), and rotates the file itself once it is drained and has reached
 * rotateBytes: events.tsv becomes events.tsv.1, a fresh events.tsv is watched,
 * and the old file stays open for a 2 s grace so a hook that opened the old path
 * just before the rename still lands its line. A line that arrives through the
 * grace is delivered when the grace ends, so it can come after newer events from
 * the fresh file; each event carries its own `at`.
 *
 * Not detectable without polling: a truncation followed by growth beyond the old
 * offset before the follower wakes. The hook only appends and renames.
 *
 * The watcher is a persistent handle: close() is what lets the process exit.
 */
export function followAgentEvents(onEvent: (e: AgentEvent) => void, o: FollowOptions = {}): EventFollower {
  const dir = o.dir ?? stateDir();
  const rotateBytes = o.rotateBytes ?? EVENTS_ROTATE_BYTES;
  const file = path.join(dir, EVENTS_FILE);

  let closed = false;
  let watcher: fs.FSWatcher | null = null;
  let old: { readonly cursor: Cursor; readonly timer: NodeJS.Timeout } | null = null;

  const report = (e: unknown): void => {
    o.onError?.(e instanceof Error ? e : new Error(String(e)));
  };

  function openCursor(fromEnd: boolean): Cursor {
    fs.mkdirSync(dir, { recursive: true });
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_CREAT, 0o600);
    try {
      const st = fs.fstatSync(fd);
      return { fd, ino: st.ino, offset: fromEnd ? st.size : 0, rest: NO_BYTES };
    } catch (e) {
      closeQuietly(fd);
      throw e;
    }
  }

  function deliver(line: string): void {
    const event = parseEventLine(line);
    if (!event) return;
    try {
      onEvent(event);
    } catch (e) {
      report(e);
    }
  }

  /** Read [offset, size) of one file and deliver its complete lines. */
  function pump(c: Cursor): void {
    const size = fs.fstatSync(c.fd).size;
    if (size < c.offset) {
      c.offset = 0;
      c.rest = NO_BYTES;
    }
    while (!closed && c.offset < size) {
      const buf = Buffer.allocUnsafe(Math.min(CHUNK_BYTES, size - c.offset));
      const n = fs.readSync(c.fd, buf, 0, buf.length, c.offset);
      if (n === 0) break;
      c.offset += n;
      const data = c.rest.length > 0 ? Buffer.concat([c.rest, buf.subarray(0, n)]) : buf.subarray(0, n);
      const lastNewline = data.lastIndexOf(0x0a);
      if (lastNewline < 0) {
        c.rest = Buffer.from(data);
        continue;
      }
      c.rest = Buffer.from(data.subarray(lastNewline + 1));
      for (const line of data.toString('utf8', 0, lastNewline).split('\n')) {
        if (closed) return;
        deliver(line);
      }
    }
  }

  /** Watch the path, which must already name the file `cur` holds. */
  function watch(): void {
    watcher?.close();
    watcher = null;
    const w = fs.watch(file, drain);
    w.on('error', report);
    watcher = w;
  }

  function rewatch(): void {
    try {
      watch();
    } catch (e) {
      report(e);
    }
  }

  let cur = openCursor(true);
  try {
    watch();
  } catch (e) {
    closeQuietly(cur.fd);
    throw e;
  }
  // An append between the open above and the watcher arming raised no wake.
  queueMicrotask(drain);

  /** The path is gone or is a different file: finish the old one, follow the new one from 0. */
  function reopen(): void {
    const prev = cur;
    const next = openCursor(false);
    closeQuietly(prev.fd);
    cur = next;
    rewatch();
    drain();
  }

  function rotate(): void {
    fs.renameSync(file, `${file}.1`);
    // If this throws, `cur` is the renamed file and the next wake sees a new
    // inode at the path and reopens.
    const fresh = openCursor(false);
    old = { cursor: cur, timer: setTimeout(finishOld, ROTATE_GRACE_MS) };
    cur = fresh;
    rewatch();
    drain();
  }

  function finishOld(): void {
    const grace = old;
    old = null; // close the scope first, then drain: nothing scheduled from here can find it
    if (!grace || closed) return;
    try {
      pump(grace.cursor);
    } catch (e) {
      report(e);
    } finally {
      closeQuietly(grace.cursor.fd);
    }
  }

  function drain(): void {
    if (closed) return;
    try {
      pump(cur);
      if (closed) return;
      let now: fs.Stats | null = null;
      try {
        now = fs.statSync(file);
      } catch {
        // deleted, or moved away: handled below as a different file
      }
      if (!now || now.ino !== cur.ino) {
        reopen();
        return;
      }
      if (cur.offset >= rotateBytes && !old) rotate();
    } catch (e) {
      report(e);
    }
  }

  return {
    close(): void {
      if (closed) return;
      closed = true;
      watcher?.close();
      watcher = null;
      if (old) {
        clearTimeout(old.timer);
        closeQuietly(old.cursor.fd);
        old = null;
      }
      closeQuietly(cur.fd);
    },
  };
}

export interface AgentFeed {
  readonly dir: string;
  /** readAgentState(dir). Its `at` is epoch seconds; the events' is milliseconds. */
  states(): AgentStateRow[];
  /**
   * followAgentEvents on this directory, with the hook's switch on for as long as
   * any follower in this process is open: it flips on when the first one starts
   * and off when the last one closes. One follower process per machine is the
   * design (a lock in the notify plugin sees to it), so the count is per process.
   */
  follow(onEvent: (e: AgentEvent) => void, onError?: (e: Error) => void): EventFollower;
}

/** Open followers per state dir, across every feed of this process. */
const followersByDir = new Map<string, number>();

export function createAgentFeed(dir: string = stateDir()): AgentFeed {
  return {
    dir,
    states: () => readAgentState(dir),
    follow(onEvent, onError) {
      // The follower first: it creates the directory and the file, and starts at
      // the end of it, so nothing the hook writes once the switch is on is missed.
      const inner = followAgentEvents(onEvent, onError ? { dir, onError } : { dir });
      const count = followersByDir.get(dir) ?? 0;
      followersByDir.set(dir, count + 1);
      if (count === 0) {
        try {
          setEventsOn(true, dir);
        } catch (e) {
          followersByDir.delete(dir);
          inner.close();
          throw e;
        }
      }
      let open = true;
      return {
        close(): void {
          if (!open) return;
          open = false;
          inner.close();
          const left = (followersByDir.get(dir) ?? 1) - 1;
          if (left > 0) {
            followersByDir.set(dir, left);
            return;
          }
          followersByDir.delete(dir);
          setEventsOn(false, dir);
        },
      };
    },
  };
}
