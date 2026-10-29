// node --test contract-file.test.ts
//
// The server reads the verbs from contract.json, the file the generator wrote from the specs; a shape it does not recognise stops the server at start, with the reason, instead of serving a half-read list.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CliContract } from '@tagents/core';
import { cliContractsOf, parseCliContract } from '../src/contract-file.ts';
import { toolSpecs } from '../src/tools.ts';

const demo: CliContract = {
  program: 'tagents-demo',
  exit: { ok: 0, error: 1, refused: 3 },
  commands: [
    { path: ['open'], positionals: ['<dir>'], options: { tag: { type: 'string', multiple: true }, json: { type: 'boolean' } }, required: [], summary: 'opens', effect: 'spawn', requires: 'tmux' },
    { path: ['plain'], positionals: [], options: {}, required: [], summary: 'has no effect and no requirement' },
    { path: ['quiet'], positionals: [], options: { detach: { type: 'boolean' } }, required: [], summary: 'is no tool and defaults a flag', effect: 'read', tool: false, toolDefaults: { detach: true } },
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

test('a contract from a newer generator, with an effect this server does not know and a key it has not heard of, still yields the tool, as an unclassified verb', () => {
  const newer = {
    contractVersion: 2,
    cli: {
      'tagents-demo': {
        exit: { ok: 0 },
        commands: [{ path: ['x'], positionals: [], options: {}, required: [], summary: 's', effect: 'teleport', futureKey: { any: 'shape' } }],
      },
    },
  };
  const [cli] = cliContractsOf(JSON.stringify(newer));
  assert.ok(cli);
  assert.deepEqual(cli.commands, [{ path: ['x'], positionals: [], options: {}, required: [], summary: 's' }]);
  const [tool] = toolSpecs([cli]);
  assert.equal(tool?.name, 'demo_x');
  assert.deepEqual(tool?.annotations, { readOnlyHint: false });
});

test('a spec with its own program name reads the same way', () => {
  assert.deepEqual(parseCliContract(demo), demo);
});
