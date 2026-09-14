// "typing…" stays on for as long as the work takes.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { TYPING_INTERVAL_MS, createTelegram } from '../src/index.ts';
import { settle, stubFetch } from './helpers.ts';

test('the typing action is sent before fn runs, and re-sent while it runs', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const stub = stubFetch(true);
  const tg = createTelegram({ token: 'T', fetch: stub.fetch });

  let release = (): void => undefined;
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  let seenAtStart: string[] = [];
  const work = tg.withTyping(5, 7, async () => {
    seenAtStart = [...stub.methods];
    await held;
    return 'done';
  });

  // Telegram drops the indicator after about 5 s, so it is re-sent every 4 s.
  assert.deepEqual(seenAtStart, ['sendChatAction']);
  await settle();
  t.mock.timers.tick(TYPING_INTERVAL_MS);
  await settle();
  t.mock.timers.tick(TYPING_INTERVAL_MS);
  await settle();
  assert.deepEqual(stub.methods, ['sendChatAction', 'sendChatAction', 'sendChatAction']);

  release();
  assert.equal(await work, 'done');

  // The interval is cleared with the work, not left ticking into the next turn.
  t.mock.timers.tick(TYPING_INTERVAL_MS * 3);
  await settle();
  assert.equal(stub.methods.length, 3);
});

test('the typing action names the chat and the topic', async () => {
  const bodies: unknown[] = [];
  const tg = createTelegram({
    token: 'T',
    fetch: (_input, init) => {
      bodies.push(JSON.parse(String(init?.body)));
      return Promise.resolve(new Response('{"ok":true,"result":true}'));
    },
  });
  await tg.withTyping(5, 7, () => Promise.resolve(null));
  await tg.withTyping(5, undefined, () => Promise.resolve(null));
  assert.deepEqual(bodies, [
    { chat_id: 5, action: 'typing', message_thread_id: 7 },
    { chat_id: 5, action: 'typing' },
  ]);
});

test('a chat that refuses the action does not take the work down with it', async () => {
  const tg = createTelegram({
    token: 'T',
    fetch: () =>
      Promise.resolve(new Response('{"ok":false,"error_code":400,"description":"Bad Request: CHAT_WRITE_FORBIDDEN"}')),
  });
  assert.equal(await tg.withTyping(5, undefined, () => Promise.resolve('work happened')), 'work happened');
});
