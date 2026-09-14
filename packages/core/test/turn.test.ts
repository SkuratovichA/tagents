// The turn lifecycle, ported case for case from orchestrator/test/turn.test.mjs
// onto ClaudeHeadlessDriver.
//
// Pins the 10.09 incident: a turn that finished its work and printed its result
// was killed by the runner's own timeout, read as a failure and re-run from
// scratch, so the owner got the whole job twice. Everything runs against a fake
// `claude` (a real executable under $TMPDIR) — the process, the pipe and the
// kill are real, because that is where the bug lived.
//
// The dedup/retry cases of the original stay in the orchestrator: claims and
// retry policy are its business, not this package's.
//
// Time is the one thing here that is not real. A turn used to be given a few
// hundred real milliseconds for a real node process to start, print and be read
// before the killer fired, and on a loaded box it lost that race (LEARNING.md,
// 14.09.2026) — a budget nobody can size, because it is a bet on the machine.
// So every turn runs on the fake clock from helpers.ts: a case that needs a
// timer to fire waits for the child's own event first (`await t.seen('text')`)
// and only then advances the clock, and a case that needs no timer to fire
// never moves it at all. The one exception is the silent timeout, which has no
// output to race and keeps the real clock on purpose.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { ClaudeHeadlessDriver } from '../src/claude-driver.ts';
import type { PromptOptions, SessionSpec, StreamEvent } from '../src/driver.ts';
import { fakeClaude, tmpDir, type FakeScript } from '../src/testkit.ts';
import { evidence, formatAttemptError, succeeded, TurnOutcomeSchema, type TurnOutcome } from '../src/turn-outcome.ts';
import type { TurnClock } from '../src/turn-scope.ts';
import { eventWaiter, FakeClock } from './helpers.ts';

