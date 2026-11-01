/** The `code` of a Node error (`ENOENT`, `EINVAL`, ...), or undefined for anything else. */
export function errnoCode(e: unknown): string | undefined {
  return e instanceof Error && 'code' in e && typeof e.code === 'string' ? e.code : undefined;
}
