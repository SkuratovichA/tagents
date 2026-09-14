// The stream-json reader: what it takes from the pipe and what it refuses to.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { StreamEvent } from '../src/driver.ts';
import { StreamReader } from '../src/stream.ts';

const feed = (chunks: string[], onEvent?: (e: StreamEvent) => void): StreamReader => {
  const r = new StreamReader(onEvent);
  for (const c of chunks) r.push(c);
  r.end();
  return r;
};

test('result event, tool uses, assistant text, session id', () => {
  const events: StreamEvent[] = [];
  const r = feed(
    [
      '{"type":"system","subtype":"init","session_id":"s"}\n',
      '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"text","text":"hi"}]}}\n',
      'not json\n',
      '{"type":"result","is_error":false,"result":"done","session_id":"s"}\n',
    ],
    (e) => events.push(e)
  );
  assert.equal(r.toolUses, 1);
  assert.equal(r.text, 'hi');
  assert.equal(r.payload?.result, 'done');
  assert.equal(r.sessionId, 's');
  assert.equal(r.sawResult, true);
  assert.deepEqual(events.map((e) => e.kind), ['other', 'tool_use', 'text', 'result']);
});

test('a line split across chunks is still one event', () => {
  const r = feed(['{"type":"res', 'ult","is_error":false,', '"result":"done","session_id":"s"}\n']);
  assert.equal(r.payload?.result, 'done');
  assert.equal(r.sessionId, 's');
});

test('the last line needs no trailing newline', () => {
  const r = feed(['{"type":"result","is_error":false,"result":"done"}']);
  assert.equal(r.payload?.result, 'done');
});

test('noise, banners and half-written lines are skipped, not fatal', () => {
  const r = feed(['warming up\n', '{"type":"assistant"\n', '{"nope}\n', '{"type":"result","is_error":true,"result":"boom"}\n']);
  assert.equal(r.payload?.is_error, true);
  assert.equal(r.toolUses, 0);
});

test('plain --output-format json (one object, no type) is a result too', () => {
  const events: StreamEvent[] = [];
  const r = feed(['{"is_error":false,"result":"legacy","session_id":"s"}\n'], (e) => events.push(e));
  assert.equal(r.payload?.result, 'legacy');
  assert.equal(r.sawResult, true);
  assert.deepEqual(events, [
    { kind: 'result', isError: false, payload: { is_error: false, result: 'legacy', session_id: 's' } },
  ]);
});

test('the result event carries the payload with the fields core does not model', () => {
  const events: StreamEvent[] = [];
  feed(
    [
      '{"type":"result","is_error":false,"result":"ok","session_id":"s","num_turns":3,' +
        '"modelUsage":{"claude-opus-5":{"inputTokens":10,"outputTokens":2}}}\n',
    ],
    (e) => events.push(e)
  );
  const [e] = events;
  assert.ok(e && e.kind === 'result');
  if (!e || e.kind !== 'result') return;
  // A consumer's ledger wants modelUsage and num_turns; core keeps them instead of stripping them.
  assert.equal(e.payload.num_turns, 3);
  assert.deepEqual(e.payload['modelUsage'], { 'claude-opus-5': { inputTokens: 10, outputTokens: 2 } });
});

test('a listener that throws cannot fail the turn it is watching', () => {
  const r = feed(['{"type":"result","is_error":false,"result":"done"}\n'], () => {
    throw new Error('listener blew up');
  });
  assert.equal(r.payload?.result, 'done');
});

test('nothing at all is a reader with nothing in it', () => {
  const r = feed([]);
  assert.equal(r.payload, null);
  assert.equal(r.sessionId, null);
  assert.equal(r.sawResult, false);
});
