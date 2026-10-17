// node --test engine.test.ts
//
// The engine against a fake feed, notifier, clock and screen probe. Timers are
// the fake clock's, so nothing here sleeps: a test that waits for real time
// would be the flaky one.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import type { AgentEvent, AgentFeed, AgentStateRow } from '@tagents/core';
import { createEngine } from '../src/engine.ts';
import { NO_SUCH_PANE, type Screen } from '../src/screen.ts';
import {
  MIN,
  T0,
  event,
  fakeClock,
  fakeFeed,
  fakeScreen,
  options,
  recordingNotifier,
  stateRow,
  type FakeFeed,
} from './fakes.ts';

// Text assertions below are English; the developer's own shell may say otherwise.
process.env['TAGENTS_LOCALE'] = 'en';

const TAGENTS = '/opt/checkout/tagents';
const BASE_ENV = { PATH: '/usr/bin:/bin', HOME: '/home/u' };

interface RigOptions {
  readonly options?: unknown;
  readonly screens?: Record<string, Screen | null | typeof NO_SUCH_PANE>;
  readonly env?: NodeJS.ProcessEnv;
  readonly rows?: AgentStateRow[];
  /** The feed the engine gets, over the rig's own fake one. */
  readonly feedOver?: (feed: FakeFeed) => AgentFeed;
}

function rig(o: RigOptions = {}) {
  const feed = fakeFeed();
  feed.rows = o.rows ?? [];
  const notifier = recordingNotifier();
  const clock = fakeClock();
  const screen = fakeScreen(o.screens ?? {});
  const logs: string[] = [];
  let current = options(o.options ?? {});
  const engine = createEngine({
    feed: o.feedOver?.(feed) ?? feed,
    notifier,
    options: () => current,
    screen,
    clock,
    log: (...parts) => logs.push(parts.join(' ')),
    tagents: TAGENTS,
    hostname: () => 'mbp.local',
    env: o.env ?? BASE_ENV,
  });
  return {
    feed,
    notifier,
    clock,
    screen,
    logs,
    engine,
    setOptions(raw: unknown) {
      current = options(raw);
    },
    /** An event that classifies as nothing, queued behind all work in flight: when it returns, that work is done. */
    async settle() {
      await engine.handle(event({ event: 'PreToolUse', tool: 'Bash' }));
    },
    /** The event, stamped with the clock's now. */
    now(over: Partial<AgentEvent> = {}): AgentEvent {
      return event({ at: clock.now(), ...over });
    },
  };
}

const visible: Screen = { visible: true, clientPid: 4242, paneTitle: '✳ build agent' };
const hidden: Screen = { visible: false, clientPid: 777, paneTitle: '✳ build agent' };

test('a turn that ends posts one notice, under the key\'s id and the session\'s thread', async () => {
  const r = rig({ screens: { '%12': hidden } });
  await r.engine.handle(r.now({ event: 'Stop', cwd: '/work/proj' }));
  assert.equal(r.notifier.posts.length, 1);
  const n = r.notifier.posts[0];
  assert.equal(n?.id, 'tagents-12');
  assert.equal(n?.thread, 'sess-1');
  assert.equal(n?.kind, 'turn_done');
  assert.equal(n?.title, 'build agent');
  assert.equal(n?.subtitle, 'Answer ready · proj');
  assert.equal(n?.body, 'Your move');
  assert.deepEqual(r.screen.probed, ['%12']);
});

test('the title is the label typed on ctrl-r when there is one', async () => {
  const r = rig({ screens: { '%12': hidden } });
  fs.writeFileSync(`${r.feed.dir}/labels.tsv`, 'sess-1\ttyped name\n');
  await r.engine.handle(r.now());
  assert.equal(r.notifier.posts[0]?.title, 'typed name');
});

test('a second notice for one key reuses its id', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  await r.engine.handle(r.now({ event: 'Notification', sub: 'permission_prompt', text: 'Allow?' }));
  assert.deepEqual(r.notifier.posts.map((p) => p.id), ['tagents-12', 'tagents-12']);
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done', 'permission']);
});

test('a disabled kind posts nothing, yet its turn_done still arms the cache deadline', async () => {
  const r = rig({ options: { events: { turn_done: { enabled: false } } } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.notifier.posts.length, 0);
  assert.equal(r.clock.pending, 1);
  r.feed.rows = [stateRow({ state: 'done', at: r.clock.now() / 1000 })];
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['cache_expiring']);
});

test('the kinds that are off by default post nothing until they are turned on', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  await r.engine.handle(r.now({ event: 'SessionEnd', sub: 'logout' }));
  assert.equal(r.notifier.posts.length, 0);
  const on = rig({ options: { events: { subagent_done: { enabled: true }, session_end: { enabled: true } } } });
  await on.engine.handle(on.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  await on.engine.handle(on.now({ event: 'SessionEnd', sub: 'logout' }));
  assert.deepEqual(on.notifier.posts.map((p) => [p.kind, p.body]), [['subagent_done', 'Explore finished'], ['session_end', 'logout']]);
});

test('skip_visible with the pane in some client\'s window: skip if frontmost, that client\'s pid', async () => {
  const r = rig({ screens: { '%12': visible } });
  await r.engine.handle(r.now());
  const n = r.notifier.posts[0];
  assert.equal(n?.skipIfFrontmost, true);
  assert.equal(n?.terminalPid, 4242);
});

test('a pane nobody is looking at is posted with no skip and the most active client\'s pid', async () => {
  const r = rig({ screens: { '%12': hidden } });
  await r.engine.handle(r.now());
  const n = r.notifier.posts[0];
  assert.ok(n && !('skipIfFrontmost' in n));
  assert.equal(n?.terminalPid, 777);
});

test('skip_visible off: a visible pane is posted without the skip, still with its client for the click', async () => {
  const r = rig({ screens: { '%12': visible }, options: { events: { turn_done: { skip_visible: false } } } });
  await r.engine.handle(r.now());
  const n = r.notifier.posts[0];
  assert.ok(n && !('skipIfFrontmost' in n));
  assert.equal(n?.terminalPid, 4242);
});

