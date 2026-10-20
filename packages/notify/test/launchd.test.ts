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

test('renderPlist pins the exit-code contract: restart only after a failure, 5 minutes apart, at load, logs to the log file', () => {
  const x = renderPlist(run());
  // A clean exit (0, which is what the run verb returns for a held lock, backend none, an unsupported OS and a stop
  // signal) must not respawn the service: SuccessfulExit false means "restart only when the exit was not successful".
  // A start that throws exits 1 and is restarted, at most every 5 minutes: a crash after a long run restarts at once.
  assert.ok(/<key>KeepAlive<\/key>\s*<dict>\s*<key>SuccessfulExit<\/key>\s*<false\/>\s*<\/dict>/.test(x));
  assert.ok(/<key>ThrottleInterval<\/key>\s*<integer>300<\/integer>/.test(x));
  assert.ok(/<key>RunAtLoad<\/key>\s*<true\/>/.test(x));
  const log = '<string>/h/Library/Logs/tagents/notify.log</string>';
  assert.ok(new RegExp(`<key>StandardOutPath</key>\\s*${log}`).test(x));
  assert.ok(new RegExp(`<key>StandardErrorPath</key>\\s*${log}`).test(x));
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
  await createLaunchd({ uid: 1, label: 'L', plist: path.join(dir, 'x.plist'), exec: f.exec, retryDelayMs: 0 }).install(
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
    createLaunchd({ uid: 1, label: 'L', plist, exec: f.exec, retryDelayMs: 0 }).install(
      run({ logFile: path.join(dir, 'n.log') })
    ),
    (e: Error) => e.message.includes('Input/output error') && e.message.includes(`plutil -lint ${plist}`)
  );
  assert.equal(f.calls.filter((c) => c[1] === 'bootstrap').length, 3);
});

const BAD_BOOTSTRAP = { code: 5, stderr: 'Bootstrap failed: 5: Input/output error' };
const LABEL = 'io.github.skuratovicha.tagents-notify';
// The launchctl-print-disabled*.txt fixtures are not captures: the format is what `print-disabled` prints on
// macOS 13+ (the legacy one has `=> true`), the labels are made up. The `-enabled` one also lists a longer label that
// begins with ours as disabled, which must not count as ours.

test('install: after the retries fail for a label that print-disabled lists as disabled, the hint is launchctl enable', async () => {
  for (const out of ['launchctl-print-disabled.txt', 'launchctl-print-disabled-legacy.txt']) {
    const dir = tmpDir('launchd-disabled');
    const f = fake([{}, BAD_BOOTSTRAP, BAD_BOOTSTRAP, BAD_BOOTSTRAP, { stdout: fixture(out) }]);
    await assert.rejects(
      createLaunchd({ uid: 501, label: LABEL, plist: path.join(dir, 'x.plist'), exec: f.exec, retryDelayMs: 0 }).install(
        run({ logFile: path.join(dir, 'n.log') })
      ),
      (e: Error) =>
        e.message.includes('Input/output error') &&
        e.message.includes(`launchctl enable gui/501/${LABEL}`) &&
        e.message.includes('Login Items') &&
        !e.message.includes('plutil')
    );
    assert.deepEqual(f.calls.at(-1), ['/bin/launchctl', 'print-disabled', 'gui/501']);
  }
});

test('install: a label that is not disabled, or a print-disabled that fails, keeps the plutil hint', async () => {
  for (const second of [
    { stdout: fixture('launchctl-print-disabled-enabled.txt') },
    { code: 1, stderr: 'nope' },
    { stdout: '' },
  ]) {
    const dir = tmpDir('launchd-notdisabled');
    const plist = path.join(dir, 'x.plist');
    const f = fake([{}, BAD_BOOTSTRAP, BAD_BOOTSTRAP, BAD_BOOTSTRAP, second]);
    await assert.rejects(
      createLaunchd({ uid: 501, label: LABEL, plist, exec: f.exec, retryDelayMs: 0 }).install(
        run({ logFile: path.join(dir, 'n.log') })
      ),
      (e: Error) => e.message.includes(`plutil -lint ${plist}`) && !e.message.includes('launchctl enable')
    );
  }
});

