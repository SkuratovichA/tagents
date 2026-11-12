// node --test shipped.test.ts
//
// Every file `plugin.json` starts or points at through ${CLAUDE_PLUGIN_ROOT} reaches an installed copy only when the plugin version moves, so it has to be in the digest: generated, under skills/ or in SHIPPED_FILES.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { generatedFiles } from '../src/plan.ts';
import { PLUGINS } from '../src/plugins.ts';
import { collectSources } from '../src/sources.ts';
import { REPO_ROOT } from '../src/tree.ts';

const ROOT_VAR = '${CLAUDE_PLUGIN_ROOT}/';

function strings(value: unknown): string[] {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  if (typeof value === 'object' && value !== null) return Object.values(value).flatMap(strings);
  return [];
}

for (const plugin of PLUGINS) {
  test(`every file the manifest of ${plugin.name} names under CLAUDE_PLUGIN_ROOT exists and is in its digest`, async () => {
    const manifest: unknown = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, plugin.manifest), 'utf8'));
    const named = strings(manifest).filter((s) => s.includes(ROOT_VAR)).map((s) => `${plugin.root}${s.slice(s.indexOf(ROOT_VAR) + ROOT_VAR.length)}`);
    assert.ok(named.length > 0, `${plugin.manifest} names no file under CLAUDE_PLUGIN_ROOT`);
    const generated = [...generatedFiles(await collectSources(REPO_ROOT))].map(([p]) => p);
    for (const file of named) {
      assert.ok(fs.existsSync(path.join(REPO_ROOT, file)), `${file} does not exist`);
      const covered = generated.includes(file) || file.startsWith(`${plugin.skillsDir}/`) || plugin.shipped.includes(file);
      assert.ok(covered, `${file} is started by ${plugin.manifest} and is not in the digest: add it to the shipped files of ${plugin.name} in plugins.ts`);
    }
  });
}

test('the okb manifest starts its launcher', () => {
  const okb: unknown = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'plugins/okb/.claude-plugin/plugin.json'), 'utf8'));
  assert.ok(strings(okb).some((s) => s === `${ROOT_VAR}bin/okb-mcp`), 'the okb manifest does not start bin/okb-mcp');
});
