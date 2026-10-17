// The doubles every test in this package leans on: a feed, a notifier that
// records, a clock whose time the test sets, and a screen probe that answers
// from a table.
//
// The clock is the one worth reading. A real `setTimeout` does not count the
// time the Mac spent asleep, while the prompt cache's TTL does, so the engine
// re-reads the wall clock on every wake. To test that, the fake clock keeps two
// things apart: `advance` walks time forward and runs the timers that fall
// inside it, in order, the way a running process would see it, while `jump`
// moves the wall clock without running anything, the way a sleep does. After a
// jump, `advance(0)` runs what is overdue, which is what the OS does on wake.
import {
  tmpDir,
  type AgentEvent,
  type AgentFeed,
  type AgentStateRow,
  type EventFollower,
} from '@tagents/core';
import type { Clock } from '../src/clock.ts';
import type { Notice, Notifier, PostResult } from '../src/notifier.ts';
import { NotifyOptionsSchema, type NotifyOptions } from '../src/options.ts';
import type { Screen, ScreenProbe } from '../src/screen.ts';

/** A round number of epoch milliseconds, so row seconds convert without a remainder. */
export const T0 = 1_700_000_000_000;
export const MIN = 60_000;

export function event(over: Partial<AgentEvent> = {}): AgentEvent {
  return {
    at: T0,
    event: 'Stop',
    key: '12',
    sessionId: 'sess-1',
    agentId: '',
    pane: '%12',
    cwd: '/work/proj',
    transcript: '',
    configDir: '',
    tool: '',
    sub: '',
    text: '',
    label: '',
    ...over,
  };
}

export function stateRow(over: Partial<AgentStateRow> = {}): AgentStateRow {
  return {
    key: '12',
    at: T0 / 1000,
    state: 'done',
    sessionId: 'sess-1',
    cwd: '/work/proj',
    transcript: '',
    detail: '',
    configDir: null,
    hasConfigDir: false,
    pid: null,
    ...over,
  };
}

/** The options a file with `raw` in it would give; `{}` is every default. */
export function options(raw: unknown = {}): NotifyOptions {
  return NotifyOptionsSchema.parse(raw);
}

export interface FakeFeed extends AgentFeed {
  rows: AgentStateRow[];
  followers: number;
  closed: boolean;
  emit(e: AgentEvent): void;
}

export function fakeFeed(dir: string = tmpDir('notify-feed')): FakeFeed {
  let listener: ((e: AgentEvent) => void) | null = null;
  const feed: FakeFeed = {
    dir,
    rows: [],
    followers: 0,
    closed: false,
    states: () => [...feed.rows],
    follow(onEvent): EventFollower {
      listener = onEvent;
      feed.followers++;
      return {
        close() {
          feed.closed = true;
        },
      };
    },
    emit(e) {
      listener?.(e);
    },
  };
  return feed;
}

export type Call =
  | { readonly op: 'post'; readonly notice: Notice }
  | { readonly op: 'withdraw'; readonly id: string };

export interface RecordingNotifier extends Notifier {
  readonly calls: Call[];
  readonly posts: Notice[];
  readonly withdrawn: string[];
  /** What the next posts answer. */
  result: PostResult;
  /** The next `n` posts throw instead of answering. */
  failPosts(n: number): void;
  /** Hold every post until `release()`: a notifier that is slow to answer. */
  hold(): { release(): void };
}

export function recordingNotifier(): RecordingNotifier {
  let failing = 0;
  let gate: Promise<void> | null = null;
  const n: RecordingNotifier = {
    name: 'recording',
    calls: [],
    posts: [],
    withdrawn: [],
    result: { shown: true },
    failPosts(count) {
      failing = count;
    },
    hold() {
      let release!: () => void;
      gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      return {
        release: () => {
          gate = null;
          release();
        },
      };
    },
    async post(notice) {
      if (gate) await gate;
      if (failing > 0) {
        failing--;
        throw new Error('the notification center is not answering');
      }
      n.calls.push({ op: 'post', notice });
      n.posts.push(notice);
      return n.result;
    },
    async withdraw(id) {
      n.calls.push({ op: 'withdraw', id });
      n.withdrawn.push(id);
    },
  };
  return n;
}

export interface FakeClock extends Clock {
  /** Timers waiting to fire. */
  pending(): number;
  /** Milliseconds until the earliest timer, or null when none waits. */
  nextDelay(): number | null;
  /** Walk time forward by `ms`, running the timers that fall inside it in order. */
  advance(ms: number): void;
  /** Move the wall clock by `ms` without running a timer: the Mac slept. */
  jump(ms: number): void;
}

export function fakeClock(start: number = T0): FakeClock {
  let now = start;
  let seq = 0;
  const timers = new Map<number, { at: number; fn: () => void }>();
  const earliest = (): [number, { at: number; fn: () => void }] | null => {
    let best: [number, { at: number; fn: () => void }] | null = null;
    for (const entry of timers) if (best === null || entry[1].at < best[1].at) best = entry;
    return best;
  };
  return {
    now: () => now,
    after(ms, fn) {
      const id = seq++;
      timers.set(id, { at: now + ms, fn });
      return () => {
        timers.delete(id);
      };
    },
    pending: () => timers.size,
    nextDelay() {
      const e = earliest();
      return e === null ? null : e[1].at - now;
    },
    advance(ms) {
      const target = now + ms;
      for (;;) {
        const e = earliest();
        if (e === null || e[1].at > target) break;
        timers.delete(e[0]);
        now = Math.max(now, e[1].at);
        e[1].fn();
      }
      now = target;
    },
    jump(ms) {
      now += ms;
    },
  };
}

export interface FakeScreen extends ScreenProbe {
  readonly probed: string[];
}

/** A probe answering from `table`; a pane that is not in it is "no such pane". */
export function fakeScreen(table: Readonly<Record<string, Screen | null>> = {}): FakeScreen {
  const probed: string[] = [];
  const probe = (pane: string): Promise<Screen | null> => {
    probed.push(pane);
    return Promise.resolve(table[pane] ?? null);
  };
  return Object.assign(probe, { probed });
}
