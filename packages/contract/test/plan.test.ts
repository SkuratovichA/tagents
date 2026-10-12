// node --test plan.test.ts
//
// The plan is pure: sources and an in-memory tree in, writes, deletes and the version move out.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createT } from '../src/i18n/index.ts';
import { parseJson, stringifyJson } from '../src/json.ts';
import { REFERENCES_DIR, planGenerate, type Disk } from '../src/plan.ts';
import type { Sources } from '../src/types.ts';
import { SAMPLE_PLUGIN, applied, sampleCli, sampleDisk, sampleSources } from './sample.ts';

const t = createT();
const PLUGIN = '.claude-plugin/plugin.json';

function pluginOf(disk: Disk): Record<string, unknown> {
  const raw = disk.files.get(PLUGIN);
  assert.equal(typeof raw, 'string');
  const parsed: unknown = JSON.parse(String(raw));
  assert.ok(typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed));
  return { ...parsed };
}

function withDisk(disk: Disk, extra: Record<string, string>): Disk {
  return { files: new Map([...disk.files, ...Object.entries(extra)]) };
}

const generated = (): { sources: Sources; disk: Disk } => {
  const sources = sampleSources();
  const first = planGenerate(sources, sampleDisk(), t);
  return { sources, disk: applied(sampleDisk(), first) };
};

test('the first plan writes the contract, the references and the digest, and keeps the version', () => {
  const plan = planGenerate(sampleSources(), sampleDisk(), t);
  assert.deepEqual([...plan.writes.keys()], [
    PLUGIN,
    'contract.json',
    `${REFERENCES_DIR}/cli.md`,
    `${REFERENCES_DIR}/core.api.md`,
    `${REFERENCES_DIR}/mcp.md`,
    `${REFERENCES_DIR}/scripts.md`,
  ].sort());
  assert.equal(plan.move, 'first');
  assert.equal(plan.versionTo, '0.1.0');
  const after = pluginOf(applied(sampleDisk(), plan));
  assert.equal(after['version'], '0.1.0');
  assert.deepEqual(after['metadata'], { digest: plan.digest });
});

test('the API report is written unchanged', () => {
  const plan = planGenerate(sampleSources(), sampleDisk(), t);
  assert.equal(plan.writes.get(`${REFERENCES_DIR}/core.api.md`), sampleSources().api[0]?.markdown);
});

test('plugin.json keeps the order and the values of its other keys', () => {
  const { disk } = generated();
  const after = pluginOf(disk);
  assert.deepEqual(Object.keys(after), [...Object.keys(SAMPLE_PLUGIN), 'metadata']);
  for (const [key, value] of Object.entries(SAMPLE_PLUGIN)) assert.deepEqual(after[key], value, key);
  assert.ok(String(disk.files.get(PLUGIN)).endsWith('}\n'), 'two-space JSON and a trailing newline');
  assert.equal(disk.files.get(PLUGIN), stringifyJson(parseJson(String(disk.files.get(PLUGIN)))));
});

test('a metadata the plugin already has keeps its other keys and its place', () => {
  const plugin = { ...SAMPLE_PLUGIN, metadata: { note: 'kept', digest: 'sha256:stale' }, extra: 1 };
  const disk = withDisk(generated().disk, { [PLUGIN]: JSON.stringify(plugin) });
  const plan = planGenerate(sampleSources(), disk, t);
  const after = pluginOf(applied(disk, plan));
  assert.deepEqual(Object.keys(after), Object.keys(plugin));
  assert.deepEqual(after['metadata'], { note: 'kept', digest: plan.digest });
  assert.equal(after['version'], '0.1.1', 'a stale stored digest with an unchanged structure is a patch');
});

test('the plan for an unchanged tree is empty', () => {
  const { sources, disk } = generated();
  const again = planGenerate(sources, disk, t);
  assert.equal(again.writes.size, 0);
  assert.deepEqual(again.deletes, []);
  assert.deepEqual(again.stale, []);
  assert.equal(again.move, 'same');
});

test('a plugin.json that only differs in formatting is left untouched while the digest matches', () => {
  const { sources, disk } = generated();
  const reformatted = withDisk(disk, { [PLUGIN]: JSON.stringify(parseJson(String(disk.files.get(PLUGIN)))) });
  assert.deepEqual(planGenerate(sources, reformatted, t).stale, []);
});

