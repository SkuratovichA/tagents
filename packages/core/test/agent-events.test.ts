// The event stream: parsing one line, switching it on and off, and following
// the file the hook appends to.
//
// Every follower case runs against real files in a temp dir and waits for the
// EVENT it expects, never for a fixed time. A wait that never ends fails after
// 2 s naming what did not arrive; the one longer wait is the grace case, whose
// delivery is by design 2 s after the rotation. "Nothing arrived" is proved
// with a second follower: once it has seen a later line, the first one has had
// its chance.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, afterEach, test, type TestContext } from 'node:test';
import { pathToFileURL } from 'node:url';
import { z } from 'zod';
import {
  EVENTS_FILE,
  EVENTS_ROTATE_BYTES,
  EVENTS_SWITCH,
  createAgentFeed,
  eventsOn,
  followAgentEvents,
  parseEventLine,
  setEventsOn,
  type AgentEvent,
  type EventFollower,
} from '../src/agent-events.ts';
import { readAgentState } from '../src/agent-state.ts';
import { drained, tmpDir } from '../src/testkit.ts';
import { HERE, NODE, writeStateRow } from './helpers.ts';

const SRC = path.resolve(HERE, '..', 'src', 'agent-events.ts');

// ------------------------------------------------------------------ plumbing ---

interface LineFields {
  at?: number | string;
  event?: string;
  key?: string;
  sid?: string;
  agent?: string;
  pane?: string;
  cwd?: string;
  transcript?: string;
  config?: string;
  tool?: string;
  sub?: string;
  text?: string;
  label?: string;
}

/** One line as the hook writes it: 13 tab separated fields and a newline. */
function lineOf(f: LineFields = {}, terminator = '\n'): string {
  return (
    [
      f.at ?? 1_760_000_000,
      f.event ?? 'Stop',
      f.key ?? '12',
      f.sid ?? 'sess-a',
      f.agent ?? '',
      f.pane ?? '%12',
      f.cwd ?? '/Users/demo/git/demo',
      f.transcript ?? '/Users/demo/.claude/projects/demo/sess-a.jsonl',
      f.config ?? '',
      f.tool ?? '',
      f.sub ?? '',
      f.text ?? '',
      f.label ?? '',
    ].join('\t') + terminator
  );
}

const cleanups: Array<() => void> = [];
afterEach(() => {
  while (cleanups.length > 0) cleanups.pop()?.();
});
const cleanup = (fn: () => void): void => {
  cleanups.push(fn);
};

/** A fresh state dir with its events file in it, and a follower already started on it when asked to. */
function fixture(): { dir: string; file: string } {
  const root = tmpDir('agent-events-test');
  cleanup(() => fs.rmSync(root, { recursive: true, force: true }));
  const dir = path.join(root, 'agent-state');
  fs.mkdirSync(dir);
  return { dir, file: path.join(dir, EVENTS_FILE) };
}

interface Run {
  readonly got: AgentEvent[];
  readonly errors: Error[];
  /** What reached onDead. */
  readonly dead: Error[];
  readonly follower: EventFollower;
  readonly texts: () => string[];
  /** Wait until `n` events are in, or fail naming `what`. */
  readonly until: (n: number, what: string, timeoutMs?: number) => Promise<void>;
}

function follow(
  dir: string,
  extra: { rotateBytes?: number; onEvent?: (e: AgentEvent) => void; onDead?: (e: Error) => void } = {}
): Run {
  const got: AgentEvent[] = [];
  const errors: Error[] = [];
  const dead: Error[] = [];
  const follower = followAgentEvents(
    (e) => {
      got.push(e);
      extra.onEvent?.(e);
    },
    {
      dir,
      onError: (e) => errors.push(e),
      onDead: (e) => {
        dead.push(e);
        extra.onDead?.(e);
      },
      ...(extra.rotateBytes === undefined ? {} : { rotateBytes: extra.rotateBytes }),
    }
  );
  cleanup(() => follower.close());
  return {
    got,
    errors,
    dead,
    follower,
    texts: () => got.map((e) => e.text),
    until: (n, what, timeoutMs = 2000) =>
      drained(() => got.length >= n, { what: `${what} (${got.length}/${n} events so far)`, timeoutMs, everyMs: 5 }),
  };
}

/**
 * Run `start`, which opens a watcher on the events file, and hand back that
 * FSWatcher so a test can make it fail from the outside. fs.watch is only spied
 * on, not replaced, and goes back to itself before this returns.
 */
function withWatcher<T>(t: TestContext, start: () => T): { started: T; watcher: fs.FSWatcher } {
  const spy = t.mock.method(fs, 'watch');
  try {
    const started = start();
    const watcher = spy.mock.calls[0]?.result;
    assert.ok(watcher, 'starting opened a watcher');
    return { started, watcher };
  } finally {
    spy.mock.restore();
  }
}

/** What a child script prints on exit: the handles it still held once it was done. */
const ChildReport = z.object({
  rotated: z.boolean(),
  pendingBefore: z.boolean().optional(),
  deaths: z.number(),
  left: z.array(z.string()),
  exitedAfterMs: z.number(),
});

