// node --test hook.test.ts
//
// The pre-commit hook regenerates the contract when a commit stages something the contract is generated from. A source the generator reads that the hook's pattern does not match is a commit that leaves the contract stale, which only the test run and CI catch, so the pattern is pinned to the sources here.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { SPEC_FILE } from '../../core/src/cli/spec.ts';
import { BASH_SPEC } from '../src/sources.ts';
import { REPO_ROOT } from '../src/tree.ts';

const hook = fs.readFileSync(path.join(REPO_ROOT, '.githooks', 'pre-commit'), 'utf8');
const pattern = /grep -q -E '([^']+)'/.exec(hook)?.[1];
/** The data file of `tagents-core` where the loader reads it, relative to the repository, and the schema that describes it. */
const CORE_SPEC = path.relative(REPO_ROOT, fileURLToPath(SPEC_FILE));
const CORE_SPEC_SCHEMA = 'spec/cli/cli-spec.schema.json';

test('the hook names the files it regenerates for in one pattern', () => {
  assert.ok(pattern !== undefined, 'no grep -q -E pattern in .githooks/pre-commit');
});

test('the pattern matches the script, its CLI spec, the data file and the schema of tagents-core, a package source, the manifest and the lockfile', () => {
  assert.ok(pattern !== undefined);
  const re = new RegExp(pattern);
  for (const staged of ['tagents', BASH_SPEC, CORE_SPEC, CORE_SPEC_SCHEMA, 'packages/mcp/src/tools.ts', 'packages/notify/package.json', 'pnpm-lock.yaml', '.claude-plugin/plugin.json', 'skills/tagents/SKILL.md', 'contract.json']) {
    assert.ok(re.test(staged), `${staged} is staged and the hook would not regenerate`);
  }
});

test('the pattern leaves out what the contract is not made from', () => {
  assert.ok(pattern !== undefined);
  const re = new RegExp(pattern);
  for (const staged of ['README.md', 'docs/guide/accounts.md', 'tests/launch.sh', 'openspec/changes/x/tasks.md', 'packages/mcp/test/tools.test.ts']) {
    assert.ok(!re.test(staged), `${staged} would regenerate for nothing`);
  }
});
