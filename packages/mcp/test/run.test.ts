// node --test run.test.ts
//
// A call is a child process: the program looked up on PATH, no stdin, its exit code named by the program's own table. The programs here are shell scripts written into a temporary directory that is the whole PATH, so nothing of the machine can answer.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { CliContract } from '@tagents/core';
import { callTool, resultText } from '../src/run.ts';
import { toolSpecs } from '../src/tools.ts';

const cli: CliContract = {
  program: 'tagents-fake',
  exit: { ok: 0, error: 1, usage: 2, refused: 3, timeout: 4 },
  commands: [
    { path: ['echo'], positionals: ['[text]'], options: { loud: { type: 'boolean' } }, required: [], summary: 'prints', effect: 'read' },
    { path: ['stdin'], positionals: [], options: {}, required: [], summary: 'reads stdin', effect: 'read' },
    { path: ['hang'], positionals: [], options: {}, required: [], summary: 'never ends', effect: 'read' },
    { path: ['window'], positionals: [], options: {}, required: [], summary: 'opens a window', effect: 'spawn', requires: 'tmux' },
  ],
};
const tool = (name: string) => {
  const found = toolSpecs([cli]).find((t) => t.name === name);
  assert.ok(found, name);
  return found;
};

function rig(script: string): { env: NodeJS.ProcessEnv; dir: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-run-'));
  const file = path.join(dir, 'tagents-fake');
  fs.writeFileSync(file, `#!/bin/sh\n${script}\n`, { mode: 0o755 });
  return { dir, env: { PATH: `${dir}:/usr/bin:/bin` } };
}

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
