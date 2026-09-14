// The path a long answer takes: split first, then one request per chunk.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createTelegram, splitMessage } from '../src/index.ts';
import { startApi } from './helpers.ts';

/** A Bot API that hands back a different message id every time. */
function counting(): Parameters<typeof startApi>[0] {
  let n = 0;
  return () => ({ ok: true, result: { message_id: (n += 1), chat: { id: 1 } } });
}

function textsOf(bodies: Record<string, unknown>[]): string[] {
  return bodies.map((b) => String(b['text']));
}

test('a 10 000-character answer arrives as three requests, in order, none over the limit', async () => {
  const api = await startApi(counting());
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    const text = 'word '.repeat(2000);
    const sent = await tg.sendText(42, text);

    const bodies = api.bodiesOf('sendMessage');
    assert.equal(bodies.length, 3);
    assert.equal(api.calls.length, 3, 'nothing else was called');
    const texts = textsOf(bodies);
    // The same boundaries splitMessage promises, not a second chunker.
    assert.deepEqual(texts, splitMessage(text));
    // Cut on the last space that falls in the window, which for this text is at
    // 4094 both times; the space itself is dropped at the seam.
    assert.deepEqual(
      texts.map((t) => t.length),
      [4094, 4094, 1809]
    );
    for (const t of texts) assert.ok(t.length <= 4096, `chunk of ${t.length} chars`);
    assert.equal(texts.join(' '), text.trim(), 'the answer is whole, only re-seamed');
    // In order, and every reply came back.
    assert.deepEqual(
      sent.map((m) => m.message_id),
      [1, 2, 3]
    );
    assert.deepEqual(
      bodies.map((b) => b['chat_id']),
      [42, 42, 42]
    );
  } finally {
    await api.close();
  }
});

test('a short answer is one request and is not re-wrapped', async () => {
  const api = await startApi(counting());
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await tg.sendText(1, '  two lines\nsecond  ', { threadId: 4 });
    assert.deepEqual(api.bodiesOf('sendMessage'), [
      { chat_id: 1, text: 'two lines\nsecond', message_thread_id: 4 },
    ]);
  } finally {
    await api.close();
  }
});

test('the reply arrow goes on the first chunk only', async () => {
  const api = await startApi(counting());
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await tg.sendText(1, 'word '.repeat(2000), { replyTo: 99, threadId: 4 });
    const bodies = api.bodiesOf('sendMessage');
    assert.equal(bodies.length, 3);
    assert.deepEqual(bodies[0]?.['reply_parameters'], { message_id: 99, allow_sending_without_reply: true });
    assert.equal(bodies[1]?.['reply_parameters'], undefined);
    assert.equal(bodies[2]?.['reply_parameters'], undefined);
    // Everything else rides on every chunk.
    for (const b of bodies) assert.equal(b['message_thread_id'], 4);
  } finally {
    await api.close();
  }
});

test('an empty answer sends nothing at all', async () => {
  const api = await startApi(counting());
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    assert.deepEqual(await tg.sendText(1, '   \n  '), []);
    assert.deepEqual(api.calls, []);
  } finally {
    await api.close();
  }
});