let tmp: string;
before(() => {
  tmp = tmpDir('turn-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const lines: string[] = [];
const driver = (clock?: TurnClock): ClaudeHeadlessDriver =>
  new ClaudeHeadlessDriver({
    stateDir: path.join(tmp, 'state'),
    log: (...p) => lines.push(p.join(' ')),
    ...(clock ? { clock } : {}),
  });

/** The same turn with its timers on a clock the case moves itself. */
interface ClockTurn {
  readonly clock: FakeClock;
  readonly outcome: Promise<TurnOutcome>;
  /** Resolves on the first event of that kind. */
  readonly seen: (kind: StreamEvent['kind']) => Promise<void>;
}

/**
 * A turn whose TIME is fake and whose everything else is real: the process, the
 * pipe and the kill are the production ones, only `after()` is the test's. The
 * open() is awaited on purpose — a turn's timers exist only once prompt() has
 * been called, and a case that advanced the clock before that would advance
 * nothing and then wait forever for a killer scheduled after the fact.
 */
async function onClock(script: FakeScript, o: Partial<PromptOptions> = {}): Promise<ClockTurn> {
  const fake = fakeClaude(script, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const clock = new FakeClock();
  const events = eventWaiter();
  const d = driver(clock);
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin: fake.bin });
  const outcome = d
    .prompt(ref, 'do the thing', { timeoutMs: 1500, warnBeforeMs: 0, exitGraceMs: 300, onEvent: events.onEvent, ...o })
    .then((out) => {
      // Every outcome must satisfy the published schema, not just the type.
      TurnOutcomeSchema.parse(out);
      return out;
    });
  return { clock, outcome, seen: events.seen };
}

/**
 * One turn against a scripted fake that runs to its own end: the clock is the
 * fake one and nobody moves it, so no driver timer can fire while a real node
 * process is starting up. A case that NEEDS a timer to fire drives the clock
 * itself through onClock().
 */
async function run(script: FakeScript, o: Partial<PromptOptions> = {}): Promise<TurnOutcome> {
  return (await onClock(script, o)).outcome;
}

const RESULT = { text: 'Отправил в «dev»: сводку (msg 470)' };

test('a clean turn is ok', async () => {
  const o = await run({ tools: ['Bash'], text: 'hi', result: RESULT });
  assert.equal(o.kind, 'ok');
  assert.equal(succeeded(o), true);
  assert.equal(formatAttemptError(o), null);
  if (o.kind !== 'ok') return;
  assert.equal(o.sessionId, 'sess-1');
  assert.equal(o.toolUses, 1);
  assert.equal(o.text, 'hi');
  assert.equal(o.costUsd, 0.1);
  assert.equal(o.numTurns, 3);
});

test('a turn killed after printing its result is a success, not a failure', async () => {
  lines.length = 0;
  const t = await onClock({ tools: ['Bash'], result: RESULT, hangAfterResult: true });
  await t.seen('result');
  // What 'did not wait for the full timeout' actually means: the killer is gone
  // and the only timer left is the exit grace, which is what fires below.
  assert.equal(t.clock.pending, 1, 'the killer went with the result');
  t.clock.advance(300);
  const o = await t.outcome;
  assert.equal(o.kind, 'killed-after-result', 'result received => the turn succeeded');
  assert.equal(succeeded(o), true);
  assert.equal(formatAttemptError(o), null, 'a finished turn has no error line');
  assert.match(lines.join('\n'), /printed its result but did not exit/);
  if (o.kind !== 'killed-after-result') return;
  assert.equal(o.toolUses, 1);
  assert.notEqual(o.code, 0);
});

test('a turn that timed out after tool calls is a timeout, with the tools counted', async () => {
  const t = await onClock({ tools: ['Bash'], result: null, hang: true }, { timeoutMs: 400 });
  await t.seen('tool_use');
  t.clock.advance(400);
  const o = await t.outcome;
  assert.equal(o.kind, 'timeout');
  if (o.kind !== 'timeout') return;
  assert.equal(o.toolUses, 1);
  assert.equal(o.limitMs, 400);
  assert.match(String(formatAttemptError(o)), /^exit=SIGKILL \(timeout 400ms, 1 tool call\(s\)\) /);
});

test('a silent timeout produced nothing at all', async () => {
  // The one turn left on the REAL clock. A fake that prints nothing races
  // nothing, so the 300 ms are honest here — and something has to prove that
  // the driver's default clock kills a turn for real, not just a test's.
  const fake = fakeClaude({ silent: true }, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const spec: SessionSpec = { kind: 'claude', cwd: tmp, skipPermissions: false, bin: fake.bin };
  const d = driver();
  const ref = await d.open(spec);
  const o = await d.prompt(ref, 'do the thing', { timeoutMs: 300, warnBeforeMs: 0, exitGraceMs: 300 });
  TurnOutcomeSchema.parse(o);
  assert.equal(o.kind, 'timeout');
  if (o.kind !== 'timeout') return;
  assert.equal(o.toolUses, 0);
  assert.equal(o.sessionId, null);
});

test('a failed resume is an exit with the stderr as the detail', async () => {
  const o = await run({
    result: null,
    stderr: 'No conversation found with session ID: abc\n',
    exitCode: 1,
  });
  assert.equal(o.kind, 'exited');
  assert.equal(succeeded(o), false);
  if (o.kind !== 'exited') return;
  assert.equal(o.code, 1);
  assert.equal(o.toolUses, 0);
  assert.match(o.detail, /No conversation found/);
  assert.match(String(formatAttemptError(o)), /^exit=1 No conversation found/);
});

test('a result with is_error=true is an exit carrying the result text', async () => {
  const o = await run({ result: { isError: true, text: 'the model refused' }, exitCode: 1 });
  assert.equal(o.kind, 'exited');
  if (o.kind !== 'exited') return;
  assert.equal(o.detail, 'the model refused');
  assert.equal(o.sessionId, 'sess-1');
});

test('a missing binary is a spawn failure, not a crash', async () => {
  const d = driver();
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin: path.join(tmp, 'no-such-claude') });
  const o = await d.prompt(ref, 'hi', { timeoutMs: 1000 });
  assert.equal(o.kind, 'spawn-failed');
  assert.match(String(formatAttemptError(o)), /^exit=null spawn: /);
  assert.match(String(formatAttemptError(o)), /ENOENT/);
});

test('the caller is warned before the kill, and not at all for a turn that finishes', async () => {
  const warns: Array<{ elapsedMs: number; leftMs: number }> = [];
  const t = await onClock({ tools: ['Bash'], result: null, hang: true }, {
    timeoutMs: 700,
    warnBeforeMs: 300,
    onWarn: (w) => warns.push(w),
  });
  await t.seen('tool_use');
  const warnAt = 700 - 300;
  t.clock.advance(warnAt - 1);
  assert.deepEqual(warns, [], 'not a millisecond early');
  t.clock.advance(1);
  assert.deepEqual(warns, [{ elapsedMs: warnAt, leftMs: 300 }]);
  t.clock.advance(300);
  const o = await t.outcome;
  assert.equal(o.kind, 'timeout');

  // A turn that finishes is not warned about, and leaves behind no timer that
  // could warn about it later either.
  const quiet: Array<{ elapsedMs: number; leftMs: number }> = [];
  const done = await onClock({ result: RESULT }, { timeoutMs: 5000, warnBeforeMs: 4000, onWarn: (x) => quiet.push(x) });
  assert.equal((await done.outcome).kind, 'ok');
  done.clock.advance(5000);
  assert.deepEqual(quiet, []);
  assert.equal(done.clock.pending, 0, 'the turn took its timers with it');
});

test('a turn that timed out after saying something records that it spoke', async () => {
  const t = await onClock({ text: 'starting on it', result: null, hang: true }, { timeoutMs: 400 });
  await t.seen('text');
  t.clock.advance(400);
  const o = await t.outcome;
  assert.equal(o.kind, 'timeout');
  if (o.kind !== 'timeout') return;
  assert.equal(o.sawText, true, 'the assistant text arrived before the killer did');
  assert.equal(o.sawResult, false, 'a timeout is by definition a turn with no result');
  assert.deepEqual(evidence(o), { toolUses: 0, sawText: true, sawResult: false });
});

test('an is_error result is evidence: the turn ran, it just ended badly', async () => {
  const o = await run({ text: 'let me look', result: { isError: true, text: 'the model refused' }, exitCode: 1 });
  assert.equal(o.kind, 'exited');
  if (o.kind !== 'exited') return;
  assert.equal(o.sawResult, true, 'is_error=true is still a result event');
  assert.equal(o.sawText, true);
  // Re-running this one would repeat whatever it already did.
  assert.deepEqual(evidence(o), { toolUses: 0, sawText: true, sawResult: true });
});

test('a crash before anything happened carries no evidence at all', async () => {
  const o = await run({ result: null, stderr: 'boom\n', exitCode: 1 });
  assert.equal(o.kind, 'exited');
  if (o.kind !== 'exited') return;
  assert.equal(o.sawText, false);
  assert.equal(o.sawResult, false);
  assert.deepEqual(evidence(o), { toolUses: 0, sawText: false, sawResult: false });
});

test('a per-turn log takes the diagnostics, and the driver-wide one stays quiet', async () => {
  lines.length = 0;
  const mine: string[] = [];
  const t = await onClock({ tools: ['Bash'], result: RESULT, hangAfterResult: true }, { log: (l) => mine.push(l) });
  await t.seen('result');
  t.clock.advance(300); // the exit grace
  const o = await t.outcome;
  assert.equal(o.kind, 'killed-after-result');
  assert.match(mine.join('\n'), /printed its result but did not exit/);
  assert.deepEqual(lines, [], 'the turn had its own sink: nothing reached the driver-wide one');

  // And a turn with no sink of its own still reaches the driver-wide log.
  lines.length = 0;
  const bare = await onClock({ result: null, hang: true }, { timeoutMs: 300 });
  bare.clock.advance(300);
  await bare.outcome;
  assert.match(lines.join('\n'), /timed out after/);
});

test('one prompt spawns the child exactly once', async () => {
  const counts = path.join(tmp, 'spawns.txt');
  fs.writeFileSync(counts, '');
  const t = await onClock({ tools: ['Bash'], result: RESULT, hangAfterResult: true, countFile: counts });
  await t.seen('result');
  t.clock.advance(300); // the exit grace
  const o = await t.outcome;
  assert.equal(o.kind, 'killed-after-result');
  assert.equal(fs.readFileSync(counts, 'utf8'), 'run\n', 'a driver never re-runs a turn on its own');
});

test('events reach the caller while the turn runs', async () => {
  const seen: StreamEvent[] = [];
  const o = await run(
    { tools: [{ name: 'Bash', input: { command: 'ls' } }], text: 'working on it', result: RESULT },
    { onEvent: (e) => seen.push(e) }
  );
  assert.equal(o.kind, 'ok');
  assert.deepEqual(
    seen.map((e) => e.kind),
    ['other', 'tool_use', 'text', 'result']
  );
  assert.deepEqual(seen[1], { kind: 'tool_use', name: 'Bash', input: { command: 'ls' } });
});

test('abort kills the turn in flight', async () => {
  const fake = fakeClaude({ silent: true }, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const d = driver();
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin: fake.bin });
  const running = d.prompt(ref, 'go', { timeoutMs: 30_000 });
  setTimeout(() => void d.abort(ref), 150);
  const o = await running;
  assert.equal(o.kind, 'exited');
  if (o.kind !== 'exited') return;
  assert.equal(o.signal, 'SIGKILL');
});

test('an AbortSignal kills the turn the same way', async () => {
  const fake = fakeClaude({ silent: true }, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const d = driver();
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin: fake.bin });
  const ac = new AbortController();
  const running = d.prompt(ref, 'go', { timeoutMs: 30_000, signal: ac.signal });
  setTimeout(() => ac.abort(), 150);
  const o = await running;
  assert.equal(o.kind, 'exited');
});