test('a pane tmux does not know is posted with no pid, named by its label or directory', async () => {
  const r = rig({ screens: {} });
  await r.engine.handle(r.now({ label: 'ticket-agent' }));
  const n = r.notifier.posts[0];
  assert.ok(n && !('terminalPid' in n) && !('skipIfFrontmost' in n));
  assert.equal(n?.title, 'ticket-agent');
});

test('a probe that rejects costs the pid, not the notice', async () => {
  const r = rig();
  const failing = createEngine({
    feed: r.feed,
    notifier: r.notifier,
    options: () => options({}),
    screen: () => Promise.reject(new Error('tmux went away')),
    clock: r.clock,
    log: (...p) => r.logs.push(p.join(' ')),
    tagents: TAGENTS,
    hostname: () => 'mbp',
    env: BASE_ENV,
  });
  await failing.handle(r.now());
  assert.equal(r.notifier.posts.length, 1);
  assert.ok(r.logs.some((l) => l.includes('tmux went away')));
});

test('a prompt withdraws only when a notice is up for that key', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.deepEqual(r.notifier.withdrawn, []);
  await r.engine.handle(r.now({ event: 'Stop' }));
  await r.engine.handle(r.now({ event: 'UserPromptSubmit', key: '13', pane: '%13' }));
  assert.deepEqual(r.notifier.withdrawn, [], 'another key\'s notice is not this one');
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12'], 'once is enough');
});

test('a notice that the backend dropped is not one to withdraw', async () => {
  const r = rig();
  r.notifier.result = { shown: false, why: 'frontmost' };
  await r.engine.handle(r.now({ event: 'Stop' }));
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.deepEqual(r.notifier.withdrawn, []);
  assert.ok(r.logs.some((l) => l.includes('frontmost')));
});

test('SessionEnd withdraws the notice and cancels the deadline', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending, 1);
  await r.engine.handle(r.now({ event: 'SessionEnd', sub: 'logout' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
  assert.equal(r.clock.pending, 0);
});

test('with session_end on, the end of a session withdraws the old notice and then posts its own', async () => {
  const r = rig({ options: { events: { session_end: { enabled: true } } } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  await r.engine.handle(r.now({ event: 'SessionEnd', sub: 'logout' }));
  assert.deepEqual(r.notifier.calls.map((c) => c.op), ['post', 'withdraw', 'post']);
});

test('the click: dock is the dashboard\'s Enter on that chat', async () => {
  const r = rig({ screens: { '%12': hidden } });
  await r.engine.handle(r.now({ cwd: '/work/proj', sessionId: 'sess-1' }));
  assert.deepEqual(r.notifier.posts[0]?.click.argv, [TAGENTS, '--act', 'open', '%12', 'live', 'sess-1', '/work/proj']);
});

test('the click: goto is the agent\'s own window', async () => {
  const r = rig({ options: { click: 'goto' } });
  await r.engine.handle(r.now());
  assert.deepEqual(r.notifier.posts[0]?.click.argv, [TAGENTS, '--goto', '%12']);
});

test('the click: focus is the terminal only, and so is a session with no pane', async () => {
  const r = rig({ options: { click: 'focus' } });
  await r.engine.handle(r.now());
  assert.deepEqual(r.notifier.posts[0]?.click.argv, []);
  const h = rig({ options: { sessions: { headless: true } } });
  await h.engine.handle(h.now({ key: 's-abc', pane: '', sessionId: 'abc' }));
  assert.deepEqual(h.notifier.posts[0]?.click.argv, []);
  assert.equal(h.notifier.posts[0]?.id, 'tagents-s-abc');
  assert.deepEqual(h.screen.probed, [], 'there is no pane to ask tmux about');
});

test('the click env is PATH and HOME, plus the locale and the variables that pick the tmux server, state and config when they are set', async () => {
  const bare = rig({ env: { ...BASE_ENV, SHELL: '/bin/zsh', SECRET: 'no' } });
  await bare.engine.handle(bare.now());
  assert.deepEqual(bare.notifier.posts[0]?.click.env, BASE_ENV);
  const full = rig({
    env: {
      ...BASE_ENV,
      LANG: 'ru_RU.UTF-8',
      LC_ALL: 'en_US.UTF-8',
      LC_CTYPE: 'UTF-8',
      TMUX_TMPDIR: '/tmp/tm',
      TA_STATE_DIR: '/tmp/st',
      TAGENTS_CONFIG_DIR: '/tmp/cfg',
      XDG_CONFIG_HOME: '/tmp/xdg',
      TA_CONFIG: '/tmp/cfg/config.yaml',
      SECRET: 'no',
    },
  });
  await full.engine.handle(full.now());
  assert.deepEqual(full.notifier.posts[0]?.click.env, {
    ...BASE_ENV,
    LANG: 'ru_RU.UTF-8',
    LC_ALL: 'en_US.UTF-8',
    LC_CTYPE: 'UTF-8',
    TMUX_TMPDIR: '/tmp/tm',
    TA_STATE_DIR: '/tmp/st',
    TAGENTS_CONFIG_DIR: '/tmp/cfg',
    XDG_CONFIG_HOME: '/tmp/xdg',
    TA_CONFIG: '/tmp/cfg/config.yaml',
  });
  const empty = rig({ env: { ...BASE_ENV, LANG: '' } });
  await empty.engine.handle(empty.now());
  assert.deepEqual(empty.notifier.posts[0]?.click.env, BASE_ENV, 'an empty variable stays absent');
});

test('the hostname is read for each notice: a title that was the host is a name once the host is renamed', async () => {
  let host = 'untitled.local';
  const r = rig({ screens: { '%12': { visible: false, paneTitle: 'untitled.local' } } });
  const e = createEngine({
    feed: r.feed,
    notifier: r.notifier,
    options: () => options({}),
    screen: r.screen,
    clock: r.clock,
    log: () => undefined,
    tagents: TAGENTS,
    hostname: () => host,
    env: BASE_ENV,
  });
  await e.handle(r.now());
  host = 'renamed.local';
  await e.handle(r.now());
  assert.equal(r.notifier.posts[0]?.title, 'proj', 'the pane title is the host: the directory names the agent');
  assert.equal(r.notifier.posts[1]?.title, 'untitled.local', 'the host changed: the title is a name now');
});

test('a session with no pane is ignored unless sessions.headless is on', async () => {
  const off = rig();
  await off.engine.handle(off.now({ key: 's-abc', pane: '' }));
  assert.equal(off.notifier.posts.length, 0);
  assert.equal(off.clock.pending, 0);
});

test('a notifier that throws is logged, and the next event still posts', async () => {
  const r = rig();
  r.notifier.failPosts(1);
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.notifier.posts.length, 0);
  assert.ok(r.logs.some((l) => l.includes('not answering')), r.logs.join('\n'));
  await r.engine.handle(r.now({ event: 'Notification', sub: 'permission_prompt', text: 'Allow?' }));
  assert.equal(r.notifier.posts.length, 1);
});

test('a notice is one log line: its kind, key, title and whether it was shown', async () => {
  const r = rig({ screens: { '%12': hidden } });
  await r.engine.handle(r.now());
  const line = r.logs.find((l) => l.includes('turn_done'));
  assert.ok(line);
  for (const part of ['12', 'build agent', 'shown']) assert.ok(line.includes(part), `${part} in ${line}`);
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.ok(r.logs.some((l) => l.includes('withdraw') && l.includes('tagents-12')));
});

test('events are handled one at a time, in the order they arrived', async () => {
  const r = rig();
  const gate = r.notifier.hold();
  const first = r.engine.handle(r.now({ event: 'Stop' }));
  const second = r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(r.notifier.calls.length, 0, 'the post is still held, and the prompt waits behind it');
  gate.release();
  await Promise.all([first, second]);
  assert.deepEqual(r.notifier.calls.map((c) => c.op), ['post', 'withdraw']);
});

test('start follows the feed and handles what it delivers; stop closes the follower, twice over', async () => {
  const r = rig();
  r.engine.start();
  assert.equal(r.feed.followers, 1);
  r.feed.emit(r.now({ event: 'Stop' }));
  await r.settle();
  assert.equal(r.notifier.posts.length, 1);
  await r.engine.stop();
  assert.equal(r.feed.closed, true);
  assert.equal(r.clock.pending, 0);
  await r.engine.stop();
});

// Cache deadlines

test('a turn arms one deadline and a prompt cancels it', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending, 1);
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.equal(r.clock.pending, 0);
  await r.engine.handle(r.now({ event: 'Notification', sub: 'permission_prompt', text: 'Allow?' }));
  assert.equal(r.clock.pending, 1);
  await r.engine.handle(r.now({ event: 'SessionStart' }));
  assert.equal(r.clock.pending, 0);
});

