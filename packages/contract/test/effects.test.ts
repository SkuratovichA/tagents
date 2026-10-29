// node --test effects.test.ts
//
// The five words an `effect` may be are written in four places that cannot import one another: the JSON Schema of the data file (read by the Rust crate, whose own test pins its enum against it), `packages/core/src/cli/spec.ts` (what the loader accepts), `packages/mcp/src/contract-file.ts` (what the server accepts from a contract file), and the node CLIs of knowledge and notify through core's `Effect` type. This file reads three of them side by side, so adding a word in one and forgetting another fails here.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { EFFECTS } from '../../core/src/cli/spec.ts';
import { parseCliContract } from '../../mcp/src/contract-file.ts';
import { REPO_ROOT } from '../src/tree.ts';

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function schemaEffects(): unknown {
  const schema: unknown = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'spec', 'cli', 'cli-spec.schema.json'), 'utf8'));
  assert.ok(isRecord(schema));
  const defs = schema['$defs'];
  assert.ok(isRecord(defs) && isRecord(defs['command']) && isRecord(defs['command']['properties']));
  const effect = defs['command']['properties']['effect'];
  assert.ok(isRecord(effect));
  return effect['enum'];
}

/** The words of `const Effect = z.enum([...])` in the server's contract reader. */
function contractFileEffects(): string[] {
  const source = fs.readFileSync(path.join(REPO_ROOT, 'packages', 'mcp', 'src', 'contract-file.ts'), 'utf8');
  const list = /^const Effect = z\.enum\(\[([^\]]*)\]\);$/m.exec(source)?.[1];
  assert.ok(list !== undefined, 'packages/mcp/src/contract-file.ts no longer has a line `const Effect = z.enum([...]);`: point this test at the new list');
  return [...list.matchAll(/'([^']+)'/g)].map((m) => m[1] ?? '');
}

test('the schema, the core loader and the server name the same effects in the same order', () => {
  assert.deepEqual(schemaEffects(), [...EFFECTS]);
  assert.deepEqual(contractFileEffects(), [...EFFECTS]);
});

test('the server keeps every effect the core loader accepts', () => {
  for (const effect of EFFECTS) {
    const parsed = parseCliContract({ program: 'p', exit: {}, commands: [{ path: ['a'], positionals: [], options: {}, required: [], summary: 's', effect }] });
    assert.equal(parsed.commands[0]?.effect, effect);
  }
});