/**
 * A child process, because the test runner has timers of its own. It is killed
 * after 8 s, which only happens when something it opened keeps it alive.
 */
function runChild(script: string): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(NODE, [script], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    const killer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`the child did not exit within 8 s of starting: a handle is still holding it\n${stdout}${stderr}`));
    }, 8000);
    child.stdout.on('data', (b: Buffer) => (stdout += b.toString()));
    child.stderr.on('data', (b: Buffer) => (stderr += b.toString()));
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(killer);
      resolve({ code, stdout, stderr });
    });
  });
}

// ------------------------------------------------------------ parseEventLine ---

test('parseEventLine: a good line gives every field, with at in milliseconds', () => {
  const got = parseEventLine(
    lineOf(
      {
        at: 1_760_000_123,
        event: 'PreToolUse',
        key: 's-sess-b',
        sid: 'sess-b',
        agent: 'agent-7',
        pane: '',
        cwd: '/work',
        transcript: '/work/t.jsonl',
        config: '/Users/demo/.claude-work',
        tool: 'AskUserQuestion',
        sub: 'Which one?',
        text: 'Pick one…',
        label: 'build',
      },
      ''
    )
  );
  assert.deepEqual(got, {
    at: 1_760_000_123_000,
    event: 'PreToolUse',
    key: 's-sess-b',
    sessionId: 'sess-b',
    agentId: 'agent-7',
    pane: '',
    cwd: '/work',
    transcript: '/work/t.jsonl',
    configDir: '/Users/demo/.claude-work',
    tool: 'AskUserQuestion',
    sub: 'Which one?',
    text: 'Pick one…',
    label: 'build',
  });
});

test('parseEventLine: every event the hook writes is accepted', () => {
  for (const event of ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification', 'Stop', 'SubagentStop', 'SessionEnd']) {
    assert.equal(parseEventLine(lineOf({ event }, ''))?.event, event, event);
  }
});

test('parseEventLine: twelve fields, an unknown event and a non-numeric at give null', () => {
  const twelve = lineOf({}, '').split('\t').slice(0, 12).join('\t');
  assert.equal(parseEventLine(twelve), null);
  assert.equal(parseEventLine(''), null);
  assert.equal(parseEventLine(lineOf({ event: 'PreCompact' }, '')), null);
  assert.equal(parseEventLine(lineOf({ event: '' }, '')), null);
  assert.equal(parseEventLine(lineOf({ at: 'soon' }, '')), null);
  assert.equal(parseEventLine(lineOf({ at: '' }, '')), null);
});

test('parseEventLine: a trailing carriage return is tolerated', () => {
  const got = parseEventLine(lineOf({ text: 'hi', label: 'lab' }, '\r'));
  assert.equal(got?.label, 'lab');
  assert.equal(got?.text, 'hi');
});

// ------------------------------------------------------------ the switch ---

test('parseEventLine: a 14th field from a newer hook is ignored, the 13 before it read as ever', () => {
  const narrow = parseEventLine(lineOf({ text: 'hello', tool: 'Bash' }, ''));
  assert.ok(narrow);
  assert.deepEqual(parseEventLine(`${lineOf({ text: 'hello', tool: 'Bash' }, '')}\tsomething newer`), narrow);
  assert.deepEqual(parseEventLine(`${lineOf({ text: 'hello', tool: 'Bash' }, '')}\tone\ttwo\r`), narrow);
});

// The other tests here write their lines by hand, so a change to the hook's
// layout would pass them all. This one lets the hook of this tree write a line
// and reads it with the parser. The environment is tests/events.sh's: a tmux
// shim that always fails, a socket that does not exist, a pane, and nothing of
// the developer's shell (no TA_LABEL, no CLAUDE_CONFIG_DIR).
const HOOK = path.resolve(HERE, '..', '..', '..', 'hooks', 'tmux-agent-state.sh');
const hasJq = spawnSync('jq', ['--version'], { stdio: 'ignore' }).status === 0;

