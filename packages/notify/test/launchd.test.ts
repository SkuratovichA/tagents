// node --test launchd.test.ts
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { tmpDir } from '@tagents/core';
import type { Exec, ExecResult } from '../src/exec.ts';
import type { RunSpec } from '../src/notifier.ts';
import { createLaunchd, parsePrint, renderPlist } from '../src/platform/macos/launchd.ts';

const fixture = (n: string): string => fs.readFileSync(path.join(import.meta.dirname, 'fixtures', n), 'utf8');

const run = (over: Partial<RunSpec> = {}): RunSpec => ({
  program: '/usr/local/bin/node',
  args: ['/pkg/dist/main.js', 'run'],
  env: { ZED: '1', HOME: '/h', ALPHA: 'a' },
  logFile: '/h/Library/Logs/tagents/notify.log',
  ...over,
});

function fake(rs: Partial<ExecResult>[]): { exec: Exec; calls: (readonly string[])[] } {
  const calls: (readonly string[])[] = [];
  const exec: Exec = async (file, args) => {
    calls.push([file, ...args]);
    return { code: 0, stdout: '', stderr: '', timedOut: false, ...(rs.shift() ?? {}) };
  };
  return { exec, calls };
}

test('renderPlist sorts env keys and escapes & < > " \'', () => {
  const x = renderPlist(run({ args: ['/a&b/<c>/"d"/\'e\'.js'], env: { B: 'x&y', A: '<' } }));
  assert.ok(x.includes('<string>/a&amp;b/&lt;c&gt;/&quot;d&quot;/&apos;e&apos;.js</string>'));
  assert.ok(x.indexOf('<key>A</key>') < x.indexOf('<key>B</key>'));
  assert.ok(x.includes('<string>x&amp;y</string>'));
  assert.ok(!x.includes('ProcessType'));
  assert.ok(x.includes('<string>io.github.skuratovicha.tagents-notify</string>'));
});

test('renderPlist passes plutil -lint, with hostile characters', { skip: process.platform !== 'darwin' }, () => {
  const dir = tmpDir('launchd-plist');
  const f = path.join(dir, 'x.plist');
  fs.writeFileSync(f, renderPlist(run({ args: ['/a&b/<c>/main.js', 'run'], logFile: '/l&<>.log' })));
  const out = execFileSync('/usr/bin/plutil', ['-lint', f], { encoding: 'utf8' });
  assert.ok(out.includes('OK'));
});

test('install: bootout, write, bootstrap, in that order', async () => {
  const dir = tmpDir('launchd-install');
  const plist = path.join(dir, 'LaunchAgents', 'x.plist');
  const f = fake([{ code: 3, stderr: 'Boot-out failed: 3: No such process' }, {}]);
  await createLaunchd({ uid: 501, label: 'L', plist, exec: f.exec }).install(
    run({ logFile: path.join(dir, 'logs', 'n.log') })
  );
  assert.deepEqual(f.calls, [
    ['/bin/launchctl', 'bootout', 'gui/501/L'],
    ['/bin/launchctl', 'bootstrap', 'gui/501', plist],
  ]);
  assert.ok(fs.readFileSync(plist, 'utf8').includes('<string>L</string>'));
  assert.ok(fs.existsSync(path.join(dir, 'logs')));
});

test('install retries a bootstrap that fails with error 5, then succeeds', async () => {
  const dir = tmpDir('launchd-retry');
  const f = fake([{}, { code: 5, stderr: 'Bootstrap failed: 5: Input/output error' }, {}]);
  await createLaunchd({ uid: 1, label: 'L', plist: path.join(dir, 'x.plist'), exec: f.exec }).install(
    run({ logFile: path.join(dir, 'n.log') })
  );
  assert.equal(f.calls.filter((c) => c[1] === 'bootstrap').length, 2);
});

