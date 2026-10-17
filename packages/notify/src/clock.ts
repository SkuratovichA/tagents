// Time, as the engine sees it: a reading and a way to be woken later.
//
// `after` hands back its own cancel function instead of a timer handle. A handle
// is `NodeJS.Timeout` here and a number in a browser, and a test that fakes the
// clock would have to forge one with a type assertion. A closure has no such
// type to forge.
export interface Clock {
  now(): number;
  after(ms: number, fn: () => void): () => void;
}

export const systemClock: Clock = {
  now: () => Date.now(),
  after(ms, fn) {
    const timer = setTimeout(fn, ms);
    return () => clearTimeout(timer);
  },
};
