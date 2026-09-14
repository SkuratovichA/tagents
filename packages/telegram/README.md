# @tagents/telegram

The Telegram Bot API, typed and small.

Two bots in this ecosystem talked to Telegram, and each carried its own client:
`tg()` inside the orchestrator's `runner.ts`, and `makeTg()` in the busano
ticket agent's `lib/telegram.mjs`. They agreed on everything that matters — POST
JSON, parse the envelope, throw the API's own words, abort on a deadline — and
drifted on everything else: one split long messages with a 3500-character regex,
the other with a paragraph-aware splitter that lived in a third bot. This
package is the agreement, with types on it.

It does not speak to a person. No i18n, no logging, no formatting for a chat
window: a plugin owns what its bot *says*, this owns how it is sent.

```ts
import { createTelegram, TelegramError } from '@tagents/telegram';

const tg = createTelegram({ token: process.env.TELEGRAM_BOT_TOKEN ?? '' });

for (const u of await tg.getUpdates({ offset: 0, timeoutS: 25, allowedUpdates: ['message'] })) {
  const m = u.message;
  if (!m?.text) continue;
  await tg.setMessageReaction(m.chat.id, m.message_id, '\u{1F440}');
  const answer = await tg.withTyping(m.chat.id, m.message_thread_id, () => think(m.text ?? ''));
  await tg.sendText(m.chat.id, answer, { threadId: m.message_thread_id, replyTo: m.message_id });
}
```

## The API

| | |
| --- | --- |
| `createTelegram({ token, apiBase?, fetch?, timeoutMs? })` | a client bound to one token. `apiBase` defaults to `https://api.telegram.org`, `timeoutMs` to 30 s, `fetch` to the global one |
| `call(method, params?, { timeoutMs? })` | any Bot API method. Returns the envelope's `result` as `unknown` — the caller knows which schema fits |
| `getMe()` | the bot user |
| `getUpdates({ offset, timeoutS, allowedUpdates? })` | one long poll. `timeoutS` is Telegram's own unit, seconds |
| `sendMessage(chatId, text, opts?)` | one message, one request; returns the sent `TgMessage` |
| `sendText(chatId, text, opts?)` | `sendMessage` over `splitMessage(text)` chunks, in order |
| `setMessageReaction(chatId, messageId, emoji)` | the one-emoji array the Bot API wants |
| `editMessageText(chatId, messageId, text, opts?)` | returns `unknown`: an ordinary edit answers with the Message, an inline one with `true` |
| `withTyping(chatId, threadId, fn)` | keeps "typing…" on for the whole of `fn`, returns what `fn` returns |
| `splitMessage(text, limit = 4096)` | paragraph, then line, then space, then hard |
| `TelegramError` | `method`, `code`, `description` |
| `EnvelopeSchema`, `MessageSchema`, `UpdateSchema`, `UpdatesSchema`, `UserSchema` | the parsed slices, with `TgMessage`, `TgUpdate`, `TgUser`, `TgEnvelope` |

`opts` for everything that carries text is one shape: `{ threadId?, replyTo?,
parseMode?, disablePreview? }`, mapped to `message_thread_id`,
`reply_parameters`, `parse_mode` and `link_preview_options`.

## The four decisions worth knowing

**The error message is a contract.** A non-ok envelope becomes
`TelegramError("<method>: <code> <description>")` — that exact text, because
production code matches Telegram's own words inside it. `boards.mjs` treats a
rejection whose description says *message is not modified* as success, and it
finds that by reading `e.message`. The fields are also on the error, so new code
can read `e.description` instead.

**The deadline aborts the socket.** Not a rejected promise beside a live
request: a poll loop that leaks sockets runs out of them. `getUpdates` gets its
own deadline — `timeoutS + 15 s` — because the request is *designed* to hang for
`timeoutS`, and a 30-second default would abort every healthy poll of a 25-second
long poll.

**`splitMessage` refuses a bad seam.** It looks for a paragraph break, then a
line break, then a space, and takes none of them if the best one falls in the
first half of the window — a separator found at character 12 of 4096 would turn
one answer into a spray of short messages. With nothing usable it cuts at the
limit. Whitespace at a seam is dropped, so chunks re-join cleanly and none of
them opens with a blank line.

**Nothing is best-effort here.** The orchestrator's `sendText` swallowed a
failed send into its log, and that belongs at the call site, which has a logger
and knows whether this message mattered: `tg.sendText(...).catch((e) => log('send
failed:', e.message))`. The one exception is inside `withTyping`, where a chat
that refuses `sendChatAction` must not take down the work the action was
announcing.

## Development

```sh
corepack pnpm -C packages/telegram build      # tsc -p tsconfig.build.json
corepack pnpm -C packages/telegram typecheck
corepack pnpm -C packages/telegram test       # node --test, no network
```

The suites run against a local `http.createServer` standing in for the Bot API.
Nothing in this package's tests reaches api.telegram.org: a suite that could
would need a token, would be flaky, and could post into somebody's chat.
