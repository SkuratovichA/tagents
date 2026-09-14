// The turn lifecycle on a fake clock: the production timeouts (50 minutes, a
// 60-second grace) proven to the millisecond without waiting for any of them.
//
// turn.test.ts pins the behaviour with real timers and short limits; this file
// pins the timing itself and what is left behind. The child is still a real
// process — only time is fake, so a kill here is a real SIGKILL.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import {
  ClaudeHeadlessDriver,
  DEFAULT_TIMEOUT_MS,
  RESULT_EXIT_GRACE_MS,
  TIMEOUT_WARN_BEFORE_MS,
} from '../src/claude-driver.ts';
import type { PromptOptions, StreamEvent } from '../src/driver.ts';
import { fakeClaude, tmpDir, type FakeScript } from '../src/testkit.ts';
import type { TurnOutcome } from '../src/turn-outcome.ts';
import { TurnScope, type TurnClock } from '../src/turn-scope.ts';

let tmp: string;
before(() => {
  tmp = tmpDir('lifecycle-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/** Time that moves only when told to, firing what falls due on the way, in order. */
class FakeClock implements TurnClock {
  private t = 0;
  private queue: Array<{ readonly at: number; readonly fn: () => void }> = [];

  now(): number {
    return this.t;
  }

  after(ms: number, fn: () => void): () => void {
    const entry = { at: this.t + ms, fn };
    this.queue.push(entry);
    return () => {
      this.queue = this.queue.filter((x) => x !== entry);
    };
  }

  /** Timers scheduled and neither fired nor cancelled. */
  get pending(): number {
    return this.queue.length;
  }

  advance(ms: number): void {
    const end = this.t + ms;
    for (;;) {
      const due = this.queue.filter((x) => x.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      this.queue = this.queue.filter((x) => x !== due);
      this.t = due.at;
      due.fn();
    }
    this.t = end;
  }
}

interface Turn {
  readonly clock: FakeClock;
  readonly log: string[];
  readonly outcome: Promise<TurnOutcome>;
  /** Resolves on the first event of that kind. */
  readonly seen: (kind: StreamEvent['kind']) => Promise<void>;
}

function start(bin: string, o: Partial<PromptOptions> = {}): Turn {
  const clock = new FakeClock();
  const log: string[] = [];
  const waiting = new Map<string, () => void>();
  const arrived = new Set<string>();
  const d = new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state'), clock });
  const outcome = d.open({ kind: 'claude', cwd: tmp, skipPermissions: false, bin }).then((ref) =>
    d.prompt(ref, 'go', {
      timeoutMs: DEFAULT_TIMEOUT_MS,
      log: (l) => log.push(l),
      onEvent: (e) => {
        arrived.add(e.kind);
        waiting.get(e.kind)?.();
      },
      ...o,
    })
  );
  const seen = (kind: string): Promise<void> =>
    arrived.has(kind) ? Promise.resolve() : new Promise((resolve) => waiting.set(kind, resolve));
  return { clock, log, outcome, seen };
}

const fake = (script: FakeScript): string => fakeClaude(script, fs.mkdtempSync(path.join(tmp, 'fake-'))).bin;
const RESULT = { text: 'done' };

test('a disposed scope owns nothing, schedules nothing, and disposes once', () => {
  const clock = new FakeClock();
  const scope = new TurnScope(clock);
  const ac = new AbortController();
  let fired = 0;
  let aborted = 0;
  scope.after(100, () => fired++);
  const cancel = scope.after(200, () => fired++);
  scope.onAbort(ac.signal, () => aborted++);
  assert.equal(scope.size, 3);
  cancel();
  assert.equal(scope.size, 2, 'a cancelled timer leaves the scope');

  assert.equal(scope.dispose(), true);
  assert.equal(scope.dispose(), false, 'the second dispose is a no-op');
  scope.after(10, () => fired++);
  clock.advance(1000);
  ac.abort();
  assert.deepEqual({ fired, aborted, owned: scope.size, pending: clock.pending }, { fired: 0, aborted: 0, owned: 0, pending: 0 });
});

test('the 50-minute timeout warns at 45:00 and kills at 50:00, to the millisecond', async () => {
  const t0 = Date.now();
  const warns: Array<{ elapsedMs: number; leftMs: number }> = [];
  const turn = start(fake({ tools: ['Bash'], result: null, hang: true }), { onWarn: (w) => warns.push(w) });
  await turn.seen('tool_use');

  const warnAt = DEFAULT_TIMEOUT_MS - TIMEOUT_WARN_BEFORE_MS;
  turn.clock.advance(warnAt - 1);
  assert.equal(warns.length, 0);
  turn.clock.advance(1);
  assert.deepEqual(warns, [{ elapsedMs: warnAt, leftMs: TIMEOUT_WARN_BEFORE_MS }]);

  turn.clock.advance(TIMEOUT_WARN_BEFORE_MS - 1);
  assert.doesNotMatch(turn.log.join('\n'), /timed out/);
  turn.clock.advance(1);
  assert.match(turn.log.join('\n'), /timed out after 50 min/);

  const o = await turn.outcome;
  assert.equal(o.kind, 'timeout');
  if (o.kind === 'timeout') assert.equal(o.toolUses, 1);
  assert.equal(turn.clock.pending, 0, 'nothing outlives the turn');
  assert.ok(Date.now() - t0 < 5000, 'fifty minutes did not take fifty minutes');
});

test('a result cancels the killer and starts the 60-second grace, which kills at 60:00 exactly', async () => {
  const turn = start(fake({ tools: ['Bash'], result: RESULT, hangAfterResult: true }));
  await turn.seen('result');
  assert.equal(turn.clock.pending, 1, 'only the grace timer is left: the killer went with the result');

  turn.clock.advance(RESULT_EXIT_GRACE_MS - 1);
  assert.doesNotMatch(turn.log.join('\n'), /did not exit/);
  turn.clock.advance(1);
  assert.match(turn.log.join('\n'), /printed its result but did not exit within 60000 ms/);

  const o = await turn.outcome;
  assert.equal(o.kind, 'killed-after-result');
  assert.equal(turn.clock.pending, 0);
});

test('a result at clock time zero still silences the warning', async () => {
  // The old guard was `if (resultAt || exit)`: a timestamp used as a boolean.
  const warns: unknown[] = [];
  const turn = start(fake({ result: RESULT, hangAfterResult: true }), {
    exitGraceMs: DEFAULT_TIMEOUT_MS,
    onWarn: (w) => warns.push(w),
  });
  await turn.seen('result');
  assert.equal(turn.clock.now(), 0);
  turn.clock.advance(DEFAULT_TIMEOUT_MS);
  const o = await turn.outcome;
  assert.equal(o.kind, 'killed-after-result');
  assert.deepEqual(warns, []);
});

test('a result flushed during teardown still counts, and schedules no grace timer', async () => {
  // The last line has no newline, so the reader only sees it in finish().
  const bin = path.join(fs.mkdtempSync(path.join(tmp, 'flush-')), 'claude');
  const payload = { type: 'result', subtype: 'success', is_error: false, result: 'done', session_id: 's-1', total_cost_usd: 0, num_turns: 1 };
  fs.writeFileSync(bin, `#!/bin/sh\nprintf '%s' '${JSON.stringify(payload)}'\n`);
  fs.chmodSync(bin, 0o755);

  const turn = start(bin);
  const o = await turn.outcome;
  assert.equal(o.kind, 'ok');
  assert.equal(turn.clock.pending, 0, 'the old finish() left a live grace timer here');
});
