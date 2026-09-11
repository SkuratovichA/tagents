// What one headless turn ended as — the typed replacement for the loose
// `attempt` object orchestrator/src/turn.mjs resolves with.
//
// The one thing to keep in mind while reading this file: THE EXIT CODE IS NOT
// WORK COMPLETION. A turn is over when its `result` event arrives; a child that
// printed its result and then hung on the way out (an MCP server, a grandchild
// holding the pipe) is killed afterwards and still succeeded. Reading that kill
// as a failure is what made the orchestrator re-run a finished job on 10.09 and
// deliver every report twice, so the two cases are separate kinds here rather
// than a boolean somebody can forget to check.
import { z } from 'zod';

/** Money/turn counters come from the `result` event and may simply be absent. */
const Counters = {
  costUsd: z.number().nullable(),
  numTurns: z.number().nullable(),
  durationMs: z.number(),
};

const Ok = z.object({
  kind: z.literal('ok'),
  text: z.string(),
  sessionId: z.string().nullable(),
  toolUses: z.number(),
  ...Counters,
});

/** Finished, then killed: `result` arrived, the process left with code !== 0. */
const KilledAfterResult = z.object({
  kind: z.literal('killed-after-result'),
  text: z.string(),
  sessionId: z.string().nullable(),
  toolUses: z.number(),
  ...Counters,
  code: z.number().nullable(),
});

/** Our own timeout killer fired: no `result` ever came. */
const Timeout = z.object({
  kind: z.literal('timeout'),
  sessionId: z.string().nullable(),
  toolUses: z.number(),
  limitMs: z.number(),
  detail: z.string(),
});

/** The child left on its own without a usable result (or with is_error=true). */
const Exited = z.object({
  kind: z.literal('exited'),
  sessionId: z.string().nullable(),
  toolUses: z.number(),
  code: z.number().nullable(),
  signal: z.string().nullable(),
  detail: z.string(),
});

/** There was never a process: ENOENT, EACCES, a bad interpreter. */
const SpawnFailed = z.object({
  kind: z.literal('spawn-failed'),
  detail: z.string(),
});

export const TurnOutcomeSchema = z.discriminatedUnion('kind', [
  Ok,
  KilledAfterResult,
  Timeout,
  Exited,
  SpawnFailed,
]);

export type TurnOutcome = z.infer<typeof TurnOutcomeSchema>;
export type OkOutcome = z.infer<typeof Ok>;
export type KilledAfterResultOutcome = z.infer<typeof KilledAfterResult>;
export type TimeoutOutcome = z.infer<typeof Timeout>;
export type ExitedOutcome = z.infer<typeof Exited>;
export type SpawnFailedOutcome = z.infer<typeof SpawnFailed>;

/** The turn did its work — the only question a caller usually has. */
export function succeeded(o: TurnOutcome): o is OkOutcome | KilledAfterResultOutcome {
  return o.kind === 'ok' || o.kind === 'killed-after-result';
}

/** The assistant's own text, when the turn got far enough to produce any. */
export function outcomeText(o: TurnOutcome): string {
  return succeeded(o) ? o.text : '';
}

export function outcomeSessionId(o: TurnOutcome): string | null {
  return o.kind === 'spawn-failed' ? null : o.sessionId;
}

export function outcomeToolUses(o: TurnOutcome): number {
  return o.kind === 'spawn-failed' ? 0 : o.toolUses;
}

// `detail` is already squeezed and clipped the way turn.mjs clips it; doing it
// again here would be free but would also hide a caller that forgot to.
const DETAIL_MAX = 300;
export const clipDetail = (s: string): string => s.replace(/\s+/g, ' ').slice(0, DETAIL_MAX);

/**
 * The owner-facing one-liner, byte for byte what turn.mjs put in `attempt.error`:
 *
 *   `exit=<code|signal|null> [(timeout <ms>ms, N tool call(s)) ]<detail>`
 *
 * The orchestrator prints this into a Telegram topic and its contract tests
 * pin it, so the format is API. A successful turn has no error line: null.
 *
 * A timeout always shows `exit=SIGKILL` because the timeout path is the only
 * one that kills, and it kills with SIGKILL — the same token turn.mjs printed
 * from the real exit signal.
 */
export function formatAttemptError(o: TurnOutcome): string | null {
  if (o.kind === 'ok' || o.kind === 'killed-after-result') return null;
  if (o.kind === 'spawn-failed') return `exit=null spawn: ${o.detail}`;
  if (o.kind === 'timeout')
    return `exit=SIGKILL (timeout ${o.limitMs}ms, ${o.toolUses} tool call(s)) ${o.detail}`;
  return `exit=${o.code ?? o.signal ?? 'null'} ${o.detail}`;
}
