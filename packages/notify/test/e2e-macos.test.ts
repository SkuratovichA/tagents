// TA_NOTIFY_E2E=1 node --test e2e-macos.test.ts
//
// The installed app, for real: it posts a banner that shows on the screen for a
// few seconds. Skipped unless asked for, and off macOS.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Notice } from '../src/notifier.ts';
import { appPath } from '../src/paths.ts';
import { createHelperNotifier, helperDelivered, helperStatus } from '../src/platform/macos/helper.ts';

const skip = process.env['TA_NOTIFY_E2E'] !== '1' || process.platform !== 'darwin';

test('post, delivered, withdraw on the installed app', { skip }, async () => {
  const app = appPath();
  assert.equal((await helperStatus(app)).status, 'authorized');

  const id = `tagents-e2e-${process.pid}`;
  const notice: Notice = {
    id,
    thread: 'tagents-e2e',
    kind: 'turn_done',
    title: 'tagents e2e',
    subtitle: 'notify',
    body: 'a test notice; it withdraws itself',
    click: { argv: [], env: {} },
  };
  const n = createHelperNotifier({ app });
  assert.equal((await n.post(notice)).shown, true);
  try {
    assert.ok((await helperDelivered(app)).includes(id));
  } finally {
    await n.withdraw(id);
  }
  assert.ok(!(await helperDelivered(app)).includes(id));
});
