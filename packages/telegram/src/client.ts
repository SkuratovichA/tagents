// One Telegram client, shared by every plugin that has a bot token.
//
// Two copies of this existed before it: the orchestrator's `tg()` inside
// runner.ts and the busano ticket agent's `makeTg()` in an .mjs lib. They agreed
// on everything that matters (POST JSON, parse the envelope, throw the API's own
// words, abort on a deadline) and drifted on everything else. This is that
// agreement, typed.
//
// Nothing here formats anything for a person to read: no i18n, no logging, no
// locale. The package talks to an API; what a bot SAYS belongs to the bot.
import { TelegramError } from './errors.ts';
import { EnvelopeSchema, MessageSchema, UpdatesSchema, UserSchema } from './schemas.ts';
import type { TgMessage, TgUpdate, TgUser } from './schemas.ts';
import { splitMessage } from './split.ts';

/** Telegram's own host. Overridable for a local Bot API server or a test. */
export const TELEGRAM_API_BASE = 'https://api.telegram.org';

/** How long one call may take before its socket is aborted. */
export const DEFAULT_TIMEOUT_MS = 30_000;

/**
 * How much longer than its long-poll window `getUpdates` is given.
 *
 * The request is designed to hang for `timeout` seconds; an HTTP deadline at or
 * below that aborts every healthy poll. 15 s of slack is what both runners used.
 */
export const POLL_TIMEOUT_SLACK_MS = 15_000;

/** Telegram drops a typing indicator after about 5 s, so it is re-sent sooner. */
export const TYPING_INTERVAL_MS = 4_000;

export interface TelegramOptions {
  /** The bot token, as BotFather issued it. */
  token: string;
  /** Default `https://api.telegram.org`. No trailing slash needed. */
  apiBase?: string;
  /** Injected for tests, a proxy, or a retrying fetch. Default: global fetch. */
  fetch?: typeof fetch;
  /** Default deadline for every call. Default 30 s. */
  timeoutMs?: number;
}

export interface CallOptions {
  /** Overrides the client's default deadline for this one call. */
  timeoutMs?: number;
}

/** The options every text-carrying method shares. */
export interface SendOptions {
  /** A forum topic id (`message_thread_id`). */
  threadId?: number;
  /** Reply to this message id; the send still goes through if it is gone. */
  replyTo?: number;
  parseMode?: 'HTML' | 'Markdown' | 'MarkdownV2';
  /** `true` suppresses the link preview, `false` forces it on. */
  disablePreview?: boolean;
}

export interface GetUpdatesOptions {
  /**
   * The first update id to receive. Telegram never redelivers anything below
   * it, so a caller moves it past an update only once that update is on disk.
   */
  offset: number;
  /** Long-poll window, in SECONDS — Telegram's own unit for this field. */
  timeoutS: number;
  /** e.g. `['message']`. Omitted means Telegram's default set. */
  allowedUpdates?: readonly string[];
}

export interface Telegram {
  /**
   * Any Bot API method. Returns the envelope's `result` unparsed — it is
   * whatever that method answers with, and the caller knows which schema fits.
   * Throws {@link TelegramError} when the envelope is not ok.
   */
  call(method: string, params?: Record<string, unknown>, opts?: CallOptions): Promise<unknown>;
  getMe(): Promise<TgUser>;
  getUpdates(opts: GetUpdatesOptions): Promise<TgUpdate[]>;
  sendMessage(chatId: number, text: string, opts?: SendOptions): Promise<TgMessage>;
  /** `sendMessage` over {@link splitMessage} chunks, in order. */
  sendText(chatId: number, text: string, opts?: SendOptions): Promise<TgMessage[]>;
  setMessageReaction(chatId: number, messageId: number, emoji: string): Promise<void>;
  editMessageText(chatId: number, messageId: number, text: string, opts?: SendOptions): Promise<unknown>;
  /** Keeps "typing…" on for the whole of `fn`, and returns what `fn` returns. */
  withTyping<T>(chatId: number, threadId: number | undefined, fn: () => Promise<T>): Promise<T>;
}

/**
 * The text fields, mapped to the Bot API's names.
 *
 * `reply_parameters` rather than the deprecated `reply_to_message_id`, and with
 * `allow_sending_without_reply` on: a reply target can be deleted between the
 * message arriving and the answer being ready, and losing the answer over a
 * missing arrow is the wrong trade.
 */