test('a question and a permission prompt arm it too; a subagent finishing does not', async () => {
  const q = rig();
  await q.engine.handle(q.now({ event: 'PreToolUse', tool: 'AskUserQuestion', text: 'Which?' }));
  assert.equal(q.clock.pending, 1);
  const s = rig();
  await s.engine.handle(s.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  assert.equal(s.clock.pending, 0);
});

test('due with the row done: cache_expiring, with the idle and the left minutes', async () => {
  const r = rig({ screens: { '%12': hidden } });
  const stopAt = r.clock.now();
  await r.engine.handle(r.now({ event: 'Stop', cwd: '/work/proj' }));
  r.feed.rows = [stateRow({ state: 'done', at: stopAt / 1000 })];
  r.clock.advance(49 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done'], 'not yet');
  r.clock.advance(MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done', 'cache_expiring']);
  const n = r.notifier.posts[1];
  assert.equal(n?.id, 'tagents-12');
  assert.equal(n?.title, 'build agent');
  assert.equal(n?.subtitle, 'Prompt cache expiring · proj');
  assert.equal(n?.body, 'Idle 50 min — send anything within ~10 min to keep the prompt cache');
  assert.deepEqual(n?.click.argv, [TAGENTS, '--act', 'open', '%12', 'live', 'sess-1', '/work/proj']);
  assert.equal(r.clock.pending, 0);
});

test('due with the row blocked also posts', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Notification', sub: 'permission_prompt', text: 'Allow?' }));
  r.feed.rows = [stateRow({ state: 'blocked' })];
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.equal(r.notifier.posts.at(-1)?.kind, 'cache_expiring');
});

test('due with the row working, new, gone or missing: nothing is posted, and the deadline is dropped', async () => {
  for (const state of ['working', 'new', 'gone', null] as const) {
    const r = rig();
    await r.engine.handle(r.now({ event: 'Stop' }));
    const before = r.notifier.posts.length;
    // A working row is a turn that began after the Stop that armed the deadline.
    r.feed.rows = state === null ? [] : [stateRow({ state, ...(state === 'working' ? { at: T0 / 1000 + 30 } : {}) })];
    r.clock.advance(50 * MIN);
    await r.settle();
    assert.equal(r.notifier.posts.length, before, String(state));
    assert.equal(r.clock.pending, 0, String(state));
  }
});

test('a row of another key does not stand in for this one', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ key: '99', state: 'done' })];
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done']);
});

test('the Mac sleeps past the cache TTL: no notice about a cache that is already gone', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.advance(4 * MIN);
  r.clock.jump(70 * MIN);
  r.clock.advance(0);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done']);
  assert.equal(r.clock.pending, 0);
});

