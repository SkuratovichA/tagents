// node --test screen.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Exec } from '../src/exec.ts';
import { NO_SUCH_PANE, parseScreen, tmuxScreen } from '../src/screen.ts';

test('a client looking at the pane\'s window: visible, with that client\'s pid', () => {
  const out = [
    'P|@|@3|@|✳ build',
    'C|@|1700000100|@|4001|@|@3',
    'C|@|1700000200|@|4002|@|@1',
    '',
  ].join('\n');
  assert.deepEqual(parseScreen(out), { visible: true, clientPid: 4001, paneTitle: '✳ build' });
});

test('no client on the window: not visible, the most recently active client\'s pid', () => {
  const out = [
    'P|@|@3|@|build',
    'C|@|1700000100|@|4001|@|@1',
    'C|@|1700000900|@|4002|@|@2',
    'C|@|1700000500|@|4003|@|@1',
  ].join('\n');
  assert.deepEqual(parseScreen(out), { visible: false, clientPid: 4002, paneTitle: 'build' });
});

test('two clients on the window: the more recently active one gets the click', () => {
  const out = [
    'P|@|@3|@|build',
    'C|@|1700000100|@|4001|@|@3',
    'C|@|1700000900|@|4002|@|@3',
    'C|@|1700009999|@|4003|@|@9',
  ].join('\n');
  assert.deepEqual(parseScreen(out), { visible: true, clientPid: 4002, paneTitle: 'build' });
});

test('no clients at all: not visible, and no pid key', () => {
  const s = parseScreen('P|@|@3|@|build\n');
  assert.deepEqual(s, { visible: false, paneTitle: 'build' });
  assert.ok(s && !('clientPid' in s));
});

test('a title that holds the separator keeps everything after the second one', () => {
  const s = parseScreen('P|@|@3|@|a |@| b |@|\nC|@|1|@|9|@|@3');
  assert.deepEqual(s, { visible: true, clientPid: 9, paneTitle: 'a |@| b |@|' });
});

test('an empty title is a title', () => {
  assert.deepEqual(parseScreen('P|@|@3|@|\n'), { visible: false, paneTitle: '' });
});

test('empty output, or output with no pane line, is null', () => {
  assert.equal(parseScreen(''), null);
  assert.equal(parseScreen('\n'), null);
  assert.equal(parseScreen('C|@|1|@|9|@|@3\n'), null);
});

test('a client line that is not numbers is skipped, not trusted', () => {
  const s = parseScreen('P|@|@3|@|t\nC|@|soon|@|9|@|@3\nC|@|5|@|x|@|@3\nC|@|7|@|8|@|@1');
  assert.deepEqual(s, { visible: false, clientPid: 8, paneTitle: 't' });
});

const VIEWPORT = 'C|@|1700000900|@|5555|@|@3|@|/dev/ttys009|@|alpha';

test('Seen through the viewport: the dashboard terminal stands in for the viewport, and its pid is the one used', () => {
  const out = [
    'P|@|@3|@|build',
    'V|@|/dev/ttys009',
    VIEWPORT,
    'C|@|1700000100|@|4001|@|@7|@|/dev/ttys001|@|tagents',
    'C|@|1700000300|@|4002|@|@7|@|/dev/ttys002|@|tagents',
    'C|@|1700009999|@|4003|@|@1|@|/dev/ttys003|@|beta',
    '',
  ].join('\n');
  assert.deepEqual(parseScreen(out), { visible: true, clientPid: 4002, paneTitle: 'build' });
});

test('The dashboard is not on screen: a pane only the viewport shows is not visible, and the viewport pid is no candidate', () => {
  const out = [
    'P|@|@3|@|build',
    'V|@|/dev/ttys009',
    VIEWPORT,
    'C|@|1700000100|@|4003|@|@1|@|/dev/ttys003|@|beta',
    '',
  ].join('\n');
  assert.deepEqual(parseScreen(out), { visible: false, clientPid: 4003, paneTitle: 'build' });
  const alone = parseScreen(['P|@|@3|@|build', 'V|@|/dev/ttys009', VIEWPORT].join('\n'));
  assert.deepEqual(alone, { visible: false, paneTitle: 'build' });
});

