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
import { QUESTION_TOOLS, classify, countsSession, type NoticeKind } from './kinds.ts';
import type { ClickAction, Notice, Notifier, PostResult } from './notifier.ts';
import type { NotifyOptions } from './options.ts';
import { NO_SUCH_PANE, type Screen, type ScreenProbe } from './screen.ts';

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
  /** Where the click's PATH, HOME, locale, TMUX_TMPDIR, TA_STATE_DIR and the config variables come from. */
  readonly env: NodeJS.ProcessEnv;
}

export interface Engine {
  start(): void;
  /**
   * Stops following and arming, and settles once the work already under way has
   * finished: a post that was in flight lands, and whatever was queued behind it
   * is dropped. Rejects if the follower would not close, after the same cleanup.
   */
  stop(): Promise<void>;
  /** Resolves when this event, and every one handed in before it, has been dealt with. */
  handle(e: AgentEvent): Promise<void>;
}

const MINUTE = 60_000;

// A dead follower is followed again after a second, then two, and so on up to
// five minutes. A follower that has proven itself starts the count over.
const REFOLLOW_MIN_MS = 1000;
const REFOLLOW_MAX_MS = 5 * MINUTE;

// The hook writes the PreToolUse of a question as a `working` row whose detail
// is the tool's name, and the PostToolUse of the same call as "<tool> ✓". The
// first is a question nobody has answered yet, which is a wait like any other.
const OPEN_QUESTION = new RegExp(`^(?:${QUESTION_TOOLS.join('|')})(?: (?!✓$).*)?$`);

// Claude Code follows a question with a permission prompt of its own about six
// seconds later. A prompt that comes later than this is a real one: a plan that
// was rejected fires no PostToolUse, and the model may go on to ask for a tool.
const QUESTION_PROMPT_WINDOW_MS = 20_000;

// What a click needs to find the same tmux server, state and config the engine
// was started with: a click runs under the notification center, not under this
// process, so it inherits none of it. Nothing else is passed on. The locale is
// on the list because tmux renders non-ASCII as `_` outside a UTF-8 one, and an
// agent's name is often not ASCII. The config is three variables because
// lib/tagents/config.sh looks for it in TA_CONFIG, then XDG_CONFIG_HOME, and
// the dashboard has the same ones.
const CLICK_ENV = [
  'PATH',
  'HOME',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'TMUX_TMPDIR',
  'TA_STATE_DIR',
  'TAGENTS_CONFIG_DIR',
  'XDG_CONFIG_HOME',
  'TA_CONFIG',
] as const;

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

async function probe(pane: string, d: NoticeDeps): Promise<Screen | null | typeof NO_SUCH_PANE> {
  if (pane === '') return null;
  try {
    return await d.screen(pane);
  } catch (err) {
    // Losing the click's terminal is cheaper than losing the notice.
    d.log('screen probe failed', pane, describe(err));
    return null;
  }
}

/**
 * The id a notice goes up under; a notice with the same id replaces the one on
 * screen, so an agent has one notice at a time, saying the latest thing.
 */
export function noticeId(key: string): string {
  return `tagents-${key}`;
}

function assemble(
  kind: NoticeKind,
  e: AgentEvent,
  extra: { readonly plan?: boolean; readonly idleMin?: number; readonly leftMin?: number },
  o: { readonly skipVisible: boolean; readonly click: NotifyOptions['click'] },
  d: NoticeDeps,
  screen: Screen | null
): Notice {
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
    id: noticeId(e.key),
    thread: e.sessionId,
    kind,
    ...compose(kind, e, name, extra),
    click: clickFor(e, o.click, d.tagents, d.env),
    ...(screen?.clientPid !== undefined ? { terminalPid: screen.clientPid } : {}),
    ...(o.skipVisible && screen?.visible === true ? { skipIfFrontmost: true } : {}),
  };
}