test('the hook of this tree writes lines parseEventLine reads, field by field', { skip: hasJq ? false : 'the hook needs jq' }, () => {
  const root = tmpDir('agent-events-hook');
  try {
    const shim = path.join(root, 'shim');
    fs.mkdirSync(shim);
    fs.writeFileSync(path.join(shim, 'tmux'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
    const state = path.join(root, 'state');
    fs.mkdirSync(state);
    fs.writeFileSync(path.join(state, EVENTS_SWITCH), '');
    const runHook = (payload: Record<string, unknown>): void => {
      const r = spawnSync('sh', [HOOK], {
        input: JSON.stringify({ session_id: 'sid-1', cwd: '/work', transcript_path: '/work/t.jsonl', ...payload }),
        encoding: 'utf8',
        env: {
          PATH: `${shim}:${process.env['PATH'] ?? '/usr/bin:/bin'}`,
          HOME: root,
          TMUX: path.join(root, 'no-such-socket,0,0'),
          TMUX_PANE: '%7',
          TA_STATE_DIR: state,
        },
      });
      assert.equal(r.status, 0, r.stderr);
    };
    const before = Date.now();
    runHook({
      hook_event_name: 'PreToolUse',
      tool_name: 'AskUserQuestion',
      tool_input: { questions: [{ question: 'Which one?', header: 'h', options: [{ label: 'A' }, { label: 'B' }] }] },
    });
    runHook({
      hook_event_name: 'Stop',
      last_assistant_message: '\n\nThe tests pass.\nSecond line, and a third below.\n\nThird line',
    });
    // Claude Code fires this when the owner has answered the form.
    runHook({ hook_event_name: 'PostToolUse', tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'Which one?' }] } });

    const written = fs.readFileSync(path.join(state, EVENTS_FILE), 'utf8');
    const lines = written.split('\n');
    assert.equal(lines.length, 4, `three lines, each ended by a newline: ${JSON.stringify(written)}`);
    const got = lines.slice(0, 3).map((line) => {
      const event = parseEventLine(line);
      assert.ok(event, `parseEventLine refused the hook's own line: ${JSON.stringify(line)}`);
      return event;
    });
    for (const event of got) {
      // The hook stamps whole seconds.
      assert.ok(event.at >= before - 1000 && event.at <= Date.now(), `at ${event.at} is when the hook ran`);
    }
    const common = { at: 0, key: '7', sessionId: 'sid-1', agentId: '', pane: '%7', cwd: '/work', transcript: '/work/t.jsonl', configDir: '', sub: '', label: '' };
    assert.deepEqual(
      got.map((e) => ({ ...e, at: 0 })),
      [
        { ...common, event: 'PreToolUse', tool: 'AskUserQuestion', text: 'Which one?' },
        { ...common, event: 'Stop', tool: '', text: 'The tests pass.' },
        { ...common, event: 'PostToolUse', tool: 'AskUserQuestion', text: '' },
      ]
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('setEventsOn: on creates the switch and an empty events.tsv, off removes only the switch', () => {
  const { dir, file } = fixture();
  assert.equal(eventsOn(dir), false);

  setEventsOn(true, dir);
  assert.equal(eventsOn(dir), true);
  assert.ok(fs.existsSync(path.join(dir, EVENTS_SWITCH)));
  assert.equal(fs.readFileSync(file, 'utf8'), '');

  // an existing log is not emptied by a second on
  fs.writeFileSync(file, lineOf({ text: 'kept' }));
  setEventsOn(true, dir);
  assert.match(fs.readFileSync(file, 'utf8'), /kept/);

  setEventsOn(false, dir);
  assert.equal(eventsOn(dir), false);
  assert.ok(fs.existsSync(file), 'off must leave events.tsv');
  setEventsOn(false, dir); // already off: harmless
});

test('setEventsOn: creates the directory when no session has made it yet', () => {
  const { dir } = fixture();
  const fresh = path.join(dir, 'deeper', 'state');
  setEventsOn(true, fresh);
  assert.equal(eventsOn(fresh), true);
});

// ------------------------------------------------------------ followAgentEvents ---

test('follow: a line appended after the start is delivered, lines present before it are not', async () => {
  const { dir, file } = fixture();
  fs.writeFileSync(file, lineOf({ text: 'before-1' }) + lineOf({ text: 'before-2' }));
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'after-1' }));
  await run.until(1, 'the line appended after the start');
  fs.appendFileSync(file, lineOf({ text: 'after-2' }));
  await run.until(2, 'the second line appended after the start');
  assert.deepEqual(run.texts(), ['after-1', 'after-2']);
  assert.deepEqual(run.errors, []);
});

test('follow: a malformed line is skipped and the next one still arrives', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, 'not an event\n\n' + lineOf({ event: 'PreCompact' }) + lineOf({ text: 'good' }));
  await run.until(1, 'the good line after the malformed ones');
  assert.deepEqual(run.texts(), ['good']);
});

test('follow: a line written in two appends is delivered once, complete', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  const second = lineOf({ text: 'second, in two halves' });
  const cut = second.length >> 1;
  // The first append carries one whole line and the first half of the next, so
  // by the time the whole line is delivered the half has already been read.
  fs.appendFileSync(file, lineOf({ text: 'first' }) + second.slice(0, cut));
  await run.until(1, 'the whole line before the half line');
  fs.appendFileSync(file, second.slice(cut));
  await run.until(2, 'the second half of the split line');
  assert.deepEqual(run.texts(), ['first', 'second, in two halves']);
});

test('follow: a multibyte character split across two appends arrives intact', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  const text = 'Готово… ждёт ответа';
  const bytes = Buffer.from(lineOf({ text }), 'utf8');
  // Cut one byte into the ellipsis (E2 80 A6), so the first read ends mid-character.
  const cut = bytes.indexOf(Buffer.from('…', 'utf8')) + 1;
  assert.ok(cut > 0 && cut < bytes.length - 1);
  fs.appendFileSync(file, Buffer.concat([Buffer.from(lineOf({ text: 'anchor' })), bytes.subarray(0, cut)]));
  await run.until(1, 'the whole line before the split character');
  fs.appendFileSync(file, bytes.subarray(cut));
  await run.until(2, 'the line with the split character');
  assert.equal(run.got[1]?.text, text);
  assert.ok(!run.got[1]?.text.includes('�'), 'no replacement character');
});

