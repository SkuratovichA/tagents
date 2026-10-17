import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { apiReports } from '../src/api.ts';

const root = fileURLToPath(new URL('../../..', import.meta.url)).replace(/\/$/, '');

test('apiReports reports the public API of each public package', { timeout: 120_000 }, async () => {
  const reports = await apiReports(root);
  assert.deepEqual(reports.map((r) => r.package), ['@tagents/core', '@tagents/knowledge', '@tagents/notify', '@tagents/telegram']);
  assert.deepEqual(reports.map((r) => r.file), ['core.api.md', 'knowledge.api.md', 'notify.api.md', 'telegram.api.md']);
  const [core, knowledge] = reports;
  assert.ok(core?.markdown.includes('definePlugin'));
  assert.ok(core?.markdown.includes('CommandSpec'));
  assert.ok(knowledge?.markdown.includes('createServer'));
  for (const r of reports) {
    assert.ok(!r.markdown.includes(root), r.package);
    assert.ok(!r.markdown.includes('\r'), r.package);
  }
  const again = await apiReports(root);
  assert.deepEqual(again.map((r) => r.markdown), reports.map((r) => r.markdown));
});

const run = promisify(execFile);
const apiModule = fileURLToPath(new URL('../src/api.ts', import.meta.url));

test('apiReports gives the same markdown from any working directory', { timeout: 120_000 }, async () => {
  const expected = (await apiReports(root)).map((r) => r.markdown);
  const script = `import { apiReports } from ${JSON.stringify(apiModule)};
process.stdout.write(JSON.stringify((await apiReports(${JSON.stringify(root)})).map((r) => r.markdown)));`;
  for (const cwd of [root, tmpdir()]) {
    const { stdout } = await run(process.execPath, ['--input-type=module', '-e', script], { cwd, maxBuffer: 64 * 1024 * 1024 });
    assert.deepEqual(JSON.parse(stdout), expected, cwd);
  }
});

test('two apiReports calls at once give what one call gives, each in a directory of its own', { timeout: 240_000 }, async () => {
  const sequential = (await apiReports(root)).map((r) => r.markdown);
  const [a, b] = await Promise.all([apiReports(root), apiReports(root)]);
  assert.deepEqual(a.map((r) => r.markdown), sequential);
  assert.deepEqual(b.map((r) => r.markdown), sequential);
});
