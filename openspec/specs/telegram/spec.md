# telegram Specification

## Purpose
A small typed Telegram Bot API client shared by every plugin that has a bot token: one way to call a method, read updates, send long text safely, and see the API's refusals. It never speaks to a person; what a bot says belongs to the bot.

## Requirements

### Requirement: Client construction
The package SHALL provide `createTelegram` that returns a client bound to one bot token. Options are `token` (required), `apiBase` (default `https://api.telegram.org`, trailing slashes tolerated), `fetch` (default the global fetch; injectable for tests, proxies or retrying fetches) and `timeoutMs` (default 30000). The client SHALL expose `call`, `getMe`, `getUpdates`, `sendMessage`, `sendText`, `setMessageReaction`, `editMessageText` and `withTyping`.

#### Scenario: Custom API host
- **WHEN** a client is created with `apiBase` pointing at a local Bot API server, with or without a trailing slash
- **THEN** calls go to `<apiBase>/bot<token>/<method>`

### Requirement: Generic call
`call(method, params?, { timeoutMs? })` SHALL POST the params as a JSON body with `content-type: application/json` to `<apiBase>/bot<token>/<method>` and, when the envelope has `ok: true`, resolve with the envelope's `result` unparsed. With no params the body is `{}`.

#### Scenario: Result is passed through
- **WHEN** the API answers `{"ok": true, "result": {"anything": [1, 2, 3]}}` to `call('getChat', { chat_id: 7 })`
- **THEN** the promise resolves with `{ anything: [1, 2, 3] }` and exactly one request `getChat` with body `{ chat_id: 7 }` was made

### Requirement: Errors carry the API's own words
When the envelope is not ok, the call SHALL reject with a `TelegramError` whose `method` is the called method, whose `code` is the envelope's `error_code`, whose `description` is the envelope's `description`, whose `name` is `TelegramError`, and whose message is exactly `<method>: <code> <description>`. Callers match Telegram's own wording inside that message, so the format is a contract.

#### Scenario: Refusal
- **WHEN** the API answers `{"ok": false, "error_code": 400, "description": "Bad Request: message is not modified"}` to `editMessageText`
- **THEN** the rejection is a `TelegramError` with message `editMessageText: 400 Bad Request: message is not modified`, `code` 400 and that `description`

### Requirement: Malformed response bodies
A response body that is valid JSON but not a Bot API envelope (for example an object without `ok`) SHALL be treated as a refusal naming the method, not as a parse crash: the call rejects with a `TelegramError` whose message is `<method>: undefined undefined`.

#### Scenario: Body is not an envelope
- **WHEN** the server answers `{"unexpected": true}` to `getMe`
- **THEN** the rejection is a `TelegramError` with message `getMe: undefined undefined`

### Requirement: Deadline aborts the request
Every call SHALL be given a deadline, `timeoutMs` of the client or of the call (default 30 seconds), after which the underlying request is aborted. A request that times out SHALL reject with an ordinary abort error (not a `TelegramError`, since nothing answered), and the timer SHALL be cleared once the call settles.

#### Scenario: Server never answers
- **WHEN** a client with `timeoutMs: 60` calls a server that never replies
- **THEN** the call rejects within a few seconds with an error whose message mentions the abort, and it is not a `TelegramError`

### Requirement: Long-poll updates
`getUpdates({ offset, timeoutS, allowedUpdates? })` SHALL send `offset`, `timeout` (the long-poll window in seconds) and, when given, `allowed_updates`, and resolve with the parsed updates. Its deadline SHALL be `timeoutS` seconds plus 15 seconds, regardless of the client's default, so a healthy long poll is never aborted.

#### Scenario: Wire format
- **WHEN** `getUpdates({ offset: 11, timeoutS: 1, allowedUpdates: ['message'] })` is called
- **THEN** the body is `{ offset: 11, timeout: 1, allowed_updates: ['message'] }`

#### Scenario: Deadline slack
- **WHEN** `getUpdates({ offset: 1, timeoutS: 3 })` is called on a client whose default timeout is 30 seconds
- **THEN** the request is aborted after 18 seconds, not before and not at 30

### Requirement: Updates are parsed leniently
Each update SHALL expose its `update_id` and, when it has one that parses, its `message`; unknown fields SHALL be preserved. A message that fails to parse SHALL become `undefined` while its update stays in the batch, so a caller can still move its offset past it, and a result that is not an array SHALL read as an empty batch.

#### Scenario: Bad message does not drop the update
- **WHEN** the API returns updates 10 (valid message), 11 (message is a string) and 12 (no message)
- **THEN** all three updates are returned, update 10 has its text, and updates 11 and 12 have no message

### Requirement: Message fields
A parsed message SHALL have `message_id` and `chat.id`, and MAY carry `chat.type`, `chat.title`, `message_thread_id`, `from.id`, `text`, `caption`, `voice`, `video_note`, `photo`, `document`, `reply_to_message`, `date` and `edit_date` (Unix seconds); fields it does not know SHALL be preserved.

#### Scenario: Edited message
- **WHEN** a message carries `edit_date`
- **THEN** the parsed message exposes it

### Requirement: Bot identity
`getMe()` SHALL call `getMe` with an empty body and resolve with the bot user, whose fields `id`, `is_bot`, `username` and `first_name` are optional; a result that does not parse reads as an empty object.

#### Scenario: Bot user
- **WHEN** the API answers with `{ id: 42, is_bot: true, username: 'a_bot' }`
- **THEN** `getMe()` resolves with that id and username and the request body was `{}`

