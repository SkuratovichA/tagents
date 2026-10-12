// Exit codes, in a module the command specs can read without importing main.ts (which imports them).
export const EXIT = { ok: 0, error: 1, usage: 2, notFound: 4 } as const;
