// node --test log-notifier.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Notice } from '../src/notifier.ts';
import { createLogNotifier } from '../src/platform/log.ts';

const notice: Notice = {
  id: 'tagents-12',
  thread: 'sess-1',
  kind: 'turn_done',
  title: 'build',
  subtitle: 'Answer ready',
  body: 'First line',
  click: { argv: [], env: {} },
};

test('a post logs one line and reports it shown', async () => {
  const lines: string[][] = [];
  const n = createLogNotifier((...parts) => lines.push(parts));
  assert.equal(n.name, 'log');
  assert.deepEqual(await n.post(notice), { shown: true });
  assert.equal(lines.length, 1);
  const line = (lines[0] ?? []).join(' ');
  for (const part of ['tagents-12', 'turn_done', 'build', 'Answer ready', 'First line']) assert.ok(line.includes(part), part);
});

test('a withdraw logs one line with the id', async () => {
  const lines: string[][] = [];
  const n = createLogNotifier((...parts) => lines.push(parts));
  await n.withdraw('tagents-12');
  assert.equal(lines.length, 1);
  assert.ok((lines[0] ?? []).join(' ').includes('tagents-12'));
});
