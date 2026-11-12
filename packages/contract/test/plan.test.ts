// node --test plan.test.ts
//
// The plan is pure: sources and an in-memory tree in, writes, deletes and the version move out.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createT } from '../src/i18n/index.ts';
import { parseJson, stringifyJson } from '../src/json.ts';
import { REFERENCES_DIR, planGenerate, type Disk } from '../src/plan.ts';
import { OKB, OKB_PROGRAM, KNOWLEDGE_SERVER_NAME } from '../src/plugins.ts';
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
    'plugins/okb/.claude-plugin/plugin.json',
    'contract.json',
    `${OKB.referencesDir}/cli.md`,
    `${OKB.referencesDir}/mcp.md`,
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

const okbOf = (plan: ReturnType<typeof planGenerate>) => plan.plugins.find((p) => p.plugin === 'okb');

test('a changed launcher in the shipped files of a plugin is a patch of that plugin only: it reaches an installed copy only as a new version', () => {
  const { sources, disk } = generated();
  const launcher = OKB.shipped[0] ?? '';
  const first = planGenerate(sources, withDisk(disk, { [launcher]: '#!/bin/sh\nexec one\n' }), t);
  assert.deepEqual([okbOf(first)?.move, okbOf(first)?.versionTo], ['patch', '1.0.1']);
  assert.equal(first.move, 'same', 'the plugin that does not ship the launcher keeps its version');
  const placed = applied(withDisk(disk, { [launcher]: '#!/bin/sh\nexec one\n' }), first);
  assert.equal(okbOf(planGenerate(sources, placed, t))?.move, 'same');
  const second = planGenerate(sources, withDisk(placed, { [launcher]: '#!/bin/sh\nexec two\n' }), t);
  assert.deepEqual([okbOf(second)?.move, okbOf(second)?.versionTo], ['patch', '1.0.2']);
});

test('each plugin has the references of the programs and servers it owns, and the other plugin has none of them', () => {
  const okbCli = { ...sampleCli, program: OKB_PROGRAM };
  const sources: Sources = { ...sampleSources(), cli: [sampleCli, okbCli], mcp: [{ name: KNOWLEDGE_SERVER_NAME, tools: [] }, ...sampleSources().mcp] };
  const plan = planGenerate(sources, sampleDisk(), t);
  const own = (path: string): string => String(plan.writes.get(path));
  assert.match(own(`${OKB.referencesDir}/cli.md`), new RegExp(`## ${OKB_PROGRAM}`));
  assert.doesNotMatch(own(`${OKB.referencesDir}/cli.md`), /## demo-cli/);
  assert.match(own(`${REFERENCES_DIR}/cli.md`), /## demo-cli/);
  assert.doesNotMatch(own(`${REFERENCES_DIR}/cli.md`), new RegExp(`## ${OKB_PROGRAM}`));
  assert.match(own(`${OKB.referencesDir}/mcp.md`), new RegExp(`## ${KNOWLEDGE_SERVER_NAME}`));
  assert.doesNotMatch(own(`${REFERENCES_DIR}/mcp.md`), new RegExp(`## ${KNOWLEDGE_SERVER_NAME}`));
  assert.equal(plan.writes.has(`${OKB.referencesDir}/scripts.md`), false, 'scripts and API reports belong to the plugin that is the root');
});

test('a stray file under the references directory of the second plugin is deleted, and a skill file of it is part of its digest only', () => {
  const { sources, disk } = generated();
  const stray = `${OKB.referencesDir}/old.md`;
  assert.deepEqual(planGenerate(sources, withDisk(disk, { [stray]: 'x' }), t).deletes, [stray]);
  const skill = 'plugins/okb/skills/okb/SKILL.md';
  const plan = planGenerate(sources, withDisk(disk, { [skill]: '# okb\n' }), t);
  assert.deepEqual([okbOf(plan)?.move, plan.move], ['patch', 'same']);
});

test('the entry of a plugin in the marketplace is in the digest of that plugin only', () => {
  const market = (tagents: string, okb: string): string =>
    `${JSON.stringify({ name: 'demo', plugins: [{ name: 'tagents', description: tagents }, { name: 'okb', description: okb }] })}\n`;
  const first = planGenerate(sampleSources(), withDisk(sampleDisk(), { '.claude-plugin/marketplace.json': market('a', 'b') }), t);
  const disk = applied(withDisk(sampleDisk(), { '.claude-plugin/marketplace.json': market('a', 'b') }), first);
  const okbChanged = planGenerate(sampleSources(), withDisk(disk, { '.claude-plugin/marketplace.json': market('a', 'b2') }), t);
  assert.deepEqual([okbChanged.move, okbOf(okbChanged)?.move], ['same', 'patch']);
  const tagentsChanged = planGenerate(sampleSources(), withDisk(disk, { '.claude-plugin/marketplace.json': market('a2', 'b') }), t);
  assert.deepEqual([tagentsChanged.move, okbOf(tagentsChanged)?.move], ['patch', 'same']);
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
