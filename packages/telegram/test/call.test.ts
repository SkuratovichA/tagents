// The envelope and the deadline: the two things every method inherits.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { TelegramError, createTelegram } from '../src/index.ts';
import { startApi } from './helpers.ts';

test('a non-ok envelope throws the API words in the message other code greps', async () => {
  const api = await startApi(() => ({ ok: false, error_code: 400, description: 'Bad Request: message is not modified' }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await assert.rejects(
      () => tg.call('editMessageText', { chat_id: 1 }),
      (e: unknown) => {
        assert.ok(e instanceof TelegramError);
        // Byte for byte what the busano ticket agent's client has always thrown.
        assert.equal(e.message, 'editMessageText: 400 Bad Request: message is not modified');
        assert.equal(e.method, 'editMessageText');
        assert.equal(e.code, 400);
        assert.equal(e.description, 'Bad Request: message is not modified');
        assert.equal(e.name, 'TelegramError');
        return true;
      }
    );
  } finally {
    await api.close();
  }
});

test('an ok envelope returns its result, unparsed', async () => {
  const api = await startApi(() => ({ ok: true, result: { anything: [1, 2, 3] } }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    assert.deepEqual(await tg.call('getChat', { chat_id: 7 }), { anything: [1, 2, 3] });
    assert.deepEqual(api.calls, [{ method: 'getChat', body: { chat_id: 7 } }]);
  } finally {
    await api.close();
  }
});

test('a body that is not an envelope at all is a refusal naming the method', async () => {
  const api = await startApi(() => ({ raw: '{"unexpected":true}' }));
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base });
    await assert.rejects(
      () => tg.call('getMe'),
      (e: unknown) => {
        assert.ok(e instanceof TelegramError);
        assert.equal(e.message, 'getMe: undefined undefined');
        return true;
      }
    );
  } finally {
    await api.close();
  }
});

test('the token and the method make the URL, and the body is JSON', async () => {
  const api = await startApi();
  try {
    const tg = createTelegram({ token: 'SECRET', apiBase: `${api.base}/` });
    await tg.call('sendMessage', { chat_id: 1, text: 'hi' });
    assert.deepEqual(api.bodiesOf('sendMessage'), [{ chat_id: 1, text: 'hi' }]);
  } finally {
    await api.close();
  }
});

test('a call that never answers is aborted at the deadline', async () => {
  const api = await startApi(() => 'hang');
  try {
    const tg = createTelegram({ token: 'T', apiBase: api.base, timeoutMs: 60 });
    const started = Date.now();
    await assert.rejects(
      () => tg.call('getUpdates'),
      (e: unknown) => {
        // Not a TelegramError: nothing answered, so there are no API words to
        // carry. The abort text is what the runners' logs have always shown.
        assert.ok(e instanceof Error);
        assert.match(e.message, /aborted/i);
        return true;
      }
    );
    assert.ok(Date.now() - started < 5_000, 'the deadline fired, not some other timeout');
  } finally {
    await api.close();
  }
});
