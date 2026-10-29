// node --test bin-shebang.test.ts
//
// A bin entry runs through the shebang on its first line. `#!/usr/bin/env node` followed by a word makes `env` look for a program of that name, so the bin cannot start while typecheck and every other test stay green.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { REPO_ROOT } from '../src/tree.ts';

function binSources(): { pkg: string; bin: string; source: string }[] {
  const found: { pkg: string; bin: string; source: string }[] = [];
  for (const dir of fs.readdirSync(path.join(REPO_ROOT, 'packages'))) {
    const manifest = path.join(REPO_ROOT, 'packages', dir, 'package.json');
    if (!fs.existsSync(manifest)) continue;
    const parsed: unknown = JSON.parse(fs.readFileSync(manifest, 'utf8'));
    const bin = typeof parsed === 'object' && parsed !== null && 'bin' in parsed ? parsed.bin : undefined;
    if (typeof bin !== 'object' || bin === null) continue;
    for (const [name, target] of Object.entries(bin)) {
      assert.equal(typeof target, 'string', `${dir}: bin ${name}`);
      const source = String(target).replace(/^\.\/dist\//, 'src/').replace(/\.js$/, '.ts');
      found.push({ pkg: dir, bin: name, source: path.join(REPO_ROOT, 'packages', dir, source) });
    }
  }
  return found;
}

test('every bin entry starts with a bare node shebang on its own line', () => {
  const bins = binSources();
  assert.ok(bins.length >= 3, 'the bins of core, knowledge and notify are found');
  for (const { pkg, bin, source } of bins) {
    const firstLine = fs.readFileSync(source, 'utf8').split('\n', 1)[0];
    assert.match(firstLine ?? '', /^#!\/usr\/bin\/env node$/, `${pkg}: ${bin} (${path.relative(REPO_ROOT, source)})`);
  }
});