test('follow: truncate then append delivers the new line', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'a long first line that sets the offset well past the next one'.repeat(2) }));
  await run.until(1, 'the first line');
  fs.truncateSync(file, 0);
  fs.appendFileSync(file, lineOf({ text: 'short' }));
  await run.until(2, 'the line appended after the truncation');
  assert.equal(run.got[1]?.text, 'short');
});

test('follow: a deleted file followed by an append to the recreated path delivers', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'before the delete' }));
  await run.until(1, 'the line before the delete');
  fs.unlinkSync(file);
  fs.appendFileSync(file, lineOf({ text: 'after the delete' }));
  await run.until(2, 'the line appended to the recreated path');
  fs.appendFileSync(file, lineOf({ text: 'and one more' }));
  await run.until(3, 'a second line on the recreated path');
  assert.deepEqual(run.texts(), ['before the delete', 'after the delete', 'and one more']);
  assert.deepEqual(run.errors, []);
});

test('follow: an external mv followed at once by appends to the path delivers them (the hook rotating)', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'before the mv' }));
  await run.until(1, 'the line before the mv');
  fs.renameSync(file, `${file}.1`);
  fs.appendFileSync(file, lineOf({ text: 'after the mv' }));
  await run.until(2, 'the line appended to the path after the mv');
  fs.appendFileSync(file, lineOf({ text: 'and one more' }));
  await run.until(3, 'a later line on the new file');
  assert.deepEqual(run.texts(), ['before the mv', 'after the mv', 'and one more']);
});

test('follow: an external mv that leaves no file is answered by recreating it, and the next append delivers', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'before the mv' }));
  await run.until(1, 'the line before the mv');
  fs.renameSync(file, `${file}.1`);
  await drained(() => fs.existsSync(file), { what: 'the follower to recreate events.tsv after the mv', timeoutMs: 2000, everyMs: 5 });
  fs.appendFileSync(file, lineOf({ text: 'after the mv' }));
  await run.until(2, 'the line appended to the recreated file');
  assert.deepEqual(run.texts(), ['before the mv', 'after the mv']);
});

test('follow: the follower rotates itself at rotateBytes, losing and duplicating nothing', async () => {
  const { dir, file } = fixture();
  const run = follow(dir, { rotateBytes: 200 });
  for (let i = 0; i < 50; i++) {
    fs.appendFileSync(file, lineOf({ text: `n${i}` }));
    // Let the follower see the file in batches, so the rotation lands mid-stream.
    if (i % 5 === 4) await run.until(i + 1, `line n${i} across the rotation`);
  }
  await run.until(50, 'all 50 lines');
  assert.deepEqual(
    run.texts(),
    Array.from({ length: 50 }, (_, i) => `n${i}`)
  );
  // How many times it rotated depends on how long the run took: the follower
  // rotates again once its 2 s grace is over, and a second rotation replaces
  // events.tsv.1. So the two files are read together, and what they must hold
  // between them, whatever the count, is an unbroken tail of the stream with each
  // line once.
  const rolled = `${file}.1`;
  assert.ok(fs.existsSync(rolled), 'events.tsv.1 is left behind');
  const textsIn = (f: string): string[] =>
    fs
      .readFileSync(f, 'utf8')
      .split('\n')
      .filter((l) => l !== '')
      .map((l) => parseEventLine(l)?.text ?? l);
  assert.notEqual(textsIn(rolled).length, 0, 'events.tsv.1 holds the lines that moved out of events.tsv');
  const kept = [...textsIn(rolled), ...textsIn(file)];
  const first = Number((kept[0] ?? '').slice(1));
  assert.deepEqual(
    kept,
    Array.from({ length: 50 - first }, (_, i) => `n${first + i}`),
    'events.tsv.1 and events.tsv together hold the stream from some line to the last, each line once'
  );
  assert.deepEqual(run.errors, []);
});

test('follow: a line appended to the OLD file inside the grace is still delivered', async () => {
  const { dir, file } = fixture();
  const run = follow(dir, { rotateBytes: 200 });
  // A hook that opened the path just before the rename keeps this descriptor.
  const hook = fs.openSync(file, 'a');
  cleanup(() => fs.closeSync(hook));
  for (let i = 0; i < 5; i++) fs.appendFileSync(file, lineOf({ text: `fill${i}` }));
  await run.until(5, 'the lines that fill the file past rotateBytes');
  await drained(() => fs.existsSync(`${file}.1`), { what: 'the follower to rotate to events.tsv.1', timeoutMs: 2000, everyMs: 5 });

  // The late write comes straight after the rotation was seen, with no wait in
  // between: the grace is 2 s and a slow machine must not be able to spend it.
  fs.writeSync(hook, lineOf({ text: 'late, on the old file' }));
  fs.appendFileSync(file, lineOf({ text: 'on the new file' }));
  await run.until(6, 'a line on the fresh events.tsv');
  assert.equal(run.got[5]?.text, 'on the new file');
  // The old file is read once more when the grace ends, 2 s after the rotation.
  await run.until(7, 'the late line written to the old file inside the grace', 4000);
  assert.equal(run.got[6]?.text, 'late, on the old file');
  assert.deepEqual(run.errors, []);
});

