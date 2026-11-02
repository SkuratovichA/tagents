// The clip and error sections of the session vectors: `clipDetail`, which squeezes white space and cuts at 300 UTF-16 units, and `formatAttemptError`, the error line of a turn that did not succeed.
//
// A clip case is the text of a JSON string (a lone surrogate written as its escape), and the answer is the text `JSON.stringify` writes for the clipped string, so a cut inside a surrogate pair is the escape of the half that is left.
import { clipDetail, formatAttemptError, type TurnOutcome } from '../../packages/core/src/turn-outcome.ts';

const letters = (n: number): string => 'x'.repeat(n);

const CLIPS: string[] = [
  '',
  'plain',
  '  leading and trailing  ',
  'a\n\nb\t\tc   d',
  'a\u00a0\u2003b\u3000c\ufeffd\u2028e\u2029f',
  'a\u0085b\u200bc\u180ed',
  letters(299),
  letters(300),
  letters(301),
  `${letters(299)}\u{1F600}`,
  `${letters(298)}\u{1F600}`,
  `${letters(300)}\u{1F600}`,
  `${letters(297)}\u{1F600}\u{1F600}`,
  `${'a \n '.repeat(200)}`,
  `${letters(298)}   \u{1F600}`,
  '\u00e9'.repeat(400),
  '\u4e2d'.repeat(301),
  `${letters(299)}\ud83d`,
  `${letters(299)}\ude00`,
  '\ud83d',
];

const OUTCOMES: Array<{ readonly name: string; readonly outcome: TurnOutcome }> = [
  { name: 'ok', outcome: { kind: 'ok', text: 'done', sessionId: 's', toolUses: 1, costUsd: 0.01, numTurns: 2, durationMs: 3 } },
  { name: 'killed-after-result', outcome: { kind: 'killed-after-result', text: 'done', sessionId: 's', toolUses: 1, costUsd: null, numTurns: null, durationMs: null, code: null } },
  { name: 'timeout', outcome: { kind: 'timeout', sessionId: null, toolUses: 2, limitMs: 400, detail: 'slow', sawText: true, sawResult: false } },
  { name: 'timeout-fraction', outcome: { kind: 'timeout', sessionId: 's', toolUses: 0, limitMs: 0.5, detail: '', sawText: false, sawResult: false } },
  { name: 'timeout-big', outcome: { kind: 'timeout', sessionId: 's', toolUses: 0, limitMs: 1e21, detail: 'x', sawText: false, sawResult: false } },
  { name: 'exited-code', outcome: { kind: 'exited', sessionId: null, toolUses: 0, code: 1, signal: null, detail: 'boom', sawText: false, sawResult: false } },
  { name: 'exited-code-zero', outcome: { kind: 'exited', sessionId: null, toolUses: 0, code: 0, signal: null, detail: 'no result', sawText: true, sawResult: false } },
  { name: 'exited-signal', outcome: { kind: 'exited', sessionId: 's', toolUses: 1, code: null, signal: 'SIGKILL', detail: '', sawText: false, sawResult: false } },
  { name: 'exited-neither', outcome: { kind: 'exited', sessionId: null, toolUses: 0, code: null, signal: null, detail: 'x', sawText: false, sawResult: false } },
  { name: 'spawn-failed', outcome: { kind: 'spawn-failed', detail: 'spawn claude ENOENT' } },
];

export function outcomeVectors(): unknown {
  return {
    clip: CLIPS.map((value) => ({ text: JSON.stringify(value), clipped: JSON.stringify(clipDetail(value)) })),
    error: OUTCOMES.map(({ name, outcome }) => ({ name, outcome: JSON.stringify(outcome), error: formatAttemptError(outcome) })),
  };
}
