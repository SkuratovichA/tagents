// node --test platform.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Exec } from '../src/exec.ts';
import type { NotifyOptions } from '../src/options.ts';
import { pickPlatform } from '../src/platform/index.ts';

const log = (): void => {};
const backends: NotifyOptions['backend'][] = ['auto', 'macos', 'log', 'none'];

test('the matrix: darwin and linux against the four backends', () => {
  const name = (os: NodeJS.Platform, b: NotifyOptions['backend']): string | null =>
    pickPlatform(os, b, { log })?.name ?? null;
  const got = Object.fromEntries(
    (['darwin', 'linux'] as const).flatMap((os) => backends.map((b) => [`${os}/${b}`, name(os, b)]))
  );
  assert.deepEqual(got, {
    'darwin/auto': 'macos',
    'darwin/macos': 'macos',
    'darwin/log': 'log',
    'darwin/none': null,
    'linux/auto': 'unsupported',
    'linux/macos': 'unsupported',
    'linux/log': 'log',
    'linux/none': null,
  });
});

test('services: launchd on darwin only', () => {
  assert.notEqual(pickPlatform('darwin', 'macos', { log })?.service, null);
  assert.notEqual(pickPlatform('darwin', 'log', { log })?.service, null);
  assert.equal(pickPlatform('linux', 'log', { log })?.service, null);
  assert.equal(pickPlatform('linux', 'auto', { log })?.service, null);
});

test('unsupported refuses to post', async () => {
  const p = pickPlatform('linux', 'auto', { log });
  await assert.rejects(p?.notifier.withdraw('x') ?? Promise.resolve(), {
    message: 'no notification backend for linux yet',
  });
});

test('the macOS platform: permission asks the helper, setup builds only when not up to date', async () => {
  const calls: string[] = [];
  let state = 'stale';
  const exec: Exec = async (file, args) => {
    calls.push(`${file.split('/').pop()} ${args.join(' ')}`.replace(/\/\S*build\.sh/, 'BUILD'));
    if (args.includes('--check')) return { code: 1, stdout: state, stderr: '', timedOut: false };
    if (args.includes('authorize')) return { code: 0, stdout: '{"ok":true,"status":"authorized"}', stderr: '', timedOut: false };
    if (args.includes('status')) return { code: 0, stdout: '{"ok":true,"status":"denied","alertStyle":"none"}', stderr: '', timedOut: false };
    return { code: 0, stdout: '', stderr: '', timedOut: false };
  };
  const p = pickPlatform('darwin', 'macos', { log, exec, env: { TA_NOTIFY_APP: '/A.app' }, home: '/h', uid: 1 });
  assert.equal(await p?.permission?.(), 'denied');
  assert.equal(await p?.setup?.(log), 'authorized');
  assert.ok(calls.some((c) => c.startsWith('sh BUILD /A.app')));
  calls.length = 0;
  state = 'up to date';
  await p?.setup?.(log);
  assert.ok(!calls.some((c) => c === 'sh BUILD /A.app'));
});
