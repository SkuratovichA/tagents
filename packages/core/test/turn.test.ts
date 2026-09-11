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
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { ClaudeHeadlessDriver } from '../src/claude-driver.ts';
import type { PromptOptions, SessionSpec, StreamEvent } from '../src/driver.ts';
import { fakeClaude, tmpDir, type FakeScript } from '../src/testkit.ts';
import { formatAttemptError, succeeded, TurnOutcomeSchema, type TurnOutcome } from '../src/turn-outcome.ts';

let tmp: string;
before(() => {
  tmp = tmpDir('turn-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const lines: string[] = [];
const driver = (): ClaudeHeadlessDriver =>
  new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state'), log: (...p) => lines.push(p.join(' ')) });

/** One turn against a scripted fake. Short timeouts: these are unit tests. */
async function run(script: FakeScript, o: Partial<PromptOptions> = {}): Promise<TurnOutcome> {
  const fake = fakeClaude(script, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const spec: SessionSpec = { kind: 'claude', cwd: tmp, skipPermissions: false, bin: fake.bin };
  const d = driver();
  const ref = await d.open(spec);
  const outcome = await d.prompt(ref, 'do the thing', { timeoutMs: 1500, warnBeforeMs: 0, exitGraceMs: 300, ...o });
  // Every outcome must satisfy the published schema, not just the type.
  TurnOutcomeSchema.parse(outcome);
  return outcome;
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
  const t0 = Date.now();
  const o = await run({ tools: ['Bash'], result: RESULT, hangAfterResult: true });
  assert.equal(o.kind, 'killed-after-result', 'result received => the turn succeeded');
  assert.equal(succeeded(o), true);
  assert.equal(formatAttemptError(o), null, 'a finished turn has no error line');
  assert.ok(Date.now() - t0 < 1500, 'did not wait for the full timeout');
  assert.match(lines.join('\n'), /printed its result but did not exit/);
  if (o.kind !== 'killed-after-result') return;
  assert.equal(o.toolUses, 1);
  assert.notEqual(o.code, 0);
});

test('a turn that timed out after tool calls is a timeout, with the tools counted', async () => {
  const o = await run({ tools: ['Bash'], result: null, hang: true }, { timeoutMs: 400 });
  assert.equal(o.kind, 'timeout');
  if (o.kind !== 'timeout') return;
  assert.equal(o.toolUses, 1);
  assert.equal(o.limitMs, 400);
  assert.match(String(formatAttemptError(o)), /^exit=SIGKILL \(timeout 400ms, 1 tool call\(s\)\) /);
});

test('a silent timeout produced nothing at all', async () => {
  const o = await run({ silent: true }, { timeoutMs: 300 });
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
  const o = await run({ tools: ['Bash'], result: null, hang: true }, {
    timeoutMs: 700,
    warnBeforeMs: 300,
    onWarn: (w) => warns.push(w),
  });
  assert.equal(o.kind, 'timeout');
  assert.equal(warns.length, 1);
  const w = warns[0];
  assert.ok(w && w.elapsedMs >= 350 && w.elapsedMs < 700, `warned at ${w?.elapsedMs}ms`);
  assert.equal(w?.leftMs, 300);

  const quiet: Array<{ elapsedMs: number; leftMs: number }> = [];
  await run({ result: RESULT }, { timeoutMs: 5000, warnBeforeMs: 4000, onWarn: (x) => quiet.push(x) });
  assert.equal(quiet.length, 0);
});

test('one prompt spawns the child exactly once', async () => {
  const counts = path.join(tmp, 'spawns.txt');
  fs.writeFileSync(counts, '');
  const o = await run({ tools: ['Bash'], result: RESULT, hangAfterResult: true, countFile: counts });
  assert.equal(o.kind, 'killed-after-result');
  assert.equal(fs.readFileSync(counts, 'utf8'), 'run\n', 'a driver never re-runs a turn on its own');
});

test('events reach the caller while the turn runs', async () => {
  const seen: StreamEvent[] = [];
  const fake = fakeClaude(
    { tools: [{ name: 'Bash', input: { command: 'ls' } }], text: 'working on it', result: RESULT },
    fs.mkdtempSync(path.join(tmp, 'fake-'))
  );
  const d = driver();
  const ref = await d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin: fake.bin });
  const o = await d.prompt(ref, 'go', { timeoutMs: 2000, onEvent: (e) => seen.push(e) });
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
