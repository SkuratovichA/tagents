/** What a log line can carry of a thrown value: an error's message, or the value as text. */
export const describe = (err: unknown): string => (err instanceof Error ? err.message : String(err));
