// The one Telegram limit every text path hits.

/** Telegram's hard ceiling for one text message. */
export const TG_TEXT_LIMIT = 4096;

/**
 * Split on a paragraph break, then a line break, then a space, then hard;
 * never exceeds `limit`.
 *
 * Ported from sdano-bot unchanged, boundary rule for boundary rule. The
 * `cut < limit / 2` guards are the point: a separator found in the first half
 * of the window is worse than no separator at all, because honouring it would
 * turn one long message into a spray of short ones. Whitespace at a seam is
 * dropped — the chunk before it is trimmed at the end, the chunk after it at
 * the start — so reassembly is `join(' ')` or `join('\n')` depending on where
 * it cut, and neither chunk carries a stray blank line into the chat.
 *
 * An empty (or all-whitespace) text yields no chunks at all, which is how a
 * caller avoids sending a message the Bot API would reject.
 */
export function splitMessage(text: string, limit: number = TG_TEXT_LIMIT): string[] {
  const out: string[] = [];
  let rest = text.trim();
  while (rest.length > limit) {
    let cut = rest.lastIndexOf('\n\n', limit);
    if (cut < limit / 2) cut = rest.lastIndexOf('\n', limit);
    if (cut < limit / 2) cut = rest.lastIndexOf(' ', limit);
    if (cut < limit / 2) cut = limit;
    out.push(rest.slice(0, cut).trimEnd());
    rest = rest.slice(cut).trimStart();
  }
  if (rest) out.push(rest);
  return out;
}
