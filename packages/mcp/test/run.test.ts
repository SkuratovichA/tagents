// node --test run.test.ts
//
// A call is a child process: the program looked up on PATH, no stdin, its exit code named by the program's own table. The programs here are shell scripts written into a temporary directory that is the whole PATH, so nothing of the machine can answer.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, test } from 'node:test';
import { MAX_STREAM, callTool, resultText } from '../src/run.ts';
import { fakeTool as tool, rig, stopRigs } from './rig.ts';

afterEach(stopRigs);

test('a zero exit with JSON on stdout is an ok result holding the parsed document', async () => {
  const { env } = rig(`printf '{"a":[1,2]}\\n'`);
  const r = await callTool(tool('fake_echo'), {}, { env, timeoutMs: 5000 });
  assert.equal(r.isError, false);
  assert.deepEqual(JSON.parse(resultText(r)), { exit: 0, outcome: 'ok', stdout: { a: [1, 2] }, stderr: '' });
});

test('stdout that is not JSON stays text, even when it looks like a number', async () => {
  const { env } = rig(`printf '42\\n'`);
  const r = await callTool(tool('fake_echo'), {}, { env, timeoutMs: 5000 });
  assert.equal(JSON.parse(resultText(r)).stdout, '42\n');
});

test('the arguments reach the program as the verb words, flags and positionals', async () => {
  const { env } = rig(`printf '%s|' "$@"`);
  const r = await callTool(tool('fake_echo'), { loud: true, text: 'hi' }, { env, timeoutMs: 5000 });
  assert.equal(JSON.parse(resultText(r)).stdout, 'echo|--loud|hi|');
});

test('a non-zero exit is an error result that names the exit by the program table and carries stderr', async () => {
  const { env } = rig(`echo "nothing done" >&2; exit 3`);
  const r = await callTool(tool('fake_echo'), {}, { env, timeoutMs: 5000 });
  assert.equal(r.isError, true);
  assert.deepEqual(JSON.parse(resultText(r)), { exit: 3, outcome: 'refused', stdout: '', stderr: 'nothing done\n' });
});

test('an exit code the table does not name is reported as the code', async () => {
  const { env } = rig(`exit 9`);
  const r = await callTool(tool('fake_echo'), {}, { env, timeoutMs: 5000 });
  assert.equal(JSON.parse(resultText(r)).outcome, 'exit 9');
});

test('the program reads an empty stdin: a verb that waits for input ends instead of hanging the call', async () => {
  const { env } = rig(`read line; printf 'got:%s' "$line"`);
  const r = await callTool(tool('fake_stdin'), {}, { env, timeoutMs: 5000 });
  assert.equal(JSON.parse(resultText(r)).stdout, 'got:');
});

test('a program that outlives the timeout is stopped and the call says timeout', async () => {
  const { env } = rig(`exec sleep 30`);
  const r = await callTool(tool('fake_hang'), {}, { env, timeoutMs: 200 });
  assert.equal(r.isError, true);
  const body = JSON.parse(resultText(r));
  assert.equal(body.outcome, 'timeout');
  assert.equal(body.exit, 4);
});

test('a program that is not on PATH is an error that says which one', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-run-empty-'));
  const r = await callTool(tool('fake_echo'), {}, { env: { PATH: dir }, timeoutMs: 5000 });
  assert.equal(r.isError, true);
  const body = JSON.parse(resultText(r));
  assert.equal(body.outcome, 'error');
  assert.match(body.stderr, /tagents-fake.*PATH/);
});

test('arguments the schema rejects never start the program', async () => {
  const { env, dir } = rig(`touch "$0.ran"`);
  const r = await callTool(tool('fake_echo'), { nope: 1 }, { env, timeoutMs: 5000 });
  assert.equal(r.isError, true);
  assert.equal(JSON.parse(resultText(r)).outcome, 'usage');
  assert.match(JSON.parse(resultText(r)).stderr, /nope/);
  assert.equal(fs.existsSync(path.join(dir, 'tagents-fake.ran')), false);
});

test('a verb that needs tmux is refused, without running, when the server has no tmux of its own', async () => {
  const { env, dir } = rig(`touch "$0.ran"`);
  const r = await callTool(tool('fake_window'), {}, { env, timeoutMs: 5000 });
  assert.equal(r.isError, true);
  const body = JSON.parse(resultText(r));
  assert.equal(body.outcome, 'refused');
  assert.equal(body.exit, 3);
  assert.match(body.stderr, /tmux/);
  assert.equal(fs.existsSync(path.join(dir, 'tagents-fake.ran')), false);
  const inTmux = await callTool(tool('fake_window'), {}, { env: { ...env, TMUX: '/tmp/tmux-1/default,1,0' }, timeoutMs: 5000 });
  assert.equal(inTmux.isError, false);
  assert.equal(fs.existsSync(path.join(dir, 'tagents-fake.ran')), true);
});

test('arguments travel as one word each: a newline or an equals sign inside a value does not split or re-read it', async () => {
  const { env } = rig(`printf '%s' "$#"; printf '<%s>' "$@"`);
  const r = await callTool(tool('fake_echo'), { name: 'a=b', text: 'line one\nline two=x' }, { env, timeoutMs: 5000 });
  assert.equal(JSON.parse(resultText(r)).stdout, '3<echo><--name=a=b><line one\nline two=x>');
});

