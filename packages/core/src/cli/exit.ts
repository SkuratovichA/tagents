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

/**
 * `tagents-core sessions recent | head` closes the pipe while we are still
 * writing, and an unhandled EPIPE turns that into a stack trace on a command
 * that did nothing wrong. Reading half the output is a legitimate thing to do
 * to a CLI, so the writes are best-effort.
 */
export function stdio(): Io {
  const ignore = (): void => undefined;
  process.stdout.on('error', ignore);
  process.stderr.on('error', ignore);
  const write = (stream: NodeJS.WriteStream, text: string): void => {
    try {
      stream.write(text);
    } catch {
      // The reader is gone; there is nobody left to tell.
    }
  };
  return {
    out: (s) => write(process.stdout, s),
    err: (s) => write(process.stderr, s),
  };
}
