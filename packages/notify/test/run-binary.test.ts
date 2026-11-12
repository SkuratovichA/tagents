// node --test run-binary.test.ts
//
// `notify run` as node answers it: it starts the Rust binary with the same stdio, passes SIGTERM and SIGINT on, returns the binary's exit code, or says there is no binary and exits 69. Stub binaries are shell scripts in a temp directory.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { tmpDir } from '@tagents/core';
import { FROM_NODE, NO_BINARY, runBinary } from '../src/run-binary.ts';

function stub(body: string): string {
  const file = path.join(tmpDir('notify-run-binary'), 'tagents-core');
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
}

test('no binary: the needs-binary line naming tagents update and cargo build, and exit 69', async () => {
  const lines: string[] = [];
  const code = await runBinary({ bin: path.join(tmpDir('notify-run-binary'), 'absent'), err: (t) => lines.push(t) });
  assert.equal(code, NO_BINARY);
  assert.equal(NO_BINARY, 69);
  assert.equal(lines.length, 1);
  assert.match(lines[0] ?? '', /^notify run is served by the tagents-core binary.*`tagents update`.*cargo build --release -p tagents-core` in the checkout\n$/);
});

test('the binary gets `notify run` and the environment, and its exit code is the answer', async () => {
  const out = path.join(tmpDir('notify-run-binary'), 'args');
  const bin = stub(`echo "$@ $PROBE" > "${out}"; exit 7`);
  assert.equal(await runBinary({ bin, env: { ...process.env, PROBE: 'seen' } }), 7);
  assert.equal(fs.readFileSync(out, 'utf8'), 'notify run seen\n');
});

test('a SIGTERM to node reaches the binary, which ends the run with its own word', async () => {
  const ready = path.join(tmpDir('notify-run-binary'), 'ready');
  const bin = stub(`trap 'exit 0' TERM; : > "${ready}"; while :; do sleep 0.05; done`);
  const done = runBinary({ bin });
  for (let n = 0; n < 500 && !fs.existsSync(ready); n += 1) await new Promise<void>((r) => setTimeout(r, 20));
  assert.ok(fs.existsSync(ready), 'the stub started');
  process.emit('SIGTERM');
  assert.equal(await done, 0);
});

test('a SIGINT to node reaches the binary too', async () => {
  const ready = path.join(tmpDir('notify-run-binary'), 'ready');
  const bin = stub(`trap 'exit 3' INT; : > "${ready}"; while :; do sleep 0.05; done`);
  const done = runBinary({ bin });
  for (let n = 0; n < 500 && !fs.existsSync(ready); n += 1) await new Promise<void>((r) => setTimeout(r, 20));
  assert.ok(fs.existsSync(ready), 'the stub started');
  process.emit('SIGINT');
  assert.equal(await done, 3);
});

test('the binary is started with the recursion guard in its environment', async () => {
  const out = path.join(tmpDir('notify-run-binary'), 'guard');
  const bin = stub(`echo "$${FROM_NODE}" > "${out}"`);
  assert.equal(await runBinary({ bin, env: { ...process.env, [FROM_NODE]: '' } }), 0);
  assert.equal(fs.readFileSync(out, 'utf8'), '1\n');
});

test('already started by the binary: node does not start it again, says there is no usable binary and exits 69', async () => {
  const out = path.join(tmpDir('notify-run-binary'), 'started');
  const bin = stub(`: > "${out}"`);
  const lines: string[] = [];
  assert.equal(await runBinary({ bin, env: { ...process.env, [FROM_NODE]: '1' }, err: (t) => lines.push(t) }), NO_BINARY);
  assert.equal(fs.existsSync(out), false);
  assert.match(lines.join(''), /^notify run is served by the tagents-core binary/);
});

test('a binary that a signal ended without its own word is exit 1, which launchd starts again', async () => {
  const bin = stub('kill -KILL $$');
  assert.equal(await runBinary({ bin }), 1);
});
