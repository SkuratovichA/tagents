// node --test clock.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { sleep } from '@tagents/core';
import { systemClock } from '../src/clock.ts';

test('now is the wall clock', () => {
  const before = Date.now();
  const n = systemClock.now();
  assert.ok(n >= before && n <= Date.now());
});

test('after runs the callback once, and its cancel function stops it', async () => {
  let ran = 0;
  systemClock.after(10, () => ran++);
  const cancel = systemClock.after(10, () => ran += 100);
  cancel();
  await sleep(80);
  assert.equal(ran, 1);
});