/** The one place a Notice is assembled: the engine posts it and the `test` verb shows it. */
export async function buildNotice(
  kind: NoticeKind,
  e: AgentEvent,
  extra: { readonly plan?: boolean; readonly idleMin?: number; readonly leftMin?: number },
  o: { readonly skipVisible: boolean; readonly click: NotifyOptions['click'] },
  d: NoticeDeps
): Promise<Notice> {
  const seen = await probe(e.pane, d);
  return assemble(kind, e, extra, o, d, seen === NO_SUCH_PANE ? null : seen);
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
  /** Ids of the notices on screen, as far as the backend told us. */
  const up = new Set<string>();
  /** Keys with a question notice on screen that nobody has answered, and when it was asked. */
  const questions = new Map<string, number>();
  /** When a cache warning went out for a key, so that arming from the state rows does not send it twice. */
  const warnedAt = new Map<string, number>();
  /** What a failing backend has said since a post last worked, so that each message is logged once. */
  const postFailures = new Set<string>();
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
  let stopping: Promise<void> | null = null;
  let cancelRefollow: (() => void) | null = null;
  let refollowAfter = REFOLLOW_MIN_MS;
  let followedAt = 0;
  let followedAfter = 0;
  let heard = false;
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
  ): Promise<boolean> {
    const seen = await probe(e.pane, noticeDeps);
    // The pane is gone and nobody told us (it was closed without a SessionEnd):
    // nothing is asked there any more. Its notices stay, since a click resumes
    // the chat by its session id, but a warning about its cache is not sent.
    if (seen === NO_SUCH_PANE) {
      questions.delete(e.key);
      if (kind === 'cache_expiring') {
        d.log('notice', kind, e.key, `skipped: tmux has no pane ${e.pane}`);
        return false;
      }
    }
    const notice = assemble(kind, e, extra, { skipVisible, click: opts.click }, noticeDeps, seen === NO_SUCH_PANE ? null : seen);
    let r: PostResult;
    try {
      r = await d.notifier.post(notice);
    } catch (err) {
      const why = describe(err);
      if (!postFailures.has(why)) {
        postFailures.add(why);
        d.log('post failed', kind, e.key, why);
      }
      return false;
    }
    if (postFailures.size > 0) {
      postFailures.clear();
      d.log('posting works again');
    }
    if (r.shown) {
      up.add(notice.id);
      // Only the question tools get a PostToolUse and a prompt that follows: an
      // MCP elicitation has neither, so it holds nothing back.
      if (kind === 'question' && e.event === 'PreToolUse' && seen !== NO_SUCH_PANE) questions.set(e.key, e.at);
    }
    d.log('notice', kind, e.key, JSON.stringify(notice.title), r.shown ? 'shown' : `dropped${r.why ? `: ${r.why}` : ''}`);
    // A notice that was dropped (the pane is in front, say) leaves the old one
    // with this id on screen, saying something that is no longer so.
    if (!r.shown) await takeDown(notice.id);
    return true;
  }

  async function takeDown(id: string): Promise<void> {
    if (!up.has(id)) return;
    up.delete(id);
    try {
      await d.notifier.withdraw(id);
      d.log('withdraw', id);
    } catch (err) {
      d.log('withdraw failed', id, describe(err));
    }
  }

  async function withdraw(key: string): Promise<void> {
    await takeDown(noticeId(key));
  }

  function arm(e: AgentEvent, opts: NotifyOptions): void {
    const c = opts.events.cache_expiring;
    // No notice would come of it, so no timer either: "no timer at all while nothing is armed".
    if (stopped || !c.enabled) return;
    armedBy.set(e.key, e);
    warnedAt.delete(e.key);
    deadlines.arm(e.key, e.at, e.at + c.after);
  }

  async function step(e: AgentEvent): Promise<void> {
    if (stopped) return;
    const opts = d.options();
    const v = classify(e);
    if (v === null) return;
    // That prompt's generic text would replace the question's, and the question
    // is the wait: the deadline it armed stays armed.
    const askedAt = questions.get(e.key);
    if (v.kind === 'permission' && askedAt !== undefined && e.at - askedAt <= QUESTION_PROMPT_WINDOW_MS) {
      d.log('permission prompt held back by the question on screen', e.key);
      return;
    }
    // The answer, a prompt, the end of the turn or of the session: nothing is asked any more.
    if (v.cancel || v.kind === 'turn_done') questions.delete(e.key);
    if (v.cancel) {
      deadlines.cancel(e.key);
      armedBy.delete(e.key);
      warnedAt.delete(e.key);
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
    if (!c.enabled || !countsSession(key)) return;
    const row = d.feed.states().find((r) => r.key === key);
    // The session is over, or a turn is running (its Stop re-arms). The hook
    // writes `working` for the question that armed this very deadline, so a
    // working row counts as a turn only when it is newer than that event.
    if (row === undefined || row.state === 'new' || row.state === 'gone') return;
    if (row.state === 'working' && row.at * 1000 > idleSince) return;
    const now = d.clock.now();
    // The cache is gone already, perhaps because the Mac slept through its TTL.
    if (now - idleSince >= c.ttl) return;
    const sent = await post(
      'cache_expiring',
      e,
      {
        idleMin: Math.round((now - idleSince) / MINUTE),
        leftMin: Math.round((idleSince + c.ttl - now) / MINUTE),
      },
      c.skip_visible,
      opts
    );
    if (sent) warnedAt.set(key, now);
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
      const waiting = row.state === 'done' || row.state === 'blocked' || (row.state === 'working' && OPEN_QUESTION.test(row.detail));
      if (!waiting) continue;
      if (!countsSession(row.key)) continue;
      const idleSince = row.at * 1000;
      if (now - idleSince >= c.ttl) continue;
      // Warned already for this idle period: a row nobody has written since the
      // warning is the same period (its `at` is not the event's, since the idle
      // ping rewrites it a minute after the Stop, so the two are not compared).
      const warned = warnedAt.get(row.key);
      if (warned !== undefined && idleSince <= warned) continue;
      armedBy.set(row.key, eventFromRow(row, labels));
      deadlines.arm(row.key, idleSince, idleSince + c.after);
    }
  }

  function handle(e: AgentEvent): Promise<void> {
    return enqueue(() => step(e));
  }

  // `precededBy` is the wait before this follow (none for the first), which a
  // follower has to outlive to count as having proven itself.
  function follow(precededBy: number): void {
    follower = d.feed.follow(
      (e) => {
        heard = true;
        void handle(e);
        // The process is awake for this event, so looking costs no wake: after
        // a Mac sleep, the timers still owe their awake time, and the first event
        // of any chat brings out the warnings that fell due meanwhile. Behind the
        // event in the chain, so a prompt that cancels a key is seen first.
        deadlines.sweep();
      },
      (err) => d.log('feed error', err.message),
      onDead
    );
    followedAt = d.clock.now();
    followedAfter = precededBy;
    heard = false;
  }

  // The one timer beside the deadlines': it exists only while the follower is
  // dead, and then it is the only thing that can bring the engine back.
  function refollowSoon(): number {
    const wait = refollowAfter;
    refollowAfter = Math.min(refollowAfter * 2, REFOLLOW_MAX_MS);
    cancelRefollow = d.clock.after(wait, () => {
      cancelRefollow = null;
      if (stopped) return;
      try {
        follow(wait);
      } catch (err) {
        const next = refollowSoon();
        d.log('follow failed', describe(err), `trying again in ${next / 1000}s`);
        return;
      }
      // The events that landed while the follower was dead are lost; the state
      // rows are what is left of them, and they arm what the events would have.
      try {
        armFromStates();
      } catch (err) {
        d.log('arming from the state rows failed', describe(err));
      }
    });
    return wait;
  }

  function onDead(err: Error): void {
    if (stopped) return;
    // The feed counted the follower out before it called us: nothing to close.
    follower = null;
    // A follow that returns proves nothing: a watch that fails at once would be
    // followed again every second. The wait starts over only for a follower that
    // heard an event, or that lived longer than the wait before it.
    if (heard || d.clock.now() - followedAt > followedAfter) refollowAfter = REFOLLOW_MIN_MS;
    d.log('feed follower died', err.message, `following again in ${refollowSoon() / 1000}s`);
  }

  async function shutDown(): Promise<void> {
    stopped = true;
    try {
      follower?.close();
    } finally {
      // Whatever the follower did, no timer may outlive the engine. The drain
      // comes last, and a throw from the close surfaces after it.
      follower = null;
      cancelRefollow?.();
      cancelRefollow = null;
      deadlines.close();
      armedBy.clear();
      questions.clear();
      warnedAt.clear();
      await chain;
    }
  }

  return {
    start() {
      if (stopped || follower !== null || cancelRefollow !== null) return;
      // Follow first: if it throws there is nothing armed to leave behind.
      follow(0);
      armFromStates();
    },
    stop() {
      stopping ??= shutDown();
      return stopping;
    },
    handle,
  };
}