test('the Mac wakes 3 minutes past the due time: the notice goes out within one 5-minute tick', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.advance(4 * MIN);
  r.clock.jump(49 * MIN);
  assert.equal(r.notifier.posts.length, 1, 'a sleeping Mac runs nothing');
  r.clock.advance(0);
  await r.settle();
  assert.equal(r.notifier.posts.at(-1)?.kind, 'cache_expiring');
  assert.equal(r.notifier.posts.at(-1)?.body, 'Idle 53 min — send anything within ~7 min to keep the prompt cache');
});

test('a deadline that fell due while a newer turn was queued ahead of it is stale and posts nothing', async () => {
  const r = rig();
  r.feed.rows = [stateRow({ state: 'done' })];
  const gate = r.notifier.hold();
  const first = r.engine.handle(r.now({ event: 'Stop' }));
  // The second turn's Stop is in the chain before the first deadline's wake can be.
  const second = r.engine.handle(r.now({ event: 'Stop', at: T0 + 49 * MIN }));
  await new Promise((resolve) => setImmediate(resolve));
  r.clock.advance(50 * MIN);
  gate.release();
  await Promise.all([first, second]);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done', 'turn_done']);
  assert.equal(r.clock.pending, 1, 'the second turn\'s own deadline is still waiting');
});

test('the timer never sleeps longer than 5 minutes', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.nextDelay(), 5 * MIN);
});

test('start arms every row that is done or blocked and still inside the TTL, and each posts once', async () => {
  const now = T0;
  const r = rig({
    rows: [
      stateRow({ key: '12', state: 'done', at: (now - 10 * MIN) / 1000, sessionId: 'sess-12', cwd: '/work/twelve' }),
      stateRow({ key: '13', state: 'blocked', at: (now - 20 * MIN) / 1000, sessionId: 'sess-13', cwd: '/work/thirteen' }),
      stateRow({ key: '14', state: 'working', at: (now - 5 * MIN) / 1000 }),
    ],
    screens: { '%12': hidden, '%13': hidden },
  });
  r.engine.start();
  assert.equal(r.clock.pending, 1, 'one timer for the earliest');
  // The rows are as they were; the clock walks to each deadline.
  r.clock.advance(31 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.id), ['tagents-13']);
  assert.equal(r.notifier.posts[0]?.body, 'Idle 51 min — send anything within ~9 min to keep the prompt cache');
  r.clock.advance(10 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.id), ['tagents-13', 'tagents-12']);
  assert.equal(r.notifier.posts[1]?.subtitle, 'Prompt cache expiring · twelve');
  r.clock.advance(60 * MIN);
  await r.settle();
  assert.equal(r.notifier.posts.length, 2, 'once each');
  assert.equal(r.clock.pending, 0);
});

test('start leaves a row that is already past the TTL alone, and arms nothing', async () => {
  const now = T0;
  const r = rig({ rows: [stateRow({ state: 'done', at: (now - 61 * MIN) / 1000 })] });
  r.engine.start();
  assert.equal(r.clock.pending, 0);
});

test('a deadline armed from a row is composed from the row, with the TA_LABEL history keeps', async () => {
  const r = rig({
    rows: [stateRow({ state: 'done', at: (T0 - 55 * MIN) / 1000, sessionId: 'sess-1', cwd: '/work/proj' })],
  });
  // history.tsv: at, kind, session id, pane, label, cwd
  fs.writeFileSync(`${r.feed.dir}/history.tsv`, `${T0 / 1000 - 3300}\tturn\tsess-1\t%12\tticket-agent\t/work/proj\n`);
  r.engine.start();
  r.clock.advance(0);
  await r.settle();
  assert.equal(r.notifier.posts.length, 1);
  const n = r.notifier.posts[0];
  assert.equal(n?.thread, 'sess-1');
  assert.equal(n?.title, 'ticket-agent');
  assert.equal(n?.body, 'Idle 55 min — send anything within ~5 min to keep the prompt cache');
  assert.deepEqual(n?.click.argv, [TAGENTS, '--act', 'open', '%12', 'live', 'sess-1', '/work/proj']);
  assert.deepEqual(r.screen.probed, ['%12']);
});

test('a headless row has no pane to click or to probe', async () => {
  const r = rig({
    options: { sessions: { headless: true } },
    rows: [stateRow({ key: 's-abc', state: 'done', at: (T0 - 55 * MIN) / 1000, sessionId: 'abc' })],
  });
  r.engine.start();
  r.clock.advance(0);
  await r.settle();
  assert.equal(r.notifier.posts[0]?.id, 'tagents-s-abc');
  assert.deepEqual(r.notifier.posts[0]?.click.argv, []);
  assert.deepEqual(r.screen.probed, []);
  const off = rig({ rows: [stateRow({ key: 's-abc', state: 'done', at: (T0 - 55 * MIN) / 1000 })] });
  off.engine.start();
  assert.equal(off.clock.pending, 0, 'headless sessions count only when asked for');
});

test('nothing is pending at start with no rows, and nothing fires after stop', async () => {
  const r = rig();
  r.engine.start();
  assert.equal(r.clock.pending, 0);
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending, 1);
  r.feed.rows = [stateRow({ state: 'done' })];
  await r.engine.stop();
  assert.equal(r.clock.pending, 0);
  r.clock.advance(120 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done']);
});

test('an event that arrives after stop arms nothing', async () => {
  const r = rig();
  await r.engine.stop();
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending, 0);
  assert.equal(r.notifier.posts.length, 0);
});