function textParams(text: string, o: SendOptions): Record<string, unknown> {
  return {
    text,
    ...(o.threadId === undefined ? {} : { message_thread_id: o.threadId }),
    ...(o.replyTo === undefined
      ? {}
      : { reply_parameters: { message_id: o.replyTo, allow_sending_without_reply: true } }),
    ...(o.parseMode === undefined ? {} : { parse_mode: o.parseMode }),
    ...(o.disablePreview === undefined ? {} : { link_preview_options: { is_disabled: o.disablePreview } }),
  };
}

/** A client bound to one bot token. */
export function createTelegram(opts: TelegramOptions): Telegram {
  const base = `${(opts.apiBase ?? TELEGRAM_API_BASE).replace(/\/+$/, '')}/bot${opts.token}`;
  const doFetch: typeof fetch = opts.fetch ?? fetch;
  const defaultTimeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  async function call(
    method: string,
    params: Record<string, unknown> = {},
    callOpts: CallOptions = {}
  ): Promise<unknown> {
    // The deadline is a socket abort, not a rejected promise beside a live
    // request: a poll loop that leaves its sockets open runs out of them.
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), callOpts.timeoutMs ?? defaultTimeoutMs);
    try {
      const res = await doFetch(`${base}/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(params),
        signal: ctl.signal,
      });
      const body = EnvelopeSchema.parse(await res.json());
      if (!body.ok) throw new TelegramError(method, body.error_code, body.description);
      return body.result;
    } finally {
      clearTimeout(timer);
    }
  }

  async function getMe(): Promise<TgUser> {
    return UserSchema.parse(await call('getMe'));
  }

  async function getUpdates(o: GetUpdatesOptions): Promise<TgUpdate[]> {
    const result = await call(
      'getUpdates',
      {
        offset: o.offset,
        timeout: o.timeoutS,
        ...(o.allowedUpdates === undefined ? {} : { allowed_updates: o.allowedUpdates }),
      },
      { timeoutMs: o.timeoutS * 1000 + POLL_TIMEOUT_SLACK_MS }
    );
    return UpdatesSchema.parse(result);
  }

  async function sendMessage(chatId: number, text: string, o: SendOptions = {}): Promise<TgMessage> {
    return MessageSchema.parse(await call('sendMessage', { chat_id: chatId, ...textParams(text, o) }));
  }

  async function sendText(chatId: number, text: string, o: SendOptions = {}): Promise<TgMessage[]> {
    // The reply arrow goes on the first chunk only. Pointing every chunk of one
    // answer at the same question is noise, and Telegram renders each of them as
    // a separate quote block.
    const { replyTo, ...rest } = o;
    const sent: TgMessage[] = [];
    for (const [i, chunk] of splitMessage(text).entries()) {
      const chunkOpts: SendOptions = i === 0 && replyTo !== undefined ? { ...rest, replyTo } : rest;
      sent.push(await sendMessage(chatId, chunk, chunkOpts));
    }
    return sent;
  }

  async function setMessageReaction(chatId: number, messageId: number, emoji: string): Promise<void> {
    await call('setMessageReaction', {
      chat_id: chatId,
      message_id: messageId,
      reaction: [{ type: 'emoji', emoji }],
    });
  }

  // Unparsed on purpose: an edit answers with the edited Message, except on an
  // inline message, where it answers `true`.
  function editMessageText(
    chatId: number,
    messageId: number,
    text: string,
    o: SendOptions = {}
  ): Promise<unknown> {
    return call('editMessageText', { chat_id: chatId, message_id: messageId, ...textParams(text, o) });
  }

  async function withTyping<T>(chatId: number, threadId: number | undefined, fn: () => Promise<T>): Promise<T> {
    const tick = (): void => {
      // Best effort by construction: a chat where the bot may not send an action
      // is not a reason to abandon the work the action was announcing.
      void call('sendChatAction', {
        chat_id: chatId,
        action: 'typing',
        ...(threadId === undefined ? {} : { message_thread_id: threadId }),
      }).catch(() => undefined);
    };
    tick();
    const timer = setInterval(tick, TYPING_INTERVAL_MS);
    try {
      return await fn();
    } finally {
      clearInterval(timer);
    }
  }

  return {
    call,
    getMe,
    getUpdates,
    sendMessage,
    sendText,
    setMessageReaction,
    editMessageText,
    withTyping,
  };
}
