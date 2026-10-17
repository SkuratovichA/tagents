/** Comparison by UTF-16 code unit: the order `Array.prototype.sort()` gives strings, with no locale taking part. */
export function byCodeUnit(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
