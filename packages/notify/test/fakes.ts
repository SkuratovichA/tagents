// The doubles every test in this package leans on: a feed, a notifier that
// records, a clock whose time the test sets, and a screen probe that answers
// from a table.
//
// The clock is core's `FakeClock`, from its testkit, and its sleeps are the ones
// worth reading. A real `setTimeout` does not count the time the Mac spent
// asleep, while the prompt cache's TTL does, so the engine re-reads the wall
// clock on every wake. `sleepPausingTimers` is that sleep, with a timer keeping
// the awake time it had left; `jump` and `sleepFiringOverdue` are the kind case,
// where every timer is overdue at the wake.
import fs from 'node:fs';
import {
  FakeClock,
  tmpDir,
  type AgentEvent,
  type AgentFeed,
  type AgentStateRow,
  type EventFollower,
} from '@tagents/core';
import type { Notice, Notifier, PostResult } from '../src/notifier.ts';
import { NotifyOptionsSchema, type NotifyOptions } from '../src/options.ts';
import type { NO_SUCH_PANE, Screen, ScreenProbe } from '../src/screen.ts';

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
    logFile: null,
    label: null,
    parentKey: null,
    parentSid: null,
    ...over,
  };
}

/** The options a file with `raw` in it would give; `{}` is every default. */
export function options(raw: unknown = {}): NotifyOptions {
  return NotifyOptionsSchema.parse(raw);
}

export interface FakeFeed extends AgentFeed {
  rows: AgentStateRow[];
  /** Followers opened so far. */
  followers: number;
  /** The latest follower is closed, by its caller or by dying. */
  closed: boolean;
  /** The next `n` calls to `follow` throw. */
  failFollows(n: number): void;
  emit(e: AgentEvent): void;
  /** The latest follower dies the way core's does: it closes itself, then reports once. */
  kill(reason?: string): void;
}

// A feed dir per rig keeps one test's labels and history out of the next one's,
// and a process per test file means the exit of this one is where they all go.
const feedDirs: string[] = [];
process.once('exit', () => {
  for (const dir of feedDirs) fs.rmSync(dir, { recursive: true, force: true });
});

function ownFeedDir(): string {
  const dir = tmpDir('notify-feed');
  feedDirs.push(dir);
  return dir;
}

/** A feed over `dir`, or over a temp dir of its own that is removed when the process exits. */
export function fakeFeed(dir: string = ownFeedDir()): FakeFeed {
  let listener: ((e: AgentEvent) => void) | null = null;
  let onDead: ((e: Error) => void) | null = null;
  let failing = 0;
  const feed: FakeFeed = {
    dir,
    rows: [],
    followers: 0,
    closed: false,
    states: () => [...feed.rows],
    failFollows(n) {
      failing = n;
    },
    follow(onEvent, _onError, dead): EventFollower {
      if (failing > 0) {
        failing--;
        throw new Error('the events file cannot be watched');
      }
      listener = onEvent;
      onDead = dead ?? null;
      feed.followers++;
      feed.closed = false;
      return {
        close() {
          feed.closed = true;
        },
      };
    },
    emit(e) {
      listener?.(e);
    },
    kill(reason = 'the watch failed') {
      feed.closed = true;
      listener = null;
      const report = onDead;
      onDead = null;
      report?.(new Error(reason));
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
  /** The next `n` posts throw `message` instead of answering. */
  failPosts(n: number, message?: string): void;
  /** Hold every post until `release()`: a notifier that is slow to answer. */
  hold(): { release(): void };
}

export function recordingNotifier(): RecordingNotifier {
  let failing = 0;
  let failure = 'the notification center is not answering';
  let gate: Promise<void> | null = null;
  const n: RecordingNotifier = {
    name: 'recording',
    calls: [],
    posts: [],
    withdrawn: [],
    result: { shown: true },
    failPosts(count, message = 'the notification center is not answering') {
      failing = count;
      failure = message;
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
        throw new Error(failure);
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

/** Core's fake clock, started at T0 so a state row's seconds convert without a remainder. */
export const fakeClock = (start: number = T0): FakeClock => new FakeClock(start);

export interface FakeScreen extends ScreenProbe {
  readonly probed: string[];
  /** Hold every probe until `release()`: a tmux that is slow to answer. */
  hold(): { release(): void };
}

/**
 * A probe answering from `table`. A pane that is not in it is one tmux did not
 * answer for (null); `NO_SUCH_PANE` is tmux saying the pane is gone.
 */
export function fakeScreen(table: Readonly<Record<string, Screen | null | typeof NO_SUCH_PANE>> = {}): FakeScreen {
  const probed: string[] = [];
  let gate: Promise<void> | null = null;
  const probe = async (pane: string): Promise<Screen | null | typeof NO_SUCH_PANE> => {
    probed.push(pane);
    if (gate) await gate;
    return table[pane] ?? null;
  };
  return Object.assign(probe, {
    probed,
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
  });
}