test('follow: nothing is delivered after close(), and a second close() is harmless', async () => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'while open' }));
  await run.until(1, 'the line while open');
  run.follower.close();
  run.follower.close();

  const witness = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'after close' }));
  await witness.until(1, 'the witness to see the line appended after close');
  assert.deepEqual(run.texts(), ['while open']);
  assert.deepEqual(run.errors, []);
});

test('follow: closing from inside the callback stops the lines that came with it', async () => {
  const { dir, file } = fixture();
  const run = follow(dir, { onEvent: () => run.follower.close() });
  fs.appendFileSync(file, lineOf({ text: 'one' }) + lineOf({ text: 'two' }) + lineOf({ text: 'three' }));
  await run.until(1, 'the first line of a batch');
  const witness = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'witnessed' }));
  await witness.until(1, 'the witness to see a later line');
  assert.deepEqual(run.texts(), ['one']);
});

test('follow: an exception thrown by the consumer goes to onError and the follower keeps following', async () => {
  const { dir, file } = fixture();
  const run = follow(dir, {
    onEvent: (e) => {
      if (e.text === 'boom') throw new Error('consumer failed');
    },
  });
  fs.appendFileSync(file, lineOf({ text: 'boom' }) + lineOf({ text: 'fine' }));
  await run.until(2, 'the line after the one the consumer threw on');
  assert.deepEqual(run.texts(), ['boom', 'fine']);
  assert.deepEqual(
    run.errors.map((e) => e.message),
    ['consumer failed']
  );
});

test('follow: a missing directory is created, and the file in it', async () => {
  const { dir } = fixture();
  const fresh = path.join(dir, 'not', 'yet', 'there');
  const run = follow(fresh);
  const file = path.join(fresh, EVENTS_FILE);
  assert.ok(fs.existsSync(file));
  fs.appendFileSync(file, lineOf({ text: 'first on a fresh machine' }));
  await run.until(1, 'the first line in the created directory');
  assert.equal(run.got[0]?.text, 'first on a fresh machine');
});

test('follow: close() during the grace leaves no timer and no handle holding the process', async () => {
  const { dir, file } = fixture();
  // A child process, because the test runner has timers of its own. It rotates
  // the file, checks that the grace timer exists, closes, checks that nothing is
  // left, and reports how long it took to exit once the loop was empty.
  const script = path.join(path.dirname(dir), 'child.mjs');
  fs.writeFileSync(
    script,
    `
import fs from 'node:fs';
const { followAgentEvents } = await import(${JSON.stringify(pathToFileURL(SRC).href)});
const file = ${JSON.stringify(file)};
const lines = Array.from({ length: 5 }, (_, i) => ['1760000000', 'Stop', '12', 's', '', '%12', '/some/working/directory', '/t', '', '', '', 'line-' + i, ''].join('\\t') + '\\n');
let seen = 0;
let closedAt = 0;
let deaths = 0;
const handles = () => process.getActiveResourcesInfo();
const f = followAgentEvents(() => {
  if (++seen < lines.length) return;
  setImmediate(() => {
    const rotated = fs.existsSync(file + '.1');
    const pendingBefore = handles().includes('Timeout');
    f.close();
    f.close();
    closedAt = Date.now();
    // A closed watcher leaves the list on the next turn of the loop, not at once.
    setImmediate(() => {
      const left = handles().filter((h) => h === 'Timeout' || h === 'FSEventWrap');
      process.on('exit', () => {
        console.log(JSON.stringify({ rotated, pendingBefore, deaths, left, exitedAfterMs: Date.now() - closedAt }));
      });
    });
  });
}, { dir: ${JSON.stringify(dir)}, rotateBytes: 200, onDead: () => deaths++ });
fs.appendFileSync(file, lines.join(''));
`
  );
  const out = await runChild(script);
  assert.equal(out.code, 0, out.stderr);
  const report = ChildReport.parse(JSON.parse(out.stdout.trim()));
  assert.equal(report.deaths, 0, 'a follower that was closed is not a dead one');
  assert.equal(report.rotated, true, 'the child must have rotated, or the grace timer was never armed');
  assert.equal(report.pendingBefore, true, 'the grace timer exists before close()');
  assert.deepEqual(report.left, [], 'no timer or watcher after close()');
  assert.ok(report.exitedAfterMs < 1000, `the process lingered ${report.exitedAfterMs} ms after close(); the 2 s grace is still pending`);
});

