// The outcome union and the one string the orchestrator prints from it.
//
// formatAttemptError reproduces `attempt.error` from turn.mjs byte for byte;
// the strings asserted here are the ones the orchestrator's own suite asserts,
// because an owner-facing message that drifts is a message nobody recognises.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  clipDetail,
  evidence,
  formatAttemptError,
  outcomeSessionId,
  outcomeText,
  outcomeToolUses,
  succeeded,
  TurnOutcomeSchema,
  type TurnOutcome,
} from '../src/turn-outcome.ts';

const ok: TurnOutcome = {
  kind: 'ok',
  text: 'hi',
  sessionId: 'sess-1',
  toolUses: 1,
  costUsd: 0.1,
  numTurns: 3,
  durationMs: 5,
};

test('a finished turn has no error line, whether or not it was killed on the way out', () => {
  assert.equal(formatAttemptError(ok), null);
  assert.equal(formatAttemptError({ ...ok, kind: 'killed-after-result', code: null }), null);
  assert.equal(succeeded(ok), true);
  assert.equal(succeeded({ ...ok, kind: 'killed-after-result', code: null }), true);
});

test('the timeout line is the one turn.mjs printed', () => {
  assert.equal(
    formatAttemptError({ kind: 'timeout', sessionId: 'sess-1', toolUses: 1, limitMs: 400, detail: '' }),
    'exit=SIGKILL (timeout 400ms, 1 tool call(s)) '
  );
  assert.equal(
    formatAttemptError({ kind: 'timeout', sessionId: null, toolUses: 0, limitMs: 3000000, detail: 'stuck' }),
    'exit=SIGKILL (timeout 3000000ms, 0 tool call(s)) stuck'
  );
});

test('an exit shows the code, or the signal when there is no code', () => {
  const base = { kind: 'exited', sessionId: null, toolUses: 0 } as const;
  assert.equal(
    formatAttemptError({ ...base, code: 1, signal: null, detail: 'No conversation found with session ID: abc' }),
    'exit=1 No conversation found with session ID: abc'
  );
  assert.equal(formatAttemptError({ ...base, code: null, signal: 'SIGTERM', detail: '' }), 'exit=SIGTERM ');
  assert.equal(formatAttemptError({ ...base, code: null, signal: null, detail: '' }), 'exit=null ');
});

test('a spawn failure names the spawn', () => {
  assert.equal(
    formatAttemptError({ kind: 'spawn-failed', detail: 'spawn /x/claude ENOENT' }),
    'exit=null spawn: spawn /x/claude ENOENT'
  );
});

test('the detail is squeezed to one line and clipped at 300 characters', () => {
  assert.equal(clipDetail(' a\n b\t\tc '), ' a b c ');
  assert.equal(clipDetail('x'.repeat(400)).length, 300);
});

test('the accessors do not make a caller re-switch on the kind', () => {
  const timeout: TurnOutcome = { kind: 'timeout', sessionId: 's', toolUses: 2, limitMs: 1, detail: '' };
  assert.equal(outcomeText(ok), 'hi');
  assert.equal(outcomeText(timeout), '');
  assert.equal(outcomeSessionId(timeout), 's');
  assert.equal(outcomeSessionId({ kind: 'spawn-failed', detail: 'x' }), null);
  assert.equal(outcomeToolUses(timeout), 2);
  assert.equal(outcomeToolUses({ kind: 'spawn-failed', detail: 'x' }), 0);
});

test('evidence answers for every kind, and reads a missing flag as no evidence', () => {
  // A finished turn: the result is what makes it one, and its text is on it.
  assert.deepEqual(evidence(ok), { toolUses: 1, sawText: true, sawResult: true });
  assert.deepEqual(evidence({ ...ok, kind: 'killed-after-result', code: 143 }), {
    toolUses: 1,
    sawText: true,
    sawResult: true,
  });
  assert.deepEqual(
    evidence({ kind: 'timeout', sessionId: 's', toolUses: 2, limitMs: 1, detail: '', sawText: true, sawResult: false }),
    { toolUses: 2, sawText: true, sawResult: false }
  );
  assert.deepEqual(
    evidence({
      kind: 'exited',
      sessionId: 's',
      toolUses: 0,
      code: 1,
      signal: null,
      detail: 'refused',
      sawText: false,
      sawResult: true,
    }),
    { toolUses: 0, sawText: false, sawResult: true }
  );
  // There was never a process, so there is nothing it could have done.
  assert.deepEqual(evidence({ kind: 'spawn-failed', detail: 'x' }), {
    toolUses: 0,
    sawText: false,
    sawResult: false,
  });
  // An outcome built before 0.2.0 carries no flags: absence of proof, not proof.
  assert.deepEqual(evidence({ kind: 'timeout', sessionId: null, toolUses: 3, limitMs: 1, detail: '' }), {
    toolUses: 3,
    sawText: false,
    sawResult: false,
  });
});

test('the evidence flags are optional, so an outcome written by 0.1 still parses', () => {
  const old = { kind: 'timeout', sessionId: null, toolUses: 0, limitMs: 400, detail: 'stuck' };
  assert.equal(TurnOutcomeSchema.safeParse(old).success, true);
  assert.equal(TurnOutcomeSchema.safeParse({ ...old, sawText: true, sawResult: false }).success, true);
  assert.equal(TurnOutcomeSchema.safeParse({ ...old, sawText: 'yes' }).success, false);
  // They change nothing about the owner-facing line.
  assert.equal(
    formatAttemptError({ ...old, kind: 'timeout', sawText: true, sawResult: true }),
    'exit=SIGKILL (timeout 400ms, 0 tool call(s)) stuck'
  );
});

test('the union survives a round trip through JSON, and refuses a wrong shape', () => {
  const parsed = TurnOutcomeSchema.parse(JSON.parse(JSON.stringify(ok)));
  assert.deepEqual(parsed, ok);
  assert.equal(TurnOutcomeSchema.safeParse({ kind: 'ok' }).success, false, 'ok without its counters');
  assert.equal(TurnOutcomeSchema.safeParse({ kind: 'invented', detail: 'x' }).success, false);
  // A cost the model did not report stays null rather than becoming zero.
  assert.equal(TurnOutcomeSchema.safeParse({ ...ok, costUsd: null, numTurns: null }).success, true);
});
