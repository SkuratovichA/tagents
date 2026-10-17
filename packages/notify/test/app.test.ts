// node --test app.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execText, type Exec, type ExecResult } from '../src/exec.ts';
import { BUILD_SCRIPT } from '../src/paths.ts';
import { appState, buildApp } from '../src/platform/macos/app.ts';

function fake(rs: Partial<ExecResult>[]): { exec: Exec; calls: (readonly string[])[] } {
  const calls: (readonly string[])[] = [];
  const exec: Exec = async (file, args) => {
    calls.push([file, ...args]);
    return { code: 0, stdout: '', stderr: '', timedOut: false, ...(rs.shift() ?? {}) };
  };
  return { exec, calls };
}

test('appState maps the three outputs and runs the script through /bin/sh', async () => {
  for (const s of ['up to date', 'stale', 'missing'] as const) {
    const f = fake([{ stdout: `${s}\n`, code: s === 'up to date' ? 0 : 1 }]);
    assert.equal(await appState('/A.app', undefined, f.exec), s);
    assert.deepEqual(f.calls[0], ['/bin/sh', BUILD_SCRIPT, '--check', '/A.app']);
  }
  await assert.rejects(appState('/A.app', undefined, fake([{ stdout: 'huh', code: 2 }]).exec));
});

test('the real script says missing, exit 1, for an app that is not there', async () => {
  const r = await execText('/bin/sh', [BUILD_SCRIPT, '--check', '/nonexistent/X.app'], { timeoutMs: 10_000 });
  assert.equal(r.stdout.trim(), 'missing');
  assert.equal(r.code, 1);
});

test('buildApp logs first and succeeds on exit 0', async () => {
  const lines: string[] = [];
  const f = fake([{}]);
  await buildApp('/A.app', undefined, (...p) => lines.push(p.join(' ')), f.exec);
  assert.equal(lines.length, 1);
  assert.deepEqual(f.calls[0], ['/bin/sh', BUILD_SCRIPT, '/A.app']);
});

test('buildApp rejects with the last 20 lines of stderr and a swiftc hint', async () => {
  const stderr = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join('\n');
  const f = fake([{ code: 1, stderr }, { code: 1 }]);
  await assert.rejects(buildApp('/A.app', undefined, () => {}, f.exec), (e: Error) => {
    assert.ok(e.message.includes('line 30') && e.message.includes('line 11'));
    assert.ok(!e.message.includes('line 10\n'));
    assert.ok(e.message.includes('xcode-select --install'));
    return true;
  });
  assert.deepEqual(f.calls[1], ['/usr/bin/xcrun', '--find', 'swiftc']);
});

test('buildApp gives no swiftc hint when swiftc exists', async () => {
  const f = fake([{ code: 1, stderr: 'oops' }, { code: 0 }]);
  await assert.rejects(buildApp('/A.app', undefined, () => {}, f.exec), (e: Error) => !e.message.includes('xcode-select'));
});
