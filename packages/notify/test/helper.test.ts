// node --test helper.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Exec, ExecResult } from '../src/exec.ts';
import type { Notice } from '../src/notifier.ts';
import {
  AUTHORIZE_TIMEOUT_MS,
  createHelperNotifier,
  helperAuthorize,
  helperBinary,
  helperDelivered,
  helperStatus,
} from '../src/platform/macos/helper.ts';

const APP = '/Apps/T.app';

interface Call {
  readonly file: string;
  readonly args: readonly string[];
  readonly input: string | undefined;
  readonly timeoutMs: number;
}

function fake(r: Partial<ExecResult> | Error): { exec: Exec; calls: Call[] } {
  const calls: Call[] = [];
  const exec: Exec = async (file, args, o) => {
    calls.push({ file, args, input: o.input, timeoutMs: o.timeoutMs });
    if (r instanceof Error) throw r;
    return { code: 0, stdout: '', stderr: '', timedOut: false, ...r };
  };
  return { exec, calls };
}

const notice: Notice = {
  id: 'n1',
  thread: 't',
  kind: 'turn_done',
  title: 'T',
  subtitle: 'S',
  body: 'B',
  click: { argv: ['a'], env: {} },
};

test('post sends the notice on stdin and maps shown', async () => {
  const f = fake({ stdout: '{"ok":true,"shown":true}\n' });
  const r = await createHelperNotifier({ app: APP, exec: f.exec }).post(notice);
  assert.deepEqual(r, { shown: true });
  assert.equal(f.calls[0]?.file, helperBinary(APP));
  assert.equal(helperBinary(APP), '/Apps/T.app/Contents/MacOS/tagents-notify');
  assert.deepEqual(f.calls[0]?.args, ['post']);
  assert.equal(f.calls[0]?.input, JSON.stringify(notice));
  assert.equal(f.calls[0]?.timeoutMs, 5000);
});

test('post maps why when not shown', async () => {
  const f = fake({ stdout: '{"ok":true,"shown":false,"why":"frontmost"}' });
  assert.deepEqual(await createHelperNotifier({ app: APP, exec: f.exec }).post(notice), {
    shown: false,
    why: 'frontmost',
  });
});

test('ok:false rejects with the helper error text', async () => {
  const f = fake({ code: 1, stdout: '{"ok":false,"error":"notifications are denied"}' });
  await assert.rejects(createHelperNotifier({ app: APP, exec: f.exec }).post(notice), {
    message: 'notifications are denied',
  });
});

test('a timeout rejects naming the seconds', async () => {
  const f = fake({ code: null, timedOut: true });
  await assert.rejects(createHelperNotifier({ app: APP, exec: f.exec }).withdraw('x'), {
    message: 'the notification helper timed out after 5 s',
  });
});

test('unparseable output rejects with stdout and stderr, cut at 200 characters', async () => {
  const f = fake({ stdout: 'x'.repeat(500), stderr: 'boom' });
  await assert.rejects(createHelperNotifier({ app: APP, exec: f.exec }).post(notice), (e: Error) => {
    assert.ok(e.message.includes('x'.repeat(200)));
    assert.ok(!e.message.includes('x'.repeat(201)));
    assert.ok(e.message.includes('boom'));
    return true;
  });
});

test('a missing binary names the app and the install command', async () => {
  const f = fake(new Error('spawn ENOENT'));
  await assert.rejects(helperStatus(APP, f.exec), (e: Error) => {
    assert.ok(e.message.includes(APP));
    assert.ok(e.message.includes('tagents notify install'));
    return true;
  });
});

test('withdraw passes the id as an argument', async () => {
  const f = fake({ stdout: '{"ok":true}' });
  await createHelperNotifier({ app: APP, exec: f.exec }).withdraw('abc');
  assert.deepEqual(f.calls[0]?.args, ['withdraw', 'abc']);
  assert.equal(f.calls[0]?.input, undefined);
});

test('status, delivered and authorize', async () => {
  const s = fake({ stdout: '{"alertStyle":"banner","ok":true,"status":"authorized"}' });
  assert.deepEqual(await helperStatus(APP, s.exec), { status: 'authorized', alertStyle: 'banner' });
  assert.deepEqual(s.calls[0]?.args, ['status']);

  const d = fake({ stdout: '{"ok":true,"ids":["a","b"]}' });
  assert.deepEqual(await helperDelivered(APP, d.exec), ['a', 'b']);
  assert.deepEqual(d.calls[0]?.args, ['delivered']);

  const a = fake({ stdout: '{"ok":true,"status":"denied"}' });
  assert.equal(await helperAuthorize(APP, a.exec), 'denied');
  assert.deepEqual(a.calls[0]?.args, ['authorize']);
  assert.equal(a.calls[0]?.timeoutMs, 65_000);
  assert.equal(AUTHORIZE_TIMEOUT_MS, 65_000);
});

test('authorize reports its own timeout in seconds', async () => {
  const f = fake({ code: null, timedOut: true });
  await assert.rejects(helperAuthorize(APP, f.exec), {
    message: 'the notification helper timed out after 65 s',
  });
});