test('with cache_expiring off, no timer is ever armed', async () => {
  const r = rig({ options: { events: { cache_expiring: { enabled: false } } } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending, 0);
  assert.equal(r.notifier.posts.length, 1);
});

test('options re-read on every event: turning a kind off takes effect at once', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.setOptions({ events: { turn_done: { enabled: false } } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.notifier.posts.length, 1);
});

// A question's deadline

const kindsOf = (r: ReturnType<typeof rig>): string[] => r.notifier.posts.map((p) => p.kind);

test('a question\'s deadline falls due although the hook wrote the row as working for it', async () => {
  for (const tool of ['AskUserQuestion', 'ExitPlanMode']) {
    const r = rig({ screens: { '%12': hidden } });
    const askedAt = r.clock.now();
    await r.engine.handle(r.now({ event: 'PreToolUse', tool }));
    r.feed.rows = [stateRow({ state: 'working', at: askedAt / 1000, detail: tool })];
    r.clock.advance(50 * MIN);
    await r.settle();
    assert.deepEqual(kindsOf(r), ['question', 'cache_expiring'], tool);
    assert.equal(r.notifier.posts[1]?.body, 'Idle 50 min — send anything within ~10 min to keep the prompt cache');
  }
});

test('a working row newer than the question means the turn runs again: no cache notice', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'PreToolUse', tool: 'AskUserQuestion' }));
  r.feed.rows = [stateRow({ state: 'working', at: T0 / 1000 + 10, detail: 'Bash ls' })];
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['question']);
  assert.equal(r.clock.pending, 0);
});

test('start arms a row that is working on a question the person has not answered, and no other working row', async () => {
  const asked = (key: string, detail: string) => stateRow({ key, state: 'working', at: (T0 - 10 * MIN) / 1000, detail, sessionId: `sess-${key}` });
  const r = rig({
    rows: [asked('12', 'AskUserQuestion'), asked('13', 'ExitPlanMode'), asked('14', 'Bash ls'), asked('15', 'AskUserQuestion ✓'), asked('16', 'ExitPlanMode ✓')],
    screens: { '%12': hidden, '%13': hidden },
  });
  r.engine.start();
  r.clock.advance(40 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => [p.id, p.kind]), [['tagents-12', 'cache_expiring'], ['tagents-13', 'cache_expiring']]);
  r.clock.advance(20 * MIN);
  await r.settle();
  assert.equal(r.notifier.posts.length, 2, 'the answered ones and the running tool never armed');
});

// A pending question and the generic permission prompt

const ASK = { event: 'PreToolUse', tool: 'AskUserQuestion', text: 'Which one?' } as const;
const PERMISSION = { event: 'Notification', sub: 'permission_prompt', text: 'Claude needs your permission' } as const;

test('a permission prompt after a question posts nothing, replaces nothing, and leaves the question\'s deadline', async () => {
  const r = rig({ screens: { '%12': hidden } });
  const askedAt = r.clock.now();
  await r.engine.handle(r.now(ASK));
  r.clock.advance(6_000);
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question'], 'the question stays up');
  assert.deepEqual(r.notifier.withdrawn, []);
  assert.ok(r.logs.some((l) => l.includes('permission') && l.includes('question')), r.logs.join('\n'));
  r.feed.rows = [stateRow({ state: 'working', at: askedAt / 1000, detail: 'AskUserQuestion' })];
  r.clock.advance(50 * MIN - 6_000);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['question', 'cache_expiring'], 'due 50 minutes after the question, not after the prompt');
});

test('the answer withdraws the question, and a permission prompt after it posts', async () => {
  const r = rig();
  await r.engine.handle(r.now(ASK));
  await r.engine.handle(r.now({ event: 'PostToolUse', tool: 'AskUserQuestion' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
  assert.equal(r.clock.pending, 0);
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question', 'permission']);
});

test('a permission prompt with no question pending posts', async () => {
  const r = rig();
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['permission']);
  assert.equal(r.notifier.posts[0]?.id, 'tagents-12');
});

test('the question ends with the answer, a prompt, the turn, the session start or the session end', async () => {
  const ends: Array<[string, Partial<AgentEvent>]> = [
    ['PostToolUse AskUserQuestion', { event: 'PostToolUse', tool: 'AskUserQuestion' }],
    ['PostToolUse ExitPlanMode', { event: 'PostToolUse', tool: 'ExitPlanMode' }],
    ['UserPromptSubmit', { event: 'UserPromptSubmit' }],
    ['Stop', { event: 'Stop' }],
    ['SessionStart', { event: 'SessionStart' }],
    ['SessionEnd', { event: 'SessionEnd' }],
  ];
  for (const [name, end] of ends) {
    const r = rig();
    await r.engine.handle(r.now(ASK));
    await r.engine.handle(r.now(PERMISSION));
    assert.deepEqual(kindsOf(r), ['question'], `${name}: held back while the question stands`);
    await r.engine.handle(r.now(end));
    await r.engine.handle(r.now(PERMISSION));
    assert.equal(kindsOf(r).at(-1), 'permission', `${name}: the question is over`);
  }
});

test('a subagent\'s Stop and another key\'s events do not end the question', async () => {
  const r = rig();
  await r.engine.handle(r.now(ASK));
  await r.engine.handle(r.now({ event: 'Stop', agentId: 'a1' }));
  await r.engine.handle(r.now({ event: 'UserPromptSubmit', key: '13', pane: '%13' }));
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question']);
  await r.engine.handle(r.now({ ...PERMISSION, key: '13', pane: '%13' }));
  assert.deepEqual(r.notifier.posts.map((p) => p.id), ['tagents-12', 'tagents-13'], 'each key has its own question');
});

test('an elicitation dialog holds nothing back: it has no answer event and no prompt after it', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Notification', sub: 'elicitation_dialog', text: 'Pick a branch' }));
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question', 'permission']);
});

test('a permission prompt more than 20 seconds after the question is a real one and posts', async () => {
  const r = rig();
  await r.engine.handle(r.now(ASK));
  r.clock.advance(20_000);
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question'], '20 seconds is still the question\'s prompt');
  r.clock.advance(10_000);
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question', 'permission'], '30 seconds is not');
});

test('a question the backend dropped, or that is switched off, holds nothing back', async () => {
  const dropped = rig();
  dropped.notifier.result = { shown: false, why: 'frontmost' };
  await dropped.engine.handle(dropped.now(ASK));
  dropped.notifier.result = { shown: true };
  await dropped.engine.handle(dropped.now(PERMISSION));
  assert.deepEqual(kindsOf(dropped), ['question', 'permission'], 'the question was tried, and the prompt is not held back');
  const off = rig({ options: { events: { question: { enabled: false } } } });
  await off.engine.handle(off.now(ASK));
  await off.engine.handle(off.now(PERMISSION));
  assert.deepEqual(kindsOf(off), ['permission']);
});

