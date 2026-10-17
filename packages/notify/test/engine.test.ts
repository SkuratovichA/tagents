// node --test engine.test.ts
//
// The engine against a fake feed, notifier, clock and screen probe. Timers are
// the fake clock's, so nothing here sleeps: a test that waits for real time
// would be the flaky one.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import type { AgentEvent, AgentStateRow } from '@tagents/core';
import { createEngine } from '../src/engine.ts';
import type { Screen } from '../src/screen.ts';
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
} from './fakes.ts';

// Text assertions below are English; the developer's own shell may say otherwise.
process.env['TAGENTS_LOCALE'] = 'en';

const TAGENTS = '/opt/checkout/tagents';
const BASE_ENV = { PATH: '/usr/bin:/bin', HOME: '/home/u' };

interface RigOptions {
  readonly options?: unknown;
  readonly screens?: Record<string, Screen | null>;
  readonly env?: NodeJS.ProcessEnv;
  readonly rows?: AgentStateRow[];
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
    feed,
    notifier,
    options: () => current,
    screen,
    clock,
    log: (...parts) => logs.push(parts.join(' ')),
    tagents: TAGENTS,
    hostname: 'mbp.local',
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
  assert.equal(r.clock.pending(), 1);
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
    hostname: 'mbp',
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
  assert.equal(r.clock.pending(), 1);
  await r.engine.handle(r.now({ event: 'SessionEnd', sub: 'logout' }));
  assert.deepEqual(r.notifier.withdrawn, ['tagents-12']);
  assert.equal(r.clock.pending(), 0);
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

test('the click env is PATH and HOME, plus the three that matter when they are set', async () => {
  const bare = rig({ env: { ...BASE_ENV, SHELL: '/bin/zsh', SECRET: 'no' } });
  await bare.engine.handle(bare.now());
  assert.deepEqual(bare.notifier.posts[0]?.click.env, BASE_ENV);
  const full = rig({
    env: { ...BASE_ENV, TMUX_TMPDIR: '/tmp/tm', TA_STATE_DIR: '/tmp/st', TAGENTS_CONFIG_DIR: '/tmp/cfg', SECRET: 'no' },
  });
  await full.engine.handle(full.now());
  assert.deepEqual(full.notifier.posts[0]?.click.env, {
    ...BASE_ENV,
    TMUX_TMPDIR: '/tmp/tm',
    TA_STATE_DIR: '/tmp/st',
    TAGENTS_CONFIG_DIR: '/tmp/cfg',
  });
});

test('a session with no pane is ignored unless sessions.headless is on', async () => {
  const off = rig();
  await off.engine.handle(off.now({ key: 's-abc', pane: '' }));
  assert.equal(off.notifier.posts.length, 0);
  assert.equal(off.clock.pending(), 0);
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
  r.engine.stop();
  assert.equal(r.feed.closed, true);
  assert.equal(r.clock.pending(), 0);
  r.engine.stop();
});

// Cache deadlines

test('a turn arms one deadline and a prompt cancels it', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending(), 1);
  await r.engine.handle(r.now({ event: 'UserPromptSubmit' }));
  assert.equal(r.clock.pending(), 0);
  await r.engine.handle(r.now({ event: 'Notification', sub: 'permission_prompt', text: 'Allow?' }));
  assert.equal(r.clock.pending(), 1);
  await r.engine.handle(r.now({ event: 'SessionStart' }));
  assert.equal(r.clock.pending(), 0);
});

test('a question and a permission prompt arm it too; a subagent finishing does not', async () => {
  const q = rig();
  await q.engine.handle(q.now({ event: 'PreToolUse', tool: 'AskUserQuestion', text: 'Which?' }));
  assert.equal(q.clock.pending(), 1);
  const s = rig();
  await s.engine.handle(s.now({ event: 'SubagentStop', agentId: 'a1', sub: 'Explore' }));
  assert.equal(s.clock.pending(), 0);
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
  assert.equal(r.clock.pending(), 0);
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
    r.feed.rows = state === null ? [] : [stateRow({ state })];
    r.clock.advance(50 * MIN);
    await r.settle();
    assert.equal(r.notifier.posts.length, before, String(state));
    assert.equal(r.clock.pending(), 0, String(state));
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
  assert.equal(r.clock.pending(), 0);
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
  assert.equal(r.clock.pending(), 1, 'the second turn\'s own deadline is still waiting');
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
  assert.equal(r.clock.pending(), 1, 'one timer for the earliest');
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
  assert.equal(r.clock.pending(), 0);
});

test('start leaves a row that is already past the TTL alone, and arms nothing', async () => {
  const now = T0;
  const r = rig({ rows: [stateRow({ state: 'done', at: (now - 61 * MIN) / 1000 })] });
  r.engine.start();
  assert.equal(r.clock.pending(), 0);
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
  assert.equal(off.clock.pending(), 0, 'headless sessions count only when asked for');
});

test('nothing is pending at start with no rows, and nothing fires after stop', async () => {
  const r = rig();
  r.engine.start();
  assert.equal(r.clock.pending(), 0);
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending(), 1);
  r.feed.rows = [stateRow({ state: 'done' })];
  r.engine.stop();
  assert.equal(r.clock.pending(), 0);
  r.clock.advance(120 * MIN);
  await r.settle();
  assert.deepEqual(r.notifier.posts.map((p) => p.kind), ['turn_done']);
});

test('an event that arrives after stop arms nothing', async () => {
  const r = rig();
  r.engine.stop();
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending(), 0);
  assert.equal(r.notifier.posts.length, 0);
});

test('with cache_expiring off, no timer is ever armed', async () => {
  const r = rig({ options: { events: { cache_expiring: { enabled: false } } } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.clock.pending(), 0);
  assert.equal(r.notifier.posts.length, 1);
});

test('options re-read on every event: turning a kind off takes effect at once', async () => {
  const r = rig();
  await r.engine.handle(r.now({ event: 'Stop' }));
  r.setOptions({ events: { turn_done: { enabled: false } } });
  await r.engine.handle(r.now({ event: 'Stop' }));
  assert.equal(r.notifier.posts.length, 1);
});