### Requirement: Sending one message
`sendMessage(chatId, text, opts?)` SHALL call `sendMessage` with `chat_id` and `text` and resolve with the sent message. A field SHALL be sent only when its option was given.

#### Scenario: Nothing extra
- **WHEN** `sendMessage(1, 'plain')` is called
- **THEN** the body is exactly `{ chat_id: 1, text: 'plain' }`

### Requirement: Send options
The text options `threadId`, `replyTo`, `parseMode` (`HTML`, `Markdown` or `MarkdownV2`) and `disablePreview` SHALL map to `message_thread_id`, `reply_parameters` (`{ message_id, allow_sending_without_reply: true }`, so the send succeeds even if the replied-to message is gone), `parse_mode` and `link_preview_options.is_disabled`.

#### Scenario: All options
- **WHEN** `sendMessage(-100, 'body', { threadId: 9, replyTo: 77, parseMode: 'HTML', disablePreview: true })` is called
- **THEN** the body holds `chat_id`, `text`, `message_thread_id: 9`, `reply_parameters: { message_id: 77, allow_sending_without_reply: true }`, `parse_mode: 'HTML'` and `link_preview_options: { is_disabled: true }`

### Requirement: Splitting long text
`splitMessage(text, limit = 4096)` SHALL trim the text and cut it into chunks of at most `limit` characters (Telegram's 4096-character ceiling for one message). Each cut SHALL prefer the last blank line within the limit, then the last line break, then the last space, ignoring a separator in the first half of the window, and with none usable the cut is hard at the limit. Whitespace at a seam SHALL be dropped from both neighbours. Empty or all-whitespace text yields no chunks.

#### Scenario: Boundary preference
- **WHEN** two 15-character blocks are joined by a blank line, a single newline, or a space, with limit 20
- **THEN** the result is the two blocks in each case

#### Scenario: Hard cut
- **WHEN** 30 characters without separators are split with limit 20
- **THEN** the chunks are 20 and 10 characters

#### Scenario: Early separator ignored
- **WHEN** `ab ` is followed by 25 `c` characters and the limit is 20
- **THEN** the first chunk is 20 characters, not `ab`

#### Scenario: Nothing to send
- **WHEN** the text is empty or only whitespace
- **THEN** no chunks are returned

#### Scenario: Exactly at the limit
- **WHEN** a text of 4096 characters is split with the default limit
- **THEN** it is one chunk, and 4097 characters give two

### Requirement: Sending long text
`sendText(chatId, text, opts?)` SHALL send the chunks of `splitMessage(text)` one request each, strictly in order, with the same options on every chunk, except that `replyTo` SHALL apply to the first chunk only. It SHALL resolve with the sent messages in order. Text that yields no chunks SHALL send nothing and resolve with an empty array. A failed send rejects the call; it is not swallowed.

#### Scenario: Three chunks
- **WHEN** `sendText(42, 'word '.repeat(2000))` is called
- **THEN** exactly three `sendMessage` requests are made, in order, none longer than 4096 characters, and the three returned messages are in that order

#### Scenario: Reply arrow on the first chunk only
- **WHEN** `sendText(1, longText, { replyTo: 99, threadId: 4 })` is called
- **THEN** only the first request has `reply_parameters`, and every request has `message_thread_id: 4`

#### Scenario: Empty answer
- **WHEN** `sendText(1, '   \n  ')` is called
- **THEN** no request is made and the result is `[]`

### Requirement: Reactions
`setMessageReaction(chatId, messageId, emoji)` SHALL call `setMessageReaction` with `chat_id`, `message_id` and `reaction: [{ type: 'emoji', emoji }]`.

#### Scenario: One emoji
- **WHEN** `setMessageReaction(5, 123, '👀')` is called
- **THEN** the body is `{ chat_id: 5, message_id: 123, reaction: [{ type: 'emoji', emoji: '👀' }] }`

### Requirement: Editing text
`editMessageText(chatId, messageId, text, opts?)` SHALL call `editMessageText` with `chat_id`, `message_id`, `text` and the same option mapping as `sendMessage`, and resolve with the API's result unparsed (the edited message, or `true` for an inline message).

#### Scenario: Edit with options
- **WHEN** `editMessageText(-100, 500, 'next', { disablePreview: true })` is called and the API answers `true`
- **THEN** the body is `{ chat_id: -100, message_id: 500, text: 'next', link_preview_options: { is_disabled: true } }` and the call resolves with `true`

### Requirement: Typing indicator
`withTyping(chatId, threadId, fn)` SHALL send a `sendChatAction` with `action: 'typing'` (and `message_thread_id` when a thread id is given) before running `fn`, re-send it every 4 seconds while `fn` runs, stop re-sending once `fn` settles, and resolve or reject exactly as `fn` does. A failure to send the action, such as a chat that forbids it, SHALL be ignored and SHALL NOT affect `fn`.

#### Scenario: Re-sent while working
- **WHEN** `fn` runs for more than 8 seconds
- **THEN** three `sendChatAction` requests were made in total, and none after `fn` finished

#### Scenario: Topic named
- **WHEN** `withTyping(5, 7, …)` and `withTyping(5, undefined, …)` run
- **THEN** the bodies are `{ chat_id: 5, action: 'typing', message_thread_id: 7 }` and `{ chat_id: 5, action: 'typing' }`

#### Scenario: Refused action
- **WHEN** the API answers `CHAT_WRITE_FORBIDDEN` to the typing action
- **THEN** `fn` still runs and its result is returned
