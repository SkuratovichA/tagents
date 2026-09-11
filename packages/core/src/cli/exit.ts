// The two things every verb of this CLI needs, in a module neither half has to
// import the other to get: the exit codes, and where output goes.
//
// Exit codes: 0 ok · 1 error · 2 usage · 3 refused · 4 timeout. "Refused" is
// the one worth spelling out — it means nothing was done ON PURPOSE (the entry
// is already there, the package is not a plugin), as opposed to an error, where
// something went wrong on the way.

export const EXIT = { ok: 0, error: 1, usage: 2, refused: 3, timeout: 4 } as const;

export interface Io {
  out: (s: string) => void;
  err: (s: string) => void;
}

/** Exactly one pretty-printed document, which is what the JSON verbs promise. */
export const json = (value: unknown): string => `${JSON.stringify(value, null, 2)}\n`;
