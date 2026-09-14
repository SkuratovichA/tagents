// One turn's timers and listeners, owned in one place.
//
// The driver used to keep a timers[] array, an abort listener and a `done` flag
// side by side and trust finish() to clear all three. A scope is that contract
// as an object: everything it hands out is torn down by dispose(), dispose() is
// idempotent, and nothing can be scheduled on a disposed scope — so a timer
// registered from inside the teardown (a last `result` line flushed by
// reader.end(), an `exit` that arrives after an `error` already finished the
// turn) no longer outlives the turn it belongs to.

/** Where a turn gets its time. The real one is Date.now and setTimeout; a test passes a fake. */
export interface TurnClock {
  now(): number;
  /** Run `fn` after `ms`; the returned function cancels it. */
  after(ms: number, fn: () => void): () => void;
}

export const realClock: TurnClock = {
  now: () => Date.now(),
  after: (ms, fn) => {
    const t = setTimeout(fn, ms);
    return () => clearTimeout(t);
  },
};

export class TurnScope {
  private readonly clock: TurnClock;
  /** One entry per live timer or listener: the thing that tears it down. */
  private readonly owned = new Set<() => void>();
  private closed = false;

  constructor(clock: TurnClock) {
    this.clock = clock;
  }

  get disposed(): boolean {
    return this.closed;
  }

  /** How many timers and listeners are still live. Zero once disposed. */
  get size(): number {
    return this.owned.size;
  }

  /** A timer the scope owns. On a disposed scope it is never scheduled. Returns its cancel. */
  after(ms: number, fn: () => void): () => void {
    if (this.closed) return () => undefined;
    let clear = (): void => undefined;
    const cancel = (): void => {
      this.owned.delete(cancel);
      clear();
    };
    this.owned.add(cancel);
    clear = this.clock.after(ms, () => {
      this.owned.delete(cancel);
      if (!this.closed) fn();
    });
    return cancel;
  }

  /** An abort listener the scope owns, removed on dispose. No signal, no listener. */
  onAbort(signal: AbortSignal | undefined, fn: () => void): void {
    if (!signal || this.closed) return;
    signal.addEventListener('abort', fn, { once: true });
    this.owned.add(() => signal.removeEventListener('abort', fn));
  }

  /** Tear down everything still owned. Returns false if it had already been disposed. */
  dispose(): boolean {
    if (this.closed) return false;
    this.closed = true;
    for (const teardown of this.owned) teardown();
    this.owned.clear();
    return true;
  }
}
