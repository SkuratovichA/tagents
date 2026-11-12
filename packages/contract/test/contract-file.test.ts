// node --test contract-file.test.ts
//
// One program's spec file is read into a CLI contract, or refused with the reason when it is not the shape the generator writes.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CliContract } from '@tagents/core';
import { parseCliContract } from '../src/contract-file.ts';
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

test('a spec with its own program name reads the same way', () => {
  assert.deepEqual(parseCliContract(demo), demo);
});
