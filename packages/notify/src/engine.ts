// The engine: agent events in, notices out, and the prompt-cache deadlines in
// between. It knows no platform: a `Notifier`, a feed, the options, a clock and
// a screen probe are everything it touches, which is also what makes it
// testable with five fakes and no sleeping.
import {
  labelsBySession,
  readLabels,
  type AgentEvent,
  type AgentFeed,
  type AgentStateRow,
  type EventFollower,
} from '@tagents/core';
import type { Clock } from './clock.ts';
import { describe } from './errors.ts';
import { agentName, compose } from './compose.ts';
import { createDeadlines } from './deadlines.ts';
import { classify, countsSession, type NoticeKind } from './kinds.ts';
import type { ClickAction, Notice, Notifier } from './notifier.ts';
import type { NotifyOptions } from './options.ts';
import type { Screen, ScreenProbe } from './screen.ts';

export interface EngineDeps {
  readonly feed: AgentFeed;
  readonly notifier: Notifier;
  /** A function so a reloaded options file takes effect on the next event, with no restart. */
  readonly options: () => NotifyOptions;
  readonly screen: ScreenProbe;
  readonly clock: Clock;
  readonly log: (...parts: string[]) => void;
  /** The absolute path of the `tagents` script a click runs. */
  readonly tagents: string;
  /** A function: macOS renames the host with the network, so each notice reads it afresh. */
  readonly hostname: () => string;
  /** Where the click's PATH, HOME, locale, TMUX_TMPDIR, TA_STATE_DIR and TAGENTS_CONFIG_DIR come from. */
  readonly env: NodeJS.ProcessEnv;
}

export interface Engine {
  start(): void;
  stop(): void;
  /** Resolves when this event, and every one handed in before it, has been dealt with. */
  handle(e: AgentEvent): Promise<void>;
}

const MINUTE = 60_000;

// What a click needs to find the same tmux server, state and config the engine
// was started with: a click runs under the notification center, not under this
// process, so it inherits none of it. Nothing else is passed on. The locale is
// on the list because tmux renders non-ASCII as `_` outside a UTF-8 one, and an
// agent's name is often not ASCII.
const CLICK_ENV = ['PATH', 'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TMUX_TMPDIR', 'TA_STATE_DIR', 'TAGENTS_CONFIG_DIR'] as const;


function clickEnv(env: NodeJS.ProcessEnv): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of CLICK_ENV) {
    const v = env[k];
    if (v !== undefined && v !== '') out[k] = v;
  }
  return out;
}

export function clickFor(e: AgentEvent, mode: NotifyOptions['click'], tagents: string, env: NodeJS.ProcessEnv): ClickAction {
  const clickEnvOf = clickEnv(env);
  // No pane, nothing to dock or go to: the click only raises the terminal.
  if (e.pane === '' || mode === 'focus') return { argv: [], env: clickEnvOf };
  if (mode === 'goto') return { argv: [tagents, '--goto', e.pane], env: clickEnvOf };
  return { argv: [tagents, '--act', 'open', e.pane, 'live', e.sessionId, e.cwd], env: clickEnvOf };
}

export interface NoticeDeps {
  readonly screen: ScreenProbe;
  /** Where the session labels live: the feed's directory. */
  readonly labelsDir: string;
  readonly tagents: string;
  readonly hostname: () => string;
  readonly env: NodeJS.ProcessEnv;
  readonly log: (...parts: string[]) => void;
}

async function probe(pane: string, d: NoticeDeps): Promise<Screen | null> {
  if (pane === '') return null;
  try {
    return await d.screen(pane);
  } catch (err) {
    // Losing the click's terminal is cheaper than losing the notice.
    d.log('screen probe failed', pane, describe(err));
    return null;
  }
}

/** The one place a Notice is assembled: the engine posts it and the `test` verb shows it. */
export async function buildNotice(
  kind: NoticeKind,
  e: AgentEvent,
  extra: { readonly plan?: boolean; readonly idleMin?: number; readonly leftMin?: number },
  o: { readonly skipVisible: boolean; readonly click: NotifyOptions['click'] },
  d: NoticeDeps
): Promise<Notice> {
  const screen = await probe(e.pane, d);
  const name = agentName({
    sessionId: e.sessionId,
    pane: e.pane,
    paneTitle: screen?.paneTitle ?? '',
    label: e.label,
    cwd: e.cwd,
    hostname: d.hostname(),
    labels: readLabels(d.labelsDir),
  });
  return {
    id: `tagents-${e.key}`,
    thread: e.sessionId,
    kind,
    ...compose(kind, e, name, extra),
    click: clickFor(e, o.click, d.tagents, d.env),
    ...(screen?.clientPid !== undefined ? { terminalPid: screen.clientPid } : {}),
    ...(o.skipVisible && screen?.visible === true ? { skipIfFrontmost: true } : {}),
  };
}

// The state row carries what an event would: enough to compose the notice and
// to click through to the right pane. Its `at` is epoch seconds, while an
// event's is milliseconds (the hook writes seconds and the parser multiplies).
export function eventFromRow(row: AgentStateRow, labels: ReadonlyMap<string, string>): AgentEvent {
  return {
    at: row.at * 1000,
    event: row.state === 'blocked' ? 'Notification' : 'Stop',
    key: row.key,
    sessionId: row.sessionId,
    agentId: '',
    pane: /^\d+$/.test(row.key) ? `%${row.key}` : '',
    cwd: row.cwd,
    transcript: row.transcript,
    configDir: row.configDir ?? '',
    tool: '',
    sub: '',
    text: row.detail,
    label: labels.get(row.sessionId) ?? '',
  };
}

