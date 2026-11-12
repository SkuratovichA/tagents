// node --test notice.test.ts
//
// The notice `send` and `test` show, and the click that goes with it. The service that follows the event stream posts the same notices from Rust (tests/rust-notify-parity.sh compares the two).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildNotice, clickFor, eventFromRow, noticeId } from '../src/notice.ts';
import type { Screen } from '../src/screen.ts';
import { event, fakeScreen, stateRow } from './fakes.ts';

// Text assertions below are English; the developer's own shell may say otherwise.
process.env['TAGENTS_LOCALE'] = 'en';

const TAGENTS = '/opt/checkout/tagents';
const BASE_ENV = { PATH: '/usr/bin:/bin', HOME: '/home/u' };
const visible: Screen = { visible: true, clientPid: 4242, paneTitle: '✳ build agent' };
const hidden: Screen = { visible: false, clientPid: 777, paneTitle: '✳ build agent' };

const deps = (screens: Record<string, Screen> = {}, env: NodeJS.ProcessEnv = BASE_ENV) => ({
  screen: fakeScreen(screens),
  labelsDir: '/nonexistent/labels',
  tagents: TAGENTS,
  hostname: () => 'mbp.local',
  env,
  log: () => undefined,
});

test('the notice is under the key\'s id and the session\'s thread', async () => {
  const n = await buildNotice('turn_done', event({ sessionId: 'sess-1' }), {}, { skipVisible: true, click: 'dock' }, deps());
  assert.equal(n.id, noticeId(event().key));
  assert.equal(n.thread, 'sess-1');
  assert.equal(n.kind, 'turn_done');
});

test('the click: dock is the dashboard\'s Enter on that chat', () => {
  assert.deepEqual(clickFor(event({ cwd: '/work/proj', sessionId: 'sess-1', pane: '%12' }), 'dock', TAGENTS, BASE_ENV).argv, [TAGENTS, '--act', 'open', '%12', 'live', 'sess-1', '/work/proj']);
});

test('the click: goto is the agent\'s own window', () => {
  assert.deepEqual(clickFor(event({ pane: '%12' }), 'goto', TAGENTS, BASE_ENV).argv, [TAGENTS, '--goto', '%12']);
});

test('the click: focus is the terminal only, and so is a click with no pane', () => {
  assert.deepEqual(clickFor(event({ pane: '%12' }), 'focus', TAGENTS, BASE_ENV).argv, []);
  assert.deepEqual(clickFor(event({ pane: '' }), 'dock', TAGENTS, BASE_ENV).argv, []);
});

test('the click env is PATH and HOME, plus the locale and the variables that pick the tmux server, state and config when they are set', () => {
  const click = (env: NodeJS.ProcessEnv) => clickFor(event(), 'dock', TAGENTS, env).env;
  assert.deepEqual(click({ ...BASE_ENV, SHELL: '/bin/zsh', SECRET: 'no' }), BASE_ENV);
  const set = {
    LANG: 'ru_RU.UTF-8',
    LC_ALL: 'en_US.UTF-8',
    LC_CTYPE: 'UTF-8',
    TMUX_TMPDIR: '/tmp/tm',
    TA_STATE_DIR: '/tmp/st',
    TAGENTS_CONFIG_DIR: '/tmp/cfg',
    XDG_CONFIG_HOME: '/tmp/xdg',
    TA_CONFIG: '/tmp/cfg/config.toml',
  };
  assert.deepEqual(click({ ...BASE_ENV, ...set, SECRET: 'no' }), { ...BASE_ENV, ...set });
  assert.deepEqual(click({ ...BASE_ENV, LANG: '' }), BASE_ENV, 'an empty variable stays absent');
});

test('skip_visible with the pane in some client\'s window: skip if frontmost, that client\'s pid', async () => {
  const n = await buildNotice('turn_done', event(), {}, { skipVisible: true, click: 'dock' }, deps({ '%12': visible }));
  assert.equal(n.skipIfFrontmost, true);
  assert.equal(n.terminalPid, 4242);
});

test('a pane nobody is looking at has no skip and the most active client\'s pid; skip_visible off keeps the client but not the skip', async () => {
  const hiddenNotice = await buildNotice('turn_done', event(), {}, { skipVisible: true, click: 'dock' }, deps({ '%12': hidden }));
  assert.ok(!('skipIfFrontmost' in hiddenNotice));
  assert.equal(hiddenNotice.terminalPid, 777);
  const off = await buildNotice('turn_done', event(), {}, { skipVisible: false, click: 'dock' }, deps({ '%12': visible }));
  assert.ok(!('skipIfFrontmost' in off));
  assert.equal(off.terminalPid, 4242);
});

test('a pane tmux does not know has no pid and is named by its label', async () => {
  const n = await buildNotice('turn_done', event({ label: 'ticket-agent' }), {}, { skipVisible: true, click: 'dock' }, deps());
  assert.ok(!('terminalPid' in n) && !('skipIfFrontmost' in n));
  assert.equal(n.title, 'ticket-agent');
});

test('a probe that rejects costs the pid, not the notice', async () => {
  const logs: string[] = [];
  const d = { ...deps(), screen: () => Promise.reject(new Error('tmux gone')), log: (...p: string[]) => void logs.push(p.join(' ')) };
  const n = await buildNotice('turn_done', event(), {}, { skipVisible: true, click: 'dock' }, d);
  assert.ok(!('terminalPid' in n));
  assert.ok(logs.some((l) => l.includes('screen probe failed') && l.includes('tmux gone')));
});

test('a state row becomes the event it stands for: blocked is a Notification, anything else a Stop, and its time is in milliseconds', () => {
  const row = stateRow({ key: '12', state: 'blocked', at: 1700000000, sessionId: 's' });
  const e = eventFromRow(row, new Map([['s', 'my label']]));
  assert.equal(e.event, 'Notification');
  assert.equal(e.at, 1700000000 * 1000);
  assert.equal(e.pane, '%12');
  assert.equal(e.label, 'my label');
  assert.equal(eventFromRow(stateRow({ state: 'done' }), new Map()).event, 'Stop');
  assert.equal(eventFromRow(stateRow({ key: 'abc' }), new Map()).pane, '');
});