// ------------------------------------------------------------ a follower that dies ---
//
// fs.watch is the one thing a follower cannot do without, and the tests below
// break it the two ways it breaks: the path is watched again after a reopen or a
// rotation and fs.watch throws (EMFILE, or the path is gone again), or the
// watcher it has emits 'error'. The first is made by replacing fs.watch for one
// call with t.mock.method, which puts it back when the test ends; the second by
// emitting the event on the FSWatcher the follower opened. Neither needs a seam
// in the source: it calls fs.watch through the module object.

const EMFILE = (): Error => Object.assign(new Error('EMFILE: too many open files, watch'), { code: 'EMFILE' });

test('follow: when watching again fails the follower closes itself, calls onDead once with the error, and delivers nothing more', async (t) => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'while it could hear' }));
  await run.until(1, 'the line before the failure');

  const watch = t.mock.method(fs, 'watch', () => {
    throw EMFILE();
  });
  // What the hook's rotation does: the path goes away, the follower reopens it
  // and has to watch the new file.
  fs.renameSync(file, `${file}.1`);
  await drained(() => run.dead.length > 0, { what: 'onDead after the watch could not be set up again', timeoutMs: 2000, everyMs: 5 });
  watch.mock.restore();
  assert.equal(watch.mock.callCount(), 1, 'one attempt to watch again, and no retry of its own');
  assert.deepEqual(
    run.dead.map((e) => e.message),
    ['EMFILE: too many open files, watch']
  );
  assert.deepEqual(run.errors, [], 'a death goes to onDead, not to onError as well');

  // Closed means closed: a line in the file the follower had just reopened is not
  // delivered, and nothing calls onDead a second time. The witness is a follower
  // that has seen a later line, so the dead one has had its chance.
  const witness = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'after the death' }));
  await witness.until(1, 'the witness to see the line appended after the death');
  run.follower.close();
  assert.deepEqual(run.texts(), ['while it could hear']);
  assert.equal(run.dead.length, 1, 'close() after the death is not a second death');
});

/**
 * A child that rotates its file with a follower whose `breakIt` makes one call of
 * fs go wrong on the second use, so the death comes in the middle of rotate().
 * It prints what it still holds once it has had two turns of the loop to let go.
 */
async function rotatingChildDies(dir: string, file: string, breakIt: string): Promise<z.infer<typeof ChildReport>> {
  const script = path.join(path.dirname(dir), 'death-child.mjs');
  fs.writeFileSync(
    script,
    `
import fs from 'node:fs';
const { followAgentEvents } = await import(${JSON.stringify(pathToFileURL(SRC).href)});
const file = ${JSON.stringify(file)};
const lines = Array.from({ length: 5 }, (_, i) => ['1760000000', 'Stop', '12', 's', '', '%12', '/some/working/directory', '/t', '', '', '', 'line-' + i, ''].join('\\t') + '\\n');
${breakIt}
let deaths = 0;
let diedAt = 0;
followAgentEvents(() => {}, {
  dir: ${JSON.stringify(dir)},
  rotateBytes: 200,
  onDead: () => {
    deaths++;
    diedAt = Date.now();
    // A closed watcher leaves the list on the next turn of the loop, not at once.
    setImmediate(() => setImmediate(() => {
      const rotated = fs.existsSync(file + '.1');
      const left = process.getActiveResourcesInfo().filter((h) => h === 'Timeout' || h === 'FSEventWrap');
      process.on('exit', () => {
        console.log(JSON.stringify({ rotated, deaths, left, exitedAfterMs: Date.now() - diedAt }));
      });
    }));
  },
});
fs.appendFileSync(file, lines.join(''));
`
  );
  const out = await runChild(script);
  assert.equal(out.code, 0, out.stderr);
  return ChildReport.parse(JSON.parse(out.stdout.trim()));
}

test('follow: a watching failure during the rotation grace closes the follower and leaves no timer in a child process', async () => {
  const { dir, file } = fixture();
  // The second fs.watch is the one rotate() makes for the fresh file, so the death
  // comes while the 2 s grace timer is armed. It must clear that timer, or the
  // process lingers for 2 s.
  const report = await rotatingChildDies(
    dir,
    file,
    `const realWatch = fs.watch;
let watches = 0;
fs.watch = (...args) => {
  if (++watches > 1) throw new Error('EMFILE: too many open files, watch');
  return realWatch(...args);
};`
  );
  assert.equal(report.rotated, true, 'the child must have rotated, or the grace timer was never armed');
  assert.equal(report.deaths, 1);
  assert.deepEqual(report.left, [], 'no timer or watcher after the death');
  assert.ok(report.exitedAfterMs < 1000, `the process lingered ${report.exitedAfterMs} ms after the death; the 2 s grace is still pending`);
});