export function createEngine(d: EngineDeps): Engine {
  /** Keys with a notice on screen, as far as the backend told us. */
  const up = new Set<string>();
  /** The event that armed each key's deadline: the notice is composed from it when the deadline falls due. */
  const armedBy = new Map<string, AgentEvent>();
  const deadlines = createDeadlines({
    clock: d.clock,
    onDue: (key, idleSince) => {
      void enqueue(() => due(key, idleSince));
    },
  });
  const noticeDeps: NoticeDeps = {
    screen: d.screen,
    labelsDir: d.feed.dir,
    tagents: d.tagents,
    hostname: d.hostname,
    env: d.env,
    log: d.log,
  };
  let follower: EventFollower | null = null;
  let stopped = false;
  // Events and due deadlines run one at a time, in the order they arrived: a
  // prompt that withdraws a notice must not overtake the post it withdraws.
  let chain: Promise<void> = Promise.resolve();

  function enqueue(job: () => Promise<void>): Promise<void> {
    chain = chain.then(job).catch((err: unknown) => d.log('error', describe(err)));
    return chain;
  }

  async function post(
    kind: NoticeKind,
    e: AgentEvent,
    extra: { plan?: boolean; idleMin?: number; leftMin?: number },
    skipVisible: boolean,
    opts: NotifyOptions
  ): Promise<void> {
    const notice = await buildNotice(kind, e, extra, { skipVisible, click: opts.click }, noticeDeps);
    // Dispose before you drain: a probe that was in flight when stop() ran must not post.
    if (stopped) return;
    try {
      const r = await d.notifier.post(notice);
      if (r.shown) up.add(e.key);
      d.log('notice', kind, e.key, JSON.stringify(notice.title), r.shown ? 'shown' : `dropped${r.why ? `: ${r.why}` : ''}`);
    } catch (err) {
      d.log('post failed', kind, e.key, describe(err));
    }
  }

  async function withdraw(key: string): Promise<void> {
    if (!up.has(key)) return;
    up.delete(key);
    const id = `tagents-${key}`;
    try {
      await d.notifier.withdraw(id);
      d.log('withdraw', id);
    } catch (err) {
      d.log('withdraw failed', id, describe(err));
    }
  }

  function arm(e: AgentEvent, opts: NotifyOptions): void {
    const c = opts.events.cache_expiring;
    // No notice would come of it, so no timer either: "no timer at all while nothing is armed".
    if (stopped || !c.enabled) return;
    armedBy.set(e.key, e);
    deadlines.arm(e.key, e.at, e.at + c.after);
  }

  async function step(e: AgentEvent): Promise<void> {
    if (stopped) return;
    const opts = d.options();
    const v = classify(e, { headless: opts.sessions.headless });
    if (v === null) return;
    if (v.cancel) {
      deadlines.cancel(e.key);
      armedBy.delete(e.key);
    }
    if (v.withdraw) await withdraw(e.key);
    // A kind that is switched off posts nothing, but the person is still
    // waiting on the session and the prompt cache's clock still runs.
    if (v.arms) arm(e, opts);
    if (v.kind === null) return;
    const ev = opts.events[v.kind];
    if (!ev.enabled) return;
    await post(v.kind, e, { plan: v.plan }, ev.skip_visible, opts);
  }

  async function due(key: string, idleSince: number): Promise<void> {
    const e = armedBy.get(key);
    // This job waited its turn in the chain. If a prompt cancelled the key, or a
    // newer turn re-armed it with an idle-since of its own, the newer deadline
    // has its own wake and this one is stale.
    if (stopped || e === undefined || e.at !== idleSince) return;
    armedBy.delete(key);
    const opts = d.options();
    const c = opts.events.cache_expiring;
    if (!c.enabled || !countsSession(key, opts.sessions.headless)) return;
    const row = d.feed.states().find((r) => r.key === key);
    // A turn is running (its Stop re-arms), or the session is over.
    if (row === undefined || row.state === 'working' || row.state === 'new' || row.state === 'gone') return;
    const now = d.clock.now();
    // The cache is gone already, perhaps because the Mac slept through its TTL.
    if (now - idleSince >= c.ttl) return;
    await post(
      'cache_expiring',
      e,
      {
        idleMin: Math.round((now - idleSince) / MINUTE),
        leftMin: Math.round((idleSince + c.ttl - now) / MINUTE),
      },
      c.skip_visible,
      opts
    );
  }

  // A restart must not forget the sessions that were already idle: arm every
  // one whose cache is still alive, from the state rows the hooks keep.
  function armFromStates(): void {
    const opts = d.options();
    const c = opts.events.cache_expiring;
    if (!c.enabled) return;
    const now = d.clock.now();
    const labels = labelsBySession(d.feed.dir);
    for (const row of d.feed.states()) {
      if (row.state !== 'done' && row.state !== 'blocked') continue;
      if (!countsSession(row.key, opts.sessions.headless)) continue;
      const idleSince = row.at * 1000;
      if (now - idleSince >= c.ttl) continue;
      armedBy.set(row.key, eventFromRow(row, labels));
      deadlines.arm(row.key, idleSince, idleSince + c.after);
    }
  }

  function handle(e: AgentEvent): Promise<void> {
    return enqueue(() => step(e));
  }

  return {
    start() {
      if (stopped || follower !== null) return;
      armFromStates();
      follower = d.feed.follow(
        (e) => {
          void handle(e);
        },
        (err) => d.log('feed error', err.message)
      );
    },
    stop() {
      if (stopped) return;
      stopped = true;
      follower?.close();
      follower = null;
      deadlines.close();
      armedBy.clear();
    },
    handle,
  };
}
