// node --test contract-file.test.ts
//
// The server reads the verbs from contract.json, the file the generator wrote from the specs; a shape it does not recognise stops the server at start, with the reason, instead of serving a half-read list.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CliContract } from '@tagents/core';
import { cliContractsOf, parseCliContract } from '../src/contract-file.ts';

const demo: CliContract = {
  program: 'tagents-demo',
  exit: { ok: 0, error: 1, refused: 3 },
  commands: [
    { path: ['open'], positionals: ['<dir>'], options: { tag: { type: 'string', multiple: true }, json: { type: 'boolean' } }, required: [], summary: 'opens', effect: 'spawn', requires: 'tmux' },
    { path: ['plain'], positionals: [], options: {}, required: [], summary: 'has no effect and no requirement' },
  ],
};

test('contract.json is read back into the CLI contracts it was written from, optional keys present only where they were', () => {
  const text = JSON.stringify({ contractVersion: 1, cli: { 'tagents-demo': { exit: demo.exit, commands: demo.commands } }, mcp: {}, api: {} });
  assert.deepEqual(cliContractsOf(text), [demo]);
});

test('a file that is not JSON, or has no cli section, is an error that says so', () => {
  assert.throws(() => cliContractsOf('{'), /JSON/);
  assert.throws(() => cliContractsOf('{"contractVersion":1}'), /cli/);
});

test('a verb with an effect the server does not know is an error naming the field', () => {
  const bad = { program: 'p', exit: { ok: 0 }, commands: [{ path: ['x'], positionals: [], options: {}, required: [], summary: 's', effect: 'explode' }] };
  assert.throws(() => parseCliContract(bad), /effect/);
});

test('a spec with its own program name reads the same way', () => {
  assert.deepEqual(parseCliContract(demo), demo);
});
