// node --test shipped.test.ts
//
// Every file `plugin.json` starts or points at through ${CLAUDE_PLUGIN_ROOT} reaches an installed copy only when the plugin version moves, so it has to be in the digest: generated, under skills/ or in SHIPPED_FILES.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { SHIPPED_FILES, SKILLS_DIR, generatedFiles } from '../src/plan.ts';
import { collectSources } from '../src/sources.ts';
import { REPO_ROOT } from '../src/tree.ts';

const ROOT_VAR = '${CLAUDE_PLUGIN_ROOT}/';

function strings(value: unknown): string[] {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  if (typeof value === 'object' && value !== null) return Object.values(value).flatMap(strings);
  return [];
}

test('every file plugin.json names under CLAUDE_PLUGIN_ROOT exists and is in the digest', async () => {
  const plugin: unknown = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, '.claude-plugin', 'plugin.json'), 'utf8'));
  const named = strings(plugin).filter((s) => s.includes(ROOT_VAR)).map((s) => s.slice(s.indexOf(ROOT_VAR) + ROOT_VAR.length));
  assert.ok(named.length > 0, 'plugin.json names no file under CLAUDE_PLUGIN_ROOT');
  const generated = [...generatedFiles(await collectSources(REPO_ROOT))].map(([p]) => p);
  for (const file of named) {
    assert.ok(fs.existsSync(path.join(REPO_ROOT, file)), `${file} does not exist`);
    const covered = generated.includes(file) || file.startsWith(`${SKILLS_DIR}/`) || (SHIPPED_FILES as readonly string[]).includes(file);
    assert.ok(covered, `${file} is started by plugin.json and is not in the digest: add it to SHIPPED_FILES`);
  }
});
