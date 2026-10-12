// node --test fresh.test.ts
//
// The live tree is fresh: contract.json, the references and the plugin digest are what the code generates today. This is the test that makes `pnpm -r test` fail when someone changes a verb, a flag, a tool, a signature, a script's help or the skill and forgets to run `pnpm plugin:gen`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createT } from '../src/i18n/index.ts';
import { REPO_ROOT, planTree, staleLines } from '../src/tree.ts';

test('the plugin contract on disk is what the code generates', async () => {
  const plan = await planTree(REPO_ROOT, createT('en'));
  assert.deepEqual(staleLines(plan, createT('en')), []);
});
