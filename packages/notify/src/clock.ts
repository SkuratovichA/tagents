// Time, as the engine sees it: a reading and a way to be woken later.
//
// core owns both: `TurnClock` and `realClock` (turn-scope.ts) are the clock the
// follower's turns already run on, and a second copy here could drift from it.
// Notify keeps its own names so no importer changes.
//
// `after` hands back its own cancel function instead of a timer handle. A handle
// is `NodeJS.Timeout` here and a number in a browser, and a test that fakes the
// clock would have to forge one with a type assertion. A closure has no such
// type to forge.
import { realClock, type TurnClock } from '@tagents/core';

export type Clock = TurnClock;

export const systemClock: Clock = realClock;