test('a program that cannot be started is a refusal, never a rejection: a NUL in the environment, a file that is not executable', async () => {
  const withNul = rig(`exit 0`);
  const nul = await callTool(tool('fake_echo'), {}, { env: { ...withNul.env, BAD: 'a\0b' }, timeoutMs: 5000 });
  assert.equal(nul.isError, true);
  assert.equal(JSON.parse(resultText(nul)).outcome, 'error');

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-run-noexec-'));
  try {
    fs.writeFileSync(path.join(dir, 'tagents-fake'), '#!/bin/sh\nexit 0\n', { mode: 0o644 });
    const noexec = await callTool(tool('fake_echo'), {}, { env: { PATH: dir }, timeoutMs: 5000 });
    assert.equal(noexec.isError, true);
    assert.equal(JSON.parse(resultText(noexec)).outcome, 'error');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// The cap counts bytes of the stream, as the client's limit does, and cuts between characters.
const MARKER = /\n\[output cut at \d+ bytes\]$/;
const bytes = (text: string): number => Buffer.byteLength(text);

test('output over the cap is cut on a character boundary with a marker, whatever the chunks were: a character that straddles the limit is dropped whole', async () => {
  const { env } = rig(`head -c ${MAX_STREAM - 1} /dev/zero | tr '\\0' a; printf '\\303\\251'; head -c 1000 /dev/zero | tr '\\0' b`);
  const body = JSON.parse(resultText(await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 })));
  assert.equal(body.truncated, true);
  assert.ok(!body.stdout.includes('\uFFFD'), 'no replacement character');
  assert.ok(!body.stdout.includes('\u00E9'), 'the half of the é that fit is dropped with the é');
  assert.match(body.stdout, MARKER);
  assert.equal(body.stdout.replace(MARKER, '').length, MAX_STREAM - 1);
  assert.ok(bytes(body.stdout) <= MAX_STREAM + bytes(body.stdout.match(MARKER)?.[0] ?? ''));
});

test('a character that ends exactly at the limit stays', async () => {
  const { env } = rig(`head -c ${MAX_STREAM - 2} /dev/zero | tr '\\0' a; printf '\\303\\251'; head -c 1000 /dev/zero | tr '\\0' b`);
  const body = JSON.parse(resultText(await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 })));
  assert.equal(body.truncated, true);
  assert.ok(body.stdout.replace(MARKER, '').endsWith('a\u00E9'));
  assert.equal(bytes(body.stdout.replace(MARKER, '')), MAX_STREAM);
});

test('many small writes that add up past the cap are cut by bytes in total, not by the size of a chunk, and multi-byte text is counted in bytes', async () => {
  const { env } = rig(`i=0; while [ $i -lt 400 ]; do printf '${'€'.repeat(300)}'; i=$((i+1)); done`);
  const r = await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 });
  const body = JSON.parse(resultText(r));
  assert.equal(body.truncated, true);
  assert.match(body.stdout, MARKER);
  const kept = body.stdout.replace(MARKER, '');
  assert.ok(bytes(kept) <= MAX_STREAM && bytes(kept) > MAX_STREAM - 3, `kept ${bytes(kept)} bytes`);
  assert.ok(!kept.includes('\uFFFD'));
});

test('a surrogate pair is never split by the cut, and stderr is capped on its own', async () => {
  const { env } = rig(`printf a; yes '😀' | head -c ${MAX_STREAM * 2}; yes '😀' | head -c ${MAX_STREAM * 2} >&2`);
  const body = JSON.parse(resultText(await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 })));
  for (const stream of [body.stdout, body.stderr]) {
    assert.ok(stream.isWellFormed(), 'no lone surrogate');
    assert.match(stream, MARKER);
    assert.ok(bytes(stream.replace(MARKER, '')) <= MAX_STREAM);
  }
});

test('a cut stderr marks the result but does not turn a small JSON stdout into text', async () => {
  const { env } = rig(`printf '{"a":[1,2]}\\n'; head -c ${MAX_STREAM + 1000} /dev/zero | tr '\\0' e >&2`);
  const body = JSON.parse(resultText(await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 })));
  assert.equal(body.truncated, true);
  assert.deepEqual(body.stdout, { a: [1, 2] });
  assert.match(body.stderr, MARKER);
});

test('a failing program whose stderr is cut is still an error, with its code, its stdout and the mark', async () => {
  const { env } = rig(`printf '{"a":[1,2]}\\n'; head -c ${MAX_STREAM + 1000} /dev/zero | tr '\\0' e >&2; exit 9`);
  const result = await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 });
  const body = JSON.parse(resultText(result));
  assert.equal(result.isError, true);
  assert.equal(body.exit, 9);
  assert.equal(body.outcome, 'exit 9');
  assert.equal(body.truncated, true);
  assert.deepEqual(body.stdout, { a: [1, 2] });
  assert.match(body.stderr, MARKER);
  assert.ok(bytes(body.stderr.replace(MARKER, '')) <= MAX_STREAM);
});

test('output within the cap is whole and not marked', async () => {
  const { env } = rig(`head -c ${MAX_STREAM} /dev/zero | tr '\\0' a`);
  const body = JSON.parse(resultText(await callTool(tool('fake_echo'), {}, { env, timeoutMs: 20000 })));
  assert.equal(body.truncated, undefined);
  assert.equal(body.stdout.length, MAX_STREAM);
});
