// The prompt-cache scheduler: "wake me when this session has been idle long
// enough", for any number of sessions, with at most one timer.
//
// The timer sleeps at most five minutes at a time and the wall clock is read
// again on every wake. That is the whole design. The cache's TTL runs in wall
// time, while a Node timer does not count the time the Mac spent asleep, so one
// long timeout set for "47 minutes from now" fires up to hours late after a lid
// close. A short sleep bounds the lateness to one tick after the machine
// wakes, and reading `clock.now()` instead of counting ticks means the due
// check is right whatever happened in between.
import type { Clock } from './clock.ts';

export const MAX_SLEEP_MS = 5 * 60_000;

export interface Deadlines {
  /** Wake `onDue` for `key` at `dueAt`; arming a key again replaces its deadline. */
  arm(key: string, idleSince: number, dueAt: number): void;
  cancel(key: string): void;
  /** Stop for good: no timer is left, and nothing fires or arms afterwards. */
  close(): void;
  /** How many keys are waiting. */
  armed(): number;
}

interface Entry {
  readonly idleSince: number;
  readonly dueAt: number;
}

export function createDeadlines(o: {
  readonly clock: Clock;
  readonly onDue: (key: string, idleSince: number) => void;
}): Deadlines {
  const waiting = new Map<string, Entry>();
  let cancelTimer: (() => void) | null = null;
  let closed = false;

  function clearTimer(): void {
    cancelTimer?.();
    cancelTimer = null;
  }

  // The one place a timer is set. It runs after every change to the map, so
  // "one pending timer at most" and "none when nothing waits" hold by
  // construction and not by every caller remembering to.
  function schedule(): void {
    clearTimer();
    if (closed || waiting.size === 0) return;
    let earliest = Infinity;
    for (const e of waiting.values()) earliest = Math.min(earliest, e.dueAt);
    const wait = Math.min(Math.max(earliest - o.clock.now(), 0), MAX_SLEEP_MS);
    cancelTimer = o.clock.after(wait, wake);
  }

  function wake(): void {
    cancelTimer = null;
    if (closed) return;
    const now = o.clock.now();
    const ready = [...waiting].filter(([, e]) => e.dueAt <= now);
    try {
      for (const [key, entry] of ready) {
        // A callback may have cancelled or re-armed a key that is later in this
        // very list, and the list is a snapshot.
        if (closed) return;
        if (waiting.get(key) !== entry) continue;
        waiting.delete(key);
        o.onDue(key, entry.idleSince);
      }
    } finally {
      schedule();
    }
  }

  return {
    arm(key, idleSince, dueAt) {
      if (closed) return;
      waiting.set(key, { idleSince, dueAt });
      schedule();
    },
    cancel(key) {
      if (waiting.delete(key)) schedule();
    },
    close() {
      closed = true;
      waiting.clear();
      clearTimer();
    },
    armed: () => waiting.size,
  };
}