// A dropped notice and the stale one

test('a turn_done the backend drops takes down the permission notice it would have replaced', async () => {
  const r = rig();
  await r.engine.handle(r.now(PERMISSION));
  r.notifier.result = { shown: false, why: 'frontmost' };
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.deepEqual(r.notifier.calls.map((c) => c.op), ['post', 'post', 'withdraw']);
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
  r.notifier.result = { shown: true };
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12'], 'the key left the set: nothing to withdraw twice');
});

// stop drains

async function pending(p: Promise<void>): Promise<boolean> {
  let settled = false;
  void p.then(() => {
    settled = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  return !settled;
}

test('stop in the middle of a post resolves after that post settles, and the events behind it post nothing', async () => {
  const r = rig();
  const gate = r.notifier.hold();
  void r.engine.handle(r.now({ event: 'Stop' }));
  void r.engine.handle(r.now(PERMISSION));
  await new Promise((resolve) => setImmediate(resolve));
  const stopping = r.engine.stop();
  assert.equal(await pending(stopping), true, 'the post is still held');
  gate.release();
  await stopping;
  assert.deepEqual(kindsOf(r), ['turn_done'], 'the one in flight landed; the one queued behind it did not');
  await r.engine.handle(r.now({ event: 'Stop', key: '13', pane: '%13' }));
  assert.equal(r.notifier.posts.length, 1, 'nothing posts after stop');
});

test('stop in the middle of a probe resolves after that notice is posted, and nothing posts after', async () => {
  const r = rig();
  const probe = r.screen.hold();
  const gate = r.notifier.hold();
  void r.engine.handle(r.now({ event: 'Stop' }));
  void r.engine.handle(r.now(PERMISSION));
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(r.screen.probed, ['%12']);
  const stopping = r.engine.stop();
  probe.release();
  assert.equal(await pending(stopping), true, 'the probe is done, the post is held');
  gate.release();
  await stopping;
  assert.deepEqual(kindsOf(r), ['turn_done']);
  await r.settle();
  assert.equal(r.notifier.posts.length, 1);
});

test('stop with nothing in flight resolves at once, and stopping twice is one stop', async () => {
  const r = rig();
  const first = r.engine.stop();
  assert.equal(await pending(first), false);
  assert.equal(r.engine.stop(), first);
});

test('stop drains a deadline that fell due, too', async () => {
  const r = rig();
  r.feed.rows = [stateRow({ state: 'done' })];
  await r.engine.handle(r.now({ event: 'Stop' }));
  const gate = r.notifier.hold();
  r.clock.advance(50 * MIN);
  await new Promise((resolve) => setImmediate(resolve));
  const stopping = r.engine.stop();
  assert.equal(await pending(stopping), true);
  gate.release();
  await stopping;
  assert.deepEqual(kindsOf(r), ['turn_done', 'cache_expiring']);
});

// start and stop leave no timer behind

test('start that cannot follow leaves no deadline armed', () => {
  const r = rig({ rows: [stateRow({ state: 'done', at: (T0 - 10 * MIN) / 1000 })] });
  r.feed.failFollows(1);
  assert.throws(() => r.engine.start(), /cannot be watched/);
  assert.equal(r.clock.pending, 0);
});

test('stop closes the deadlines even when the follower will not close', async () => {
  const r = rig({
    rows: [stateRow({ state: 'done', at: (T0 - 10 * MIN) / 1000 })],
    feedOver: (feed) => ({
      dir: feed.dir,
      states: feed.states,
      follow: (...args) => {
        const follower = feed.follow(...args);
        return {
          close() {
            follower.close();
            throw new Error('the events switch cannot be turned off');
          },
        };
      },
    }),
  });
  r.engine.start();
  assert.equal(r.clock.pending, 1);
  await assert.rejects(r.engine.stop(), /cannot be turned off/);
  assert.equal(r.clock.pending, 0);
  r.clock.advance(120 * MIN);
  await r.settle();
  assert.equal(r.notifier.posts.length, 0);
});

// A dead follower is followed again

const SECOND = 1000;

test('a follower that dies is followed again after a second, and its events are heard', async () => {
  const r = rig();
  r.engine.start();
  r.feed.kill('the watch failed');
  assert.equal(r.feed.followers, 1);
  assert.equal(r.clock.nextDelay(), SECOND);
  assert.equal(r.logs.filter((l) => l.includes('the watch failed')).length, 1, 'one line for the death');
  r.clock.advance(SECOND - 1);
  assert.equal(r.feed.followers, 1, 'not yet');
  r.clock.advance(1);
  assert.equal(r.feed.followers, 2);
  assert.equal(r.clock.pending, 0, 'the re-follow timer exists only while the follower is dead');
  r.feed.emit(r.now({ event: 'Stop' }));
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done']);
});

test('a re-follow that fails waits twice as long, up to 5 minutes, and a follower that lived longer than that wait starts over at a second', async () => {
  const r = rig();
  r.engine.start();
  r.feed.failFollows(12);
  r.feed.kill();
  const waits: number[] = [];
  for (let i = 0; i < 12; i++) {
    waits.push(r.clock.nextDelay() ?? -1);
    r.clock.advance(r.clock.nextDelay() ?? 0);
  }
  assert.deepEqual(
    waits.map((w) => w / SECOND),
    [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300, 300]
  );
  assert.equal(r.feed.followers, 1, 'every try so far threw');
  assert.equal(r.clock.nextDelay(), 300 * SECOND);
  r.clock.advance(300 * SECOND);
  assert.equal(r.feed.followers, 2, 'the follow that worked');
  assert.equal(r.clock.pending, 0);
  r.clock.advance(300 * SECOND + 1);
  r.feed.kill();
  assert.equal(r.clock.nextDelay(), SECOND, 'it outlived the 300 s that preceded it');
  assert.ok(r.logs.some((l) => l.includes('cannot be watched')), 'a failed try is logged too');
});

test('a follower that dies at once, three times, is followed after 1, 2 and 4 seconds', async () => {
  const r = rig();
  r.engine.start();
  const waits: number[] = [];
  for (let i = 0; i < 3; i++) {
    r.feed.kill();
    waits.push((r.clock.nextDelay() ?? -1) / SECOND);
    r.clock.advance(r.clock.nextDelay() ?? 0);
  }
  assert.deepEqual(waits, [1, 2, 4]);
  assert.equal(r.feed.followers, 4);
  assert.equal(r.logs.filter((l) => l.includes('feed follower died')).length, 3);
});

test('a follower that keeps dying at once is followed every 5 minutes at most', async () => {
  const r = rig();
  r.engine.start();
  for (let i = 0; i < 12; i++) {
    r.feed.kill();
    r.clock.advance(r.clock.nextDelay() ?? 0);
  }
  r.feed.kill();
  assert.equal(r.clock.nextDelay(), 300 * SECOND);
});

test('a follower that heard an event, or lived longer than the wait before it, starts the wait over', async () => {
  const heard = rig();
  heard.engine.start();
  for (let i = 0; i < 3; i++) {
    heard.feed.kill();
    heard.clock.advance(heard.clock.nextDelay() ?? 0);
  }
  heard.feed.emit(heard.now({ event: 'PreToolUse', tool: 'Bash' }));
  heard.feed.kill();
  assert.equal(heard.clock.nextDelay(), SECOND, 'it delivered an event');
  const lived = rig();
  lived.engine.start();
  for (let i = 0; i < 3; i++) {
    lived.feed.kill();
    lived.clock.advance(lived.clock.nextDelay() ?? 0);
  }
  lived.clock.advance(4 * SECOND);
  lived.feed.kill();
  assert.equal(lived.clock.nextDelay(), 8 * SECOND, 'not longer than the 4 s before it');
  lived.clock.advance(8 * SECOND);
  lived.clock.advance(8 * SECOND + 1);
  lived.feed.kill();
  assert.equal(lived.clock.nextDelay(), SECOND, 'longer than the 8 s before it');
});

test('after a re-follow the state rows are armed again: what the events said while it was dead is in them', async () => {
  const r = rig();
  r.engine.start();
  r.feed.kill();
  r.feed.rows = [
    stateRow({ key: '12', state: 'done', at: (T0 - 5 * MIN) / 1000 }),
    stateRow({ key: '13', state: 'working', detail: 'AskUserQuestion', at: (T0 - 2 * MIN) / 1000, sessionId: 'sess-13' }),
  ];
  assert.equal(r.clock.pending, 1, 'only the re-follow timer: nothing is armed while the follower is dead');
  r.clock.advance(SECOND);
  assert.equal(r.feed.followers, 2);
  assert.equal(r.clock.pending, 1, 'one deadline timer now');
  r.clock.advance(49 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => [p.id, p.kind]), [['tagents-12', 'cache_expiring'], ['tagents-13', 'cache_expiring']]);
});

test('a re-follow that fails arms nothing, and the one that works afterwards arms once', async () => {
  const r = rig();
  r.engine.start();
  r.feed.failFollows(1);
  r.feed.kill();
  r.feed.rows = [stateRow({ state: 'done', at: (T0 - 5 * MIN) / 1000 })];
  r.clock.advance(SECOND);
  assert.equal(r.clock.pending, 1, 'only the next re-follow timer');
  r.clock.advance(2 * SECOND);
  assert.equal(r.feed.followers, 2);
  assert.equal(r.clock.pending, 1, 'the deadline timer');
  r.clock.advance(46 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['cache_expiring']);
});

test('stop cancels a re-follow that is waiting', async () => {
  const r = rig();
  r.engine.start();
  r.feed.kill();
  assert.equal(r.clock.pending, 1);
  await r.engine.stop();
  assert.equal(r.clock.pending, 0);
  r.clock.advance(10 * MIN);
  assert.equal(r.feed.followers, 1);
});

test('a follower that dies after stop is not followed again', async () => {
  const r = rig();
  r.engine.start();
  await r.engine.stop();
  r.feed.kill();
  assert.equal(r.clock.pending, 0);
});

test('the re-follow timer is beside the deadline timer, and start while dead does not follow twice', async () => {
  const r = rig({ rows: [stateRow({ state: 'done', at: (T0 - 10 * MIN) / 1000 })] });
  r.engine.start();
  assert.equal(r.clock.pending, 1);
  r.feed.kill();
  assert.equal(r.clock.pending, 2);
  r.engine.start();
  assert.equal(r.clock.pending, 2);
  r.clock.advance(SECOND);
  assert.equal(r.feed.followers, 2);
});

// A pane that is gone

test('no cache notice for a pane tmux says is gone, and the reason is logged; other notices still post', async () => {
  const r = rig({ screens: { '%12': NO_SUCH_PANE } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done']);
  assert.ok(!('terminalPid' in (r.notifier.posts[0] ?? {})));
  assert.ok(r.logs.some((l) => l.includes('cache_expiring') && l.includes('12') && l.includes('pane')), r.logs.join('\n'));
});

test('a tmux that did not answer is not a pane that is gone: the cache notice posts', async () => {
  const r = rig({ screens: { '%12': null } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done', 'cache_expiring']);
});

test('a session with no pane has no pane to be gone', async () => {
  const r = rig({
    options: { sessions: { headless: true } },
    rows: [stateRow({ key: 's-abc', state: 'done', at: (T0 - 55 * MIN) / 1000, sessionId: 'abc' })],
  });
  r.engine.start();
  r.clock.advance(0);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['cache_expiring']);
});

// A wake late in the window

test('a deadline that fell due while the Mac slept posts on the next event of another chat, before its own timer', async () => {
  const r = rig({ screens: { '%12': hidden } });
  r.engine.start();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.sleepPausingTimers(55 * MIN);
  r.clock.advance(0);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done'], 'the timer still owes its awake time');
  r.feed.emit(r.now({ event: 'Stop', key: '13', pane: '%13', sessionId: 'sess-13' }));
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => [p.id, p.kind]), [['tagents-12', 'turn_done'], ['tagents-13', 'turn_done'], ['tagents-12', 'cache_expiring']]);
  assert.match(r.notifier.posts[2]?.body ?? '', /Idle 55 min/);
  assert.equal(r.clock.pending, 1, 'the other chat\'s deadline');
});

test('an event of the sleeping chat itself, a prompt, cancels the deadline before the sweep can warn', async () => {
  const r = rig();
  r.engine.start();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.sleepPausingTimers(55 * MIN);
  r.feed.emit(r.now({ event: 'UserPromptSubmit' }));
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done']);
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
});

test('events that reach handle directly do not sweep: only what the follower delivers does', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.feed.rows = [stateRow({ state: 'done' })];
  r.clock.sleepPausingTimers(55 * MIN);
  await r.engine.handle(r.now({ event: 'Stop', key: '13', pane: '%13' }));
  assert.deepEqual(kindsOf(r), ['turn_done', 'turn_done']);
});

// A subagent notice has its own id

test('a subagent notice does not replace the question or the permission notice of its key', async () => {
  const r = rig({ options: { events: { subagent_done: { enabled: true } } } });
  await r.engine.handle(r.now(ASK));
  await r.engine.handle(r.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  assert.deepEqual(r.notifier.posts.map((p) => p.id), ['tagents-12', 'tagents-12-sub']);
  assert.equal(r.notifier.posts[1]?.thread, 'sess-1');
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.deepEqual([...r.notifier.withdrawn].sort(), ['tagents-12', 'tagents-12-sub'], 'a prompt takes down both');
});

test('a dropped subagent notice takes down only an older subagent notice', async () => {
  const r = rig({ options: { events: { subagent_done: { enabled: true } } } });
  await r.engine.handle(r.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  await r.engine.handle(r.now(PERMISSION));
  r.notifier.result = { shown: false, why: 'frontmost' };
  await r.engine.handle(r.now({ event: 'SubagentStop', agentId: 'a2', sub: 'Plan' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12-sub'], 'the permission notice stays');
});

// A backend that keeps failing

test('a failing backend is logged once per distinct message, and once more when it works again', async () => {
  const r = rig();
  const failed = () => r.logs.filter((l) => l.includes('post failed'));
  r.notifier.failPosts(3, 'helper exited 1');
  for (let i = 0; i < 3; i++) await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(failed().length, 1, failed().join('\n'));
  assert.ok(failed()[0]?.includes('helper exited 1'));
  r.notifier.failPosts(2, 'the helper is missing');
  await r.engine.handle(r.now({ event: 'Stop' }));
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(failed().length, 2, 'a message not seen yet is logged');
  r.notifier.failPosts(1, 'helper exited 1');
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(failed().length, 2, 'seen since the last success: not again');
  assert.equal(r.logs.filter((l) => l.includes('posting works again')).length, 0);
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.logs.filter((l) => l.includes('posting works again')).length, 1);
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.logs.filter((l) => l.includes('posting works again')).length, 1, 'said once');
  r.notifier.failPosts(1, 'helper exited 1');
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(failed().length, 3, 'after a success the message counts as new again');
});

// Cleanup

test('a new session in the pane withdraws what the old one asked, and the question with it', async () => {
  const r = rig();
  await r.engine.handle(r.now(ASK));
  await r.engine.handle(r.now({ event: 'SessionStart' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
  assert.equal(r.clock.pending, 0);
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question', 'permission']);
});

test('a pane tmux says is gone drops the question it held back with, and leaves its notices up', async () => {
  const screens: Record<string, Screen | null | typeof NO_SUCH_PANE> = { '%12': null };
  const r = rig({ screens, options: { events: { subagent_done: { enabled: true } } } });
  await r.engine.handle(r.now(ASK));
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question'], 'held back while the pane is there');
  screens['%12'] = NO_SUCH_PANE;
  await r.engine.handle(r.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  assert.deepEqual(r.notifier.withdrawn, []);
  await r.engine.handle(r.now(PERMISSION));
  assert.deepEqual(kindsOf(r), ['question', 'subagent_done', 'permission']);
});

// One warning for one idle period

test('a re-follow does not warn again about a key it already warned about', async () => {
  const r = rig({ rows: [stateRow({ state: 'done', at: T0 / 1000 })] });
  r.engine.start();
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['cache_expiring']);
  r.feed.kill();
  r.clock.advance(SECOND);
  assert.equal(r.feed.followers, 2);
  assert.equal(r.clock.pending, 0, 'the row is the same idle period: nothing armed');
  r.clock.advance(5 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['cache_expiring']);
});

test('a row written after the warning is a new idle period, and the re-follow arms it', async () => {
  const r = rig({ rows: [stateRow({ state: 'done', at: T0 / 1000 })] });
  r.engine.start();
  r.clock.advance(50 * MIN);
  await r.settle();
  r.feed.kill();
  r.feed.rows = [stateRow({ state: 'done', at: (T0 + 52 * MIN) / 1000 })];
  r.clock.advance(SECOND);
  assert.equal(r.clock.pending, 1);
});

test('a prompt, or a new turn, lets a key be warned about again', async () => {
  const r = rig();
  r.feed.rows = [stateRow({ state: 'done' })];
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done', 'cache_expiring']);
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  const second = r.clock.now();
  r.feed.rows = [stateRow({ state: 'done', at: second / 1000 })];
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.clock.advance(50 * MIN);
  await r.settle();
  assert.deepEqual(kindsOf(r), ['turn_done', 'cache_expiring', 'turn_done', 'cache_expiring']);
});