test('a stray file under references is deleted in write mode and reported stale in check mode', () => {
  const { sources, disk } = generated();
  const stray = `${REFERENCES_DIR}/old.md`;
  const plan = planGenerate(sources, withDisk(disk, { [stray]: 'left behind\n' }), t);
  assert.deepEqual(plan.deletes, [stray]);
  assert.deepEqual(plan.stale, [stray]);
  assert.equal(plan.writes.size, 0);
  assert.equal(plan.move, 'same', 'a stray file is not part of what the plugin ships');
});

test('a file under skills outside references is part of the payload, never deleted', () => {
  const { sources, disk } = generated();
  const plan = planGenerate(sources, withDisk(disk, { 'skills/tagents/SKILL.md': '# the skill, edited\n' }), t);
  assert.deepEqual(plan.deletes, []);
  assert.equal(plan.move, 'patch');
  assert.equal(plan.versionTo, '0.1.1');
  assert.deepEqual([...plan.writes.keys()], [PLUGIN]);
});

test('a changed marketplace.json is a patch', () => {
  const { sources, disk } = generated();
  const plan = planGenerate(sources, withDisk(disk, { '.claude-plugin/marketplace.json': '{"name":"other"}\n' }), t);
  assert.deepEqual([plan.move, plan.versionTo], ['patch', '0.1.1']);
});

test('a changed key of plugin.json other than the version and the digest is a patch', () => {
  const { sources, disk } = generated();
  const edited = { ...pluginOf(disk), description: 'a new description' };
  const plan = planGenerate(sources, withDisk(disk, { [PLUGIN]: JSON.stringify(edited) }), t);
  assert.deepEqual([plan.move, plan.versionTo], ['patch', '0.1.1']);
});

test('a changed mcpServers entry of plugin.json is a patch', () => {
  const { sources, disk } = generated();
  const edited = { ...pluginOf(disk), mcpServers: { knowledge: { command: 'demo', args: ['mcp', '--other'] } } };
  const plan = planGenerate(sources, withDisk(disk, { [PLUGIN]: JSON.stringify(edited) }), t);
  assert.deepEqual([plan.move, plan.versionTo], ['patch', '0.1.1']);
});

test('a change in a script help text alone is a patch: the scripts have no spec, so their help counts as text', () => {
  const { sources, disk } = generated();
  const edited: Sources = { ...sources, scripts: sources.scripts.map((s) => ({ ...s, help: `${s.help}  --other   does another thing\n` })) };
  const plan = planGenerate(edited, disk, t);
  assert.deepEqual([plan.move, plan.versionTo], ['patch', '0.1.1']);
  assert.ok(plan.writes.has(`${REFERENCES_DIR}/scripts.md`));
});

test('an added flag is a minor: the version moves, contract.json and cli.md are rewritten', () => {
  const { disk } = generated();
  const extended: Sources = {
    ...sampleSources(),
    cli: [{ ...sampleCli, commands: sampleCli.commands.map((c, i) => (i === 0 ? { ...c, options: { ...c.options, model: { type: 'string' as const } } } : c)) }],
  };
  const plan = planGenerate(extended, disk, t);
  assert.deepEqual([plan.move, plan.versionFrom, plan.versionTo], ['minor', '0.1.0', '0.2.0']);
  assert.deepEqual([...plan.writes.keys()], [PLUGIN, 'contract.json', `${REFERENCES_DIR}/cli.md`].sort());
  const next = applied(disk, plan);
  assert.deepEqual(planGenerate(extended, next, t).stale, [], 'the second run changes nothing');
});

test('the digest does not move when only plugin.json version and digest differ', () => {
  const { sources, disk } = generated();
  const a = planGenerate(sources, disk, t).digest;
  const edited = { ...pluginOf(disk), version: '9.9.9', metadata: { digest: 'sha256:anything' } };
  assert.equal(planGenerate(sources, withDisk(disk, { [PLUGIN]: JSON.stringify(edited) }), t).digest, a);
});

test('a plugin.json without a usable version is refused', () => {
  const broken = withDisk(sampleDisk(), { [PLUGIN]: JSON.stringify({ name: 'x' }) });
  assert.throws(() => planGenerate(sampleSources(), broken, t), /"version"/);
  const missing: Disk = { files: new Map() };
  assert.throws(() => planGenerate(sampleSources(), missing, t), /plugin\.json/);
});