test('install: a print-disabled that cannot even start leaves the bootstrap error and the plutil hint', async () => {
  const dir = tmpDir('launchd-printdisabled-throws');
  const plist = path.join(dir, 'x.plist');
  const answers = [{}, BAD_BOOTSTRAP, BAD_BOOTSTRAP, BAD_BOOTSTRAP];
  const exec: Exec = async (_file, args) => {
    if (args[0] === 'print-disabled') throw new Error('spawn /bin/launchctl EAGAIN');
    return { code: 0, stdout: '', stderr: '', timedOut: false, ...(answers.shift() ?? {}) };
  };
  await assert.rejects(
    createLaunchd({ uid: 501, label: LABEL, plist, exec, retryDelayMs: 0 }).install(run({ logFile: path.join(dir, 'n.log') })),
    (e: Error) => e.message.includes('Input/output error') && e.message.includes(`plutil -lint ${plist}`) && !e.message.includes('EAGAIN')
  );
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

test('parsePrint reads the top-level field when a nested block repeats its name', () => {
  const real = fixture('launchctl-print-running.txt');
  // The real output already repeats `state` one level down; hoist that block above the top-level fields as well,
  // so a match that is not anchored to the top level would find the nested value first.
  assert.ok(real.includes('\t\tstate = active\n'), 'the fixture must hold a nested state');
  const [head, ...rest] = real.split('\n');
  const nestedFirst = [
    head,
    '\tresource coalition = {',
    '\t\tstate = active',
    '\t\tpid = 1',
    '\t\tlast exit code = 99',
    '\t}',
    ...rest,
  ].join('\n');
  assert.deepEqual(parsePrint(nestedFirst), parsePrint(real));
  assert.deepEqual(parsePrint(nestedFirst), { running: true, pid: 24192, state: 'running', lastExit: '(never exited)' });
});

const ICON_ID = 'io.github.skuratovicha.tagents-notify.i0123abcd';
const BASE_ID = 'io.github.skuratovicha.tagents-notify';
const associated = (x: string): string | undefined =>
  /<key>AssociatedBundleIdentifiers<\/key>\s*<array>\s*<string>([^<]*)<\/string>/.exec(x)?.[1];

test('renderPlist writes the associated id into AssociatedBundleIdentifiers and leaves Label at the base id', () => {
  const x = renderPlist(run(), BASE_ID, ICON_ID);
  assert.equal(associated(x), ICON_ID);
  assert.ok(new RegExp(`<key>Label</key>\\s*<string>${BASE_ID}</string>`).test(x));
  assert.equal(associated(renderPlist(run())), BASE_ID);
});

async function installedPlist(app: string | undefined, plutil: Partial<ExecResult>): Promise<{ text: string; calls: (readonly string[])[] }> {
  const dir = tmpDir('launchd-appid');
  const plist = path.join(dir, 'x.plist');
  const calls: (readonly string[])[] = [];
  const exec: Exec = async (file, args) => {
    calls.push([file, ...args]);
    const r = file === '/usr/bin/plutil' ? plutil : {};
    return { code: 0, stdout: '', stderr: '', timedOut: false, ...r };
  };
  await createLaunchd({ uid: 1, plist, exec, ...(app !== undefined ? { app } : {}) }).install(
    run({ logFile: path.join(dir, 'n.log') })
  );
  return { text: fs.readFileSync(plist, 'utf8'), calls };
}

test('install with an app: AssociatedBundleIdentifiers is the id plutil reads from the built Info.plist, Label stays', async () => {
  const r = await installedPlist('/apps/N.app', { stdout: `${ICON_ID}\n` });
  assert.equal(associated(r.text), ICON_ID);
  assert.ok(new RegExp(`<key>Label</key>\\s*<string>${BASE_ID}</string>`).test(r.text));
  assert.deepEqual(r.calls.find((c) => c[0] === '/usr/bin/plutil'), [
    '/usr/bin/plutil',
    '-extract',
    'CFBundleIdentifier',
    'raw',
    '/apps/N.app/Contents/Info.plist',
  ]);
});

test('install with an app whose plutil read fails: the base id', async () => {
  const r = await installedPlist('/apps/N.app', { code: 1, stderr: 'No value at that key path' });
  assert.equal(associated(r.text), BASE_ID);
});

test('install without an app: the base id, and plutil is not asked', async () => {
  const r = await installedPlist(undefined, { stdout: `${ICON_ID}\n` });
  assert.equal(associated(r.text), BASE_ID);
  assert.ok(!r.calls.some((c) => c[0] === '/usr/bin/plutil'));
});