test('a real client on the window beats the viewport, and with the option unset the extra fields change nothing', () => {
  const direct = ['P|@|@3|@|b', 'V|@|/dev/ttys009', VIEWPORT, 'C|@|1|@|4001|@|@3|@|/dev/ttys001|@|beta', 'C|@|2|@|4002|@|@7|@|/dev/ttys002|@|tagents'].join('\n');
  assert.deepEqual(parseScreen(direct), { visible: true, clientPid: 4001, paneTitle: 'b' });
  const unset = ['P|@|@3|@|b', 'V|@|', 'C|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha', 'C|@|2|@|4002|@|@7|@|/dev/ttys002|@|tagents'].join('\n');
  assert.deepEqual(parseScreen(unset), { visible: true, clientPid: 5555, paneTitle: 'b' });
});

function fakeExec(result: Awaited<ReturnType<Exec>> | Error) {
  const calls: Array<{ file: string; args: readonly string[]; timeoutMs: number }> = [];
  const exec: Exec = (file, args, o) => {
    calls.push({ file, args: [...args], timeoutMs: o.timeoutMs });
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result);
  };
  return { exec, calls };
}

const ok = (stdout: string) => ({ code: 0, stdout, stderr: '', timedOut: false });

test('tmuxScreen asks tmux once, with two commands and no tab in a format', async () => {
  const { exec, calls } = fakeExec(ok('P|@|@3|@|build\nC|@|5|@|9|@|@3\n'));
  const screen = await tmuxScreen(exec)('%12');
  assert.deepEqual(screen, { visible: true, clientPid: 9, paneTitle: 'build' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.file, 'tmux');
  assert.deepEqual(calls[0]?.args, [
    'display',
    '-p',
    '-t',
    '%12',
    'P|@|#{window_id}|@|#{pane_title}',
    ';',
    'list-clients',
    '-F',
    'C|@|#{client_activity}|@|#{client_pid}|@|#{window_id}|@|#{client_tty}|@|#{client_session}',
    ';',
    'display',
    '-p',
    '-t',
    '%12',
    'V|@|#{@tagents_viewport_tty}',
  ]);
  assert.equal(calls[0]?.timeoutMs, 2000);
  for (const a of calls[0]?.args ?? []) assert.ok(!a.includes('\t'), 'a literal tab in a tmux format renders as _ without a UTF-8 locale');
});

test('a pane line with no window id is the pane tmux 3.7 answers with for one that does not exist', () => {
  assert.equal(parseScreen('P|@||@|\nC|@|5|@|9|@|@3\n'), NO_SUCH_PANE);
  assert.equal(parseScreen('C|@|5|@|9|@|@3\n'), null, 'no pane line at all says nothing');
});

test('tmuxScreen: tmux saying the pane is not there is NO_SUCH_PANE, and only that', async () => {
  assert.equal(await tmuxScreen(fakeExec(ok('P|@||@|\n')).exec)('%99'), NO_SUCH_PANE);
  assert.equal(await tmuxScreen(fakeExec({ code: 1, stdout: '', stderr: "can't find pane: %99", timedOut: false }).exec)('%99'), NO_SUCH_PANE);
  const nothing = await tmuxScreen(fakeExec({ code: 1, stdout: '', stderr: 'no server running on /tmp/tmux-501/default', timedOut: false }).exec)('%99');
  assert.equal(nothing, null, 'no server could be the wrong socket, not a closed pane');
  const slow = await tmuxScreen(fakeExec({ code: null, stdout: '', stderr: "can't find pane: %99", timedOut: true }).exec)('%99');
  assert.equal(slow, null, 'a timeout is not an answer');
});

test('tmuxScreen: a failing tmux, a timeout and a tmux that cannot start are all null', async () => {
  assert.equal(await tmuxScreen(fakeExec({ code: 1, stdout: '', stderr: 'unknown option', timedOut: false }).exec)('%99'), null);
  assert.equal(await tmuxScreen(fakeExec({ code: null, stdout: '', stderr: '', timedOut: true }).exec)('%12'), null);
  assert.equal(await tmuxScreen(fakeExec(new Error('spawn tmux ENOENT')).exec)('%12'), null);
  assert.equal(await tmuxScreen(fakeExec(ok('')).exec)('%12'), null);
});