test('install gives up after 3 bootstraps and points at plutil', async () => {
  const dir = tmpDir('launchd-giveup');
  const bad = { code: 5, stderr: 'Bootstrap failed: 5: Input/output error' };
  const f = fake([{}, bad, bad, bad]);
  const plist = path.join(dir, 'x.plist');
  await assert.rejects(
    createLaunchd({ uid: 1, label: 'L', plist, exec: f.exec }).install(run({ logFile: path.join(dir, 'n.log') })),
    (e: Error) => e.message.includes('Input/output error') && e.message.includes(`plutil -lint ${plist}`)
  );
  assert.equal(f.calls.filter((c) => c[1] === 'bootstrap').length, 3);
});

test('install does not retry an error that is not error 5', async () => {
  const dir = tmpDir('launchd-noretry');
  const f = fake([{}, { code: 134, stderr: 'Bootstrap failed: 134: nope' }]);
  await assert.rejects(
    createLaunchd({ uid: 1, label: 'L', plist: path.join(dir, 'x.plist'), exec: f.exec }).install(
      run({ logFile: path.join(dir, 'n.log') })
    )
  );
  assert.equal(f.calls.filter((c) => c[1] === 'bootstrap').length, 1);
});

test('uninstall tolerates not loaded and a missing plist, and deletes the plist', async () => {
  const dir = tmpDir('launchd-uninstall');
  const plist = path.join(dir, 'x.plist');
  fs.writeFileSync(plist, 'x');
  const notLoaded = { code: 3, stderr: fixture('launchctl-bootout-not-loaded.txt') };
  await createLaunchd({ uid: 1, label: 'L', plist, exec: fake([notLoaded]).exec }).uninstall();
  assert.ok(!fs.existsSync(plist));
  await createLaunchd({ uid: 1, label: 'L', plist, exec: fake([notLoaded]).exec }).uninstall();
});

test('uninstall surfaces any other bootout failure', async () => {
  const dir = tmpDir('launchd-uninstall-bad');
  await assert.rejects(
    createLaunchd({ uid: 1, label: 'L', plist: path.join(dir, 'x.plist'), exec: fake([{ code: 1, stderr: 'denied' }]).exec }).uninstall(),
    /denied/
  );
});

test('status: the four details', async () => {
  const dir = tmpDir('launchd-status');
  const plist = path.join(dir, 'x.plist');
  const mk = (rs: Partial<ExecResult>[]) => createLaunchd({ uid: 7, label: 'L', plist, exec: fake(rs).exec });
  const notLoaded = { code: 113, stderr: fixture('launchctl-print-not-loaded.txt') };

  assert.deepEqual(await mk([notLoaded]).status(), { installed: false, running: false, detail: 'not installed' });
  fs.writeFileSync(plist, 'x');
  assert.equal((await mk([notLoaded]).status()).detail, 'installed, not loaded');
  const running = await mk([{ stdout: fixture('launchctl-print-running.txt') }]).status();
  assert.deepEqual(running, { installed: true, running: true, pid: 24192, detail: 'loaded, running, pid 24192' });
  const crashed = await mk([{ stdout: fixture('launchctl-print-not-running.txt') }]).status();
  assert.equal(crashed.detail, 'loaded, not running (last exit 1)');
  assert.equal(crashed.running, false);
  const f = fake([{}]);
  await createLaunchd({ uid: 7, label: 'L', plist, exec: f.exec }).status();
  assert.deepEqual(f.calls[0], ['/bin/launchctl', 'print', 'gui/7/L']);
});

test('parsePrint on every real fixture', () => {
  assert.deepEqual(parsePrint(fixture('launchctl-print-running.txt')), {
    running: true,
    pid: 24192,
    state: 'running',
    lastExit: '(never exited)',
  });
  assert.deepEqual(parsePrint(fixture('launchctl-print-not-running.txt')), {
    running: false,
    state: 'not running',
    lastExit: '1',
  });
  assert.deepEqual(parsePrint(fixture('launchctl-print-throttled.txt')), {
    running: false,
    state: 'spawn scheduled',
    lastExit: '1',
  });
  assert.deepEqual(parsePrint(fixture('launchctl-print-not-loaded.txt')), { running: false });
});
