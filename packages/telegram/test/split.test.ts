// The boundary rules, pinned at a small limit so each one is readable.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { TG_TEXT_LIMIT, splitMessage } from '../src/index.ts';

const A = 'a'.repeat(15);
const B = 'b'.repeat(15);

test('the default limit is the Bot API limit', () => {
  assert.equal(TG_TEXT_LIMIT, 4096);
  assert.deepEqual(splitMessage('x'.repeat(4096)), ['x'.repeat(4096)]);
  assert.equal(splitMessage('x'.repeat(4097)).length, 2);
});

test('text that fits comes back whole, trimmed, as one chunk', () => {
  assert.deepEqual(splitMessage('  hello\nthere  ', 20), ['hello\nthere']);
});

test('nothing but whitespace is no chunks at all', () => {
  assert.deepEqual(splitMessage('', 20), []);
  assert.deepEqual(splitMessage('   \n\n  ', 20), []);
});

test('a paragraph break is the first choice', () => {
  assert.deepEqual(splitMessage(`${A}\n\n${B}`, 20), [A, B]);
});

test('a line break is the second choice', () => {
  assert.deepEqual(splitMessage(`${A}\n${B}`, 20), [A, B]);
});

test('a space is the third choice', () => {
  assert.deepEqual(splitMessage(`${A} ${B}`, 20), [A, B]);
});

test('with no separator in the window it cuts at the limit', () => {
  assert.deepEqual(splitMessage('a'.repeat(30), 20), ['a'.repeat(20), 'a'.repeat(10)]);
});

test('a separator in the first half of the window is ignored', () => {
  // Honouring the space at index 2 would turn one long message into a spray of
  // short ones, so the cut is hard at the limit instead.
  const text = `ab ${'c'.repeat(25)}`;
  assert.deepEqual(splitMessage(text, 20), [`ab ${'c'.repeat(17)}`, 'c'.repeat(8)]);
  assert.equal(splitMessage(text, 20)[0]?.length, 20);
});

test('the whitespace at a seam is dropped, not carried into the next chunk', () => {
  const chunks = splitMessage(`${A}   \n\n   ${B}`, 20);
  assert.deepEqual(chunks, [A, B]);
  for (const c of chunks) assert.equal(c, c.trim());
});

test('a very long text keeps cutting until what is left fits', () => {
  const chunks = splitMessage('word '.repeat(2000));
  assert.equal(chunks.length, 3);
  for (const c of chunks) assert.ok(c.length <= TG_TEXT_LIMIT);
  assert.equal(chunks.join(' '), 'word '.repeat(2000).trim());
});
