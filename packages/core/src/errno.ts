// Not re-exported from index.ts: an internal helper of this package's readers.

/** The `code` of a Node error (`ENOENT`, `EINVAL`, ...), or undefined for anything else. */
export function errnoCode(e: unknown): string | undefined {
  if (!(e instanceof Error)) return undefined;
  const code: unknown = (e as NodeJS.ErrnoException).code;
  return typeof code === 'string' ? code : undefined;
}