test('follow: a failed open of the fresh file after a rotation is a death, not a follower parked on the renamed file', async () => {
  const { dir, file } = fixture();
  // Only the open of the events file after the rename fails, which is rotate()'s:
  // the watcher is still on the renamed file and nothing would wake the follower
  // again. Matching the path and the rename keeps this independent of whether
  // appendFileSync goes through fs.openSync.
  const report = await rotatingChildDies(
    dir,
    file,
    `const realOpen = fs.openSync;
fs.openSync = (...args) => {
  if (args[0] === file && fs.existsSync(file + '.1')) throw new Error('EMFILE: too many open files, open');
  return realOpen(...args);
};`
  );
  assert.equal(report.rotated, true, 'the child must have renamed the file, or the open that fails was never reached');
  assert.equal(report.deaths, 1);
  assert.deepEqual(report.left, [], 'the watcher on the renamed file is closed with the follower');
  assert.ok(report.exitedAfterMs < 1000, `the process lingered ${report.exitedAfterMs} ms after the death`);
});

test('follow: a failed open when the path was replaced is a death, reported once through onDead', async (t) => {
  const { dir, file } = fixture();
  const run = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'while it could hear' }));
  await run.until(1, 'the line before the failure');

  const open = t.mock.method(
    fs,
    'openSync',
    () => {
      throw Object.assign(new Error('EACCES: permission denied, open'), { code: 'EACCES' });
    },
    { times: 1 }
  );
  fs.renameSync(file, `${file}.1`);
  await drained(() => run.dead.length > 0, { what: 'onDead after the path could not be opened again', timeoutMs: 2000, everyMs: 5 });
  assert.equal(open.mock.callCount(), 1, 'one attempt to open the path again, and no retry of its own');
  assert.deepEqual(
    run.dead.map((e) => e.message),
    ['EACCES: permission denied, open']
  );
  assert.deepEqual(run.errors, [], 'a death goes to onDead, not to onError as well');

  const witness = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'after the death' }));
  await witness.until(1, 'the witness to see the line appended after the death');
  run.follower.close();
  assert.deepEqual(run.texts(), ['while it could hear']);
  assert.equal(run.dead.length, 1, 'close() after the death is not a second death');
});

test("follow: an 'error' from the watcher is a death too, and a second one is not", (t) => {
  const { dir } = fixture();
  const { started: run, watcher } = withWatcher(t, () => follow(dir));
  watcher.emit('error', new Error('watch failed'));
  watcher.emit('error', new Error('watch failed again'));
  assert.deepEqual(
    run.dead.map((e) => e.message),
    ['watch failed']
  );
  assert.deepEqual(run.errors, []);
});

test('follow: without onDead a death goes to onError, so it is never silent', (t) => {
  const { dir } = fixture();
  const errors: Error[] = [];
  const { started: follower, watcher } = withWatcher(t, () => followAgentEvents(() => {}, { dir, onError: (e) => errors.push(e) }));
  cleanup(() => follower.close());
  watcher.emit('error', new Error('watch failed'));
  assert.deepEqual(
    errors.map((e) => e.message),
    ['watch failed']
  );
});

test('follow: an explicit close() is not a death, even when the watcher complains afterwards', (t) => {
  const { dir } = fixture();
  const { started: run, watcher } = withWatcher(t, () => follow(dir));
  run.follower.close();
  watcher.emit('error', new Error('too late'));
  assert.deepEqual(run.dead, []);
  assert.deepEqual(run.errors, []);
});

test('follow: an onDead that throws goes to onError instead of escaping the watcher event', (t) => {
  const { dir } = fixture();
  const { started: run, watcher } = withWatcher(t, () =>
    follow(dir, {
      onDead: () => {
        throw new Error('the caller failed');
      },
    })
  );
  assert.doesNotThrow(() => watcher.emit('error', new Error('watch failed')));
  assert.deepEqual(
    run.errors.map((e) => e.message),
    ['the caller failed']
  );
});

// ------------------------------------------------------------ createAgentFeed ---

test('createAgentFeed: the first follow creates the switch, the last close removes it', async () => {
  const { dir, file } = fixture();
  const feed = createAgentFeed(dir);
  assert.equal(feed.dir, dir);
  assert.equal(eventsOn(dir), false);

  const a = feed.follow(() => {});
  cleanup(() => a.close());
  assert.equal(eventsOn(dir), true, 'on once the first follower started');
  const b = feed.follow(() => {});
  cleanup(() => b.close());
  assert.equal(eventsOn(dir), true);

  a.close();
  a.close(); // a second close of the same follower must not count twice
  assert.equal(eventsOn(dir), true, 'still on while one follower is open');

  fs.appendFileSync(file, lineOf({ text: 'through the feed' }));
  const witness = follow(dir);
  fs.appendFileSync(file, lineOf({ text: 'witnessed' }));
  await witness.until(1, 'the witness to see a line after the first follower closed');

  b.close();
  assert.equal(eventsOn(dir), false, 'off once the last follower closed');
  assert.ok(fs.existsSync(file), 'the log stays');
});

test('createAgentFeed: followers of two feeds on one directory count together', () => {
  const { dir } = fixture();
  const one = createAgentFeed(dir).follow(() => {});
  cleanup(() => one.close());
  const two = createAgentFeed(dir).follow(() => {});
  cleanup(() => two.close());
  one.close();
  assert.equal(eventsOn(dir), true, 'the other feed still has a follower');
  two.close();
  assert.equal(eventsOn(dir), false);
});

