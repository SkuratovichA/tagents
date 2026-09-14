// What each method puts on the wire.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createTelegram } from '../src/index.ts';
import { startApi } from './helpers.ts';

test('getUpdates sends Telegram field names and parses the batch', async () => {
  const api = await startApi(() => ({
    ok: true,
    result: [
      { update_id: 10, message: { message_id: 1, chat: { id: 5, type: 'private' }, text: 'hi', date: 1 } },
      { update_id: 11, message: 'not a message' },
      { update_id: 12 },
    ],
  }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    const updates = await tg.getUpdates({ offset: 11, timeoutS: 1, allowedUpdates: ['message'] });
    assert.deepEqual(api.bodiesOf('getUpdates'), [{ offset: 11, timeout: 1, allowed_updates: ['message'] }]);
    assert.deepEqual(
      updates.map((u) => u.update_id),
      [10, 11, 12]
    );
    assert.equal(updates[0]?.message?.text, 'hi');
    // A message that does not parse is dropped, the update it came on is not:
    // the offset still has to move past it.
    assert.equal(updates[1]?.message, undefined);
  } finally {
    await api.close();
  }
});

test('getUpdates gives the HTTP deadline 15 s more than its long-poll window', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const seen: { body: unknown; signal: AbortSignal | null } = { body: null, signal: null };
  const never: typeof fetch = (_input, init) => {
    seen.body = JSON.parse(String(init?.body));
    seen.signal = init?.signal ?? null;
    return new Promise<Response>(() => undefined);
  };
  const tg = createTelegram({ token: 'T', fetch: never, timeoutMs: 30_000 });
  void tg.getUpdates({ offset: 1, timeoutS: 3 }).catch(() => undefined);

  assert.deepEqual(seen.body, { offset: 1, timeout: 3 });
  const signal = seen.signal;
  assert.ok(signal !== null);
  // 3 s of long poll + 15 s of slack, and NOT the client's own 30 s default.
  assert.equal(signal.aborted, false);
  t.mock.timers.tick(17_999);
  assert.equal(signal.aborted, false);
  t.mock.timers.tick(1);
  assert.equal(signal.aborted, true);
});

test('getMe parses the bot user', async () => {
  const api = await startApi(() => ({ ok: true, result: { id: 42, is_bot: true, username: 'a_bot' } }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    const me = await tg.getMe();
    assert.equal(me.username, 'a_bot');
    assert.equal(me.id, 42);
    assert.deepEqual(api.bodiesOf('getMe'), [{}]);
  } finally {
    await api.close();
  }
});

test('sendMessage maps every option to its Bot API field', async () => {
  const api = await startApi();
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await tg.sendMessage(-100, 'body', {
      threadId: 9,
      replyTo: 77,
      parseMode: 'HTML',
      disablePreview: true,
    });
    assert.deepEqual(api.bodiesOf('sendMessage'), [
      {
        chat_id: -100,
        text: 'body',
        message_thread_id: 9,
        reply_parameters: { message_id: 77, allow_sending_without_reply: true },
        parse_mode: 'HTML',
        link_preview_options: { is_disabled: true },
      },
    ]);
  } finally {
    await api.close();
  }
});

test('sendMessage sends nothing it was not given', async () => {
  const api = await startApi();
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await tg.sendMessage(1, 'plain');
    assert.deepEqual(api.bodiesOf('sendMessage'), [{ chat_id: 1, text: 'plain' }]);
  } finally {
    await api.close();
  }
});

test('setMessageReaction sends the one-emoji array the Bot API wants', async () => {
  const api = await startApi(() => ({ ok: true, result: true }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await tg.setMessageReaction(5, 123, '\u{1F440}');
    assert.deepEqual(api.bodiesOf('setMessageReaction'), [
      { chat_id: 5, message_id: 123, reaction: [{ type: 'emoji', emoji: '\u{1F440}' }] },
    ]);
  } finally {
    await api.close();
  }
});

test('editMessageText addresses the message and carries the text options', async () => {
  const api = await startApi(() => ({ ok: true, result: true }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    const out = await tg.editMessageText(-100, 500, 'next', { disablePreview: true });
    assert.equal(out, true);
    assert.deepEqual(api.bodiesOf('editMessageText'), [
      { chat_id: -100, message_id: 500, text: 'next', link_preview_options: { is_disabled: true } },
    ]);
  } finally {
    await api.close();
  }
});
