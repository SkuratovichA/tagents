// What a Bot API refusal becomes.
//
// The message text is a contract, not a nicety. `${method}: ${code} ${description}`
// is what the busano ticket agent's client has thrown since it was written, and
// callers match Telegram's own words inside it — boards.mjs treats a rejection
// whose description says "message is not modified" as success, because it is.
// Re-wording this string would break that grep silently, so it is pinned by a
// test and reproduced here byte for byte.

/** One failed Bot API call: `ok: false`, with the API's own words in it. */
export class TelegramError extends Error {
  /** The Bot API method that was called, e.g. `sendMessage`. */
  readonly method: string;
  /**
   * Telegram's `error_code`. Undefined when the body carried none — a reply
   * that is neither ok nor an error is still a refusal, and the message then
   * reads `<method>: undefined undefined`, which is what the ported clients
   * have always produced for it.
   */
  readonly code: number | string | undefined;
  /** Telegram's `description`. What callers actually match on. */
  readonly description: string | undefined;

  constructor(method: string, code: number | string | undefined, description: string | undefined) {
    super(`${method}: ${code} ${description}`);
    this.name = 'TelegramError';
    this.method = method;
    this.code = code;
    this.description = description;
  }
}