test('createAgentFeed: a follower that dies is counted out like a close, the switch goes with the last one, and onDead comes after', (t) => {
  const { dir } = fixture();
  const feed = createAgentFeed(dir);
  const deaths: Array<{ message: string; switchOn: boolean }> = [];
  const dying = withWatcher(t, () =>
    feed.follow(
      () => {},
      undefined,
      (e) => deaths.push({ message: e.message, switchOn: eventsOn(dir) })
    )
  );
  cleanup(() => dying.started.close());
  const other = feed.follow(() => {});
  cleanup(() => other.close());

  dying.watcher.emit('error', new Error('watch failed'));
  assert.deepEqual(deaths, [{ message: 'watch failed', switchOn: true }], 'the other follower is still open, so the switch is still on when onDead runs');
  dying.started.close();
  assert.equal(eventsOn(dir), true, 'closing a follower that already died does not count it out twice');
  other.close();
  assert.equal(eventsOn(dir), false, 'off once the last follower is gone');
});

test('createAgentFeed: the last follower dying removes the switch before onDead runs', (t) => {
  const { dir } = fixture();
  const switchOn: boolean[] = [];
  const { watcher } = withWatcher(t, () =>
    createAgentFeed(dir).follow(
      () => {},
      undefined,
      () => switchOn.push(eventsOn(dir))
    )
  );
  assert.equal(eventsOn(dir), true);
  watcher.emit('error', new Error('watch failed'));
  assert.deepEqual(switchOn, [false], 'the hook stops writing for a follower nobody runs, and the caller may follow again from onDead');
  assert.equal(eventsOn(dir), false);
});

test('createAgentFeed: without onDead a death goes to onError, after the bookkeeping', (t) => {
  const { dir } = fixture();
  const seen: Array<{ message: string; switchOn: boolean }> = [];
  const { watcher } = withWatcher(t, () =>
    createAgentFeed(dir).follow(
      () => {},
      (e) => seen.push({ message: e.message, switchOn: eventsOn(dir) })
    )
  );
  watcher.emit('error', new Error('watch failed'));
  assert.deepEqual(seen, [{ message: 'watch failed', switchOn: false }]);
});

test('createAgentFeed: a switch that cannot be removed is reported to onError and close() still does not throw', () => {
  const { dir } = fixture();
  const errors: Error[] = [];
  const f = createAgentFeed(dir).follow(() => {}, (e) => errors.push(e));
  cleanup(() => f.close());
  // rm of a directory without `recursive` fails (EISDIR); EACCES and EPERM end the same way.
  const sw = path.join(dir, EVENTS_SWITCH);
  fs.rmSync(sw);
  fs.mkdirSync(sw);
  assert.doesNotThrow(() => f.close());
  assert.equal(errors.length, 1);
  assert.match(errors[0]?.message ?? '', /EISDIR|directory/i);
  f.close();
  assert.equal(errors.length, 1, 'a second close() reports nothing more');
});

test('createAgentFeed: spellings of one directory, a trailing slash and a symlink, share one count', () => {
  const { dir } = fixture();
  const link = `${dir}-link`;
  fs.symlinkSync(dir, link);
  const plain = createAgentFeed(dir).follow(() => {});
  cleanup(() => plain.close());
  const slash = createAgentFeed(`${dir}/`).follow(() => {});
  cleanup(() => slash.close());
  const linked = createAgentFeed(link).follow(() => {});
  cleanup(() => linked.close());

  plain.close();
  assert.equal(eventsOn(dir), true, 'two followers of the same directory are still open');
  slash.close();
  assert.equal(eventsOn(dir), true, 'the one through the symlink is still open');
  linked.close();
  assert.equal(eventsOn(dir), false);
});

test('createAgentFeed: follow delivers what the hook appends, and states() is readAgentState(dir)', async () => {
  const { dir, file } = fixture();
  writeStateRow(dir, { key: '12', at: 1_760_000_000, state: 'working', sessionId: 'sess-a', detail: 'Bash ls', configDir: '' });
  writeStateRow(dir, { key: 's-sess-b', at: 1_760_000_100, state: 'blocked', sessionId: 'sess-b', detail: 'needs you', configDir: '/x' });
  const feed = createAgentFeed(dir);
  assert.deepEqual(feed.states(), readAgentState(dir));
  assert.equal(feed.states().length, 2);

  const got: AgentEvent[] = [];
  const f = feed.follow((e) => got.push(e));
  cleanup(() => f.close());
  fs.appendFileSync(file, lineOf({ text: 'via the feed', at: 1_760_000_200 }));
  await drained(() => got.length >= 1, { what: 'the feed to deliver the appended line', timeoutMs: 2000, everyMs: 5 });
  assert.equal(got[0]?.at, 1_760_000_200_000);
});

test('constants: the rotation threshold is 1 MiB', () => {
  assert.equal(EVENTS_ROTATE_BYTES, 1_048_576);
});

after(() => {
  while (cleanups.length > 0) cleanups.pop()?.();
});
