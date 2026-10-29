// node --test tools.test.ts
//
// The tools of the `tagents` server are derived from the CLI specs, so the plugin version follows the specs: a verb added to a spec is a tool, a different digest and a minor move, with no tool written by hand anywhere in this test.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createT } from '../src/i18n/index.ts';
import { isJsonArray, isJsonObject, parseJson, type JsonValue } from '../src/json.ts';
import { planGenerate } from '../src/plan.ts';
import { tagentsServer } from '../src/sources.ts';
import { noticeLines } from '../src/tree.ts';
import type { CliContract, Sources } from '../src/types.ts';
import { applied, sampleDisk, sampleServer, sampleSources } from './sample.ts';

const t = createT();

const fixture: CliContract = {
  program: 'tagents-demo',
  exit: { ok: 0, error: 1, usage: 2, refused: 3 },
  commands: [
    { path: ['search'], positionals: ['<query…>'], options: { limit: { type: 'string' } }, required: [], summary: 'finds documents', effect: 'read' },
    { path: ['session', 'open'], positionals: [], options: { cwd: { type: 'string' } }, required: ['cwd'], summary: 'starts a session', effect: 'spawn' },
  ],
};

/** What `collectSources` does with a set of CLI specs: the server's tools are made from the same specs the references are. */
const sourcesOf = (...cli: CliContract[]): Sources => ({ ...sampleSources(), cli, mcp: [sampleServer, tagentsServer(cli)] });

const withVerb = (cli: CliContract, verb: CliContract['commands'][number]): CliContract => ({ ...cli, commands: [...cli.commands, verb] });
const archive = { path: ['archive'], positionals: ['<id>'], options: {}, required: [], summary: 'archives a document', effect: 'write' } as const;

function toolNames(contract: string | undefined): string[] {
  assert.notEqual(contract, undefined);
  const parsed: JsonValue = parseJson(contract ?? '');
  assert.ok(isJsonObject(parsed));
  const server = isJsonObject(parsed['mcp']) ? parsed['mcp']['tagents'] : undefined;
  assert.ok(isJsonObject(server));
  const tools = server['tools'];
  assert.ok(isJsonArray(tools));
  return tools.map((tool) => (isJsonObject(tool) && typeof tool['name'] === 'string' ? tool['name'] : ''));
}

test('the server is called tagents and lists one tool per verb of the specs it is given', () => {
  const server = tagentsServer([fixture]);
  assert.equal(server.name, 'tagents');
  assert.deepEqual(server.tools.map((tool) => tool.name), ['demo_search', 'demo_session_open']);
});

test('a verb added to a CLI spec is a new tool and a minor version move, with no code written for the tool', () => {
  const first = planGenerate(sourcesOf(fixture), sampleDisk(), t);
  assert.deepEqual(toolNames(first.writes.get('contract.json')), ['demo_search', 'demo_session_open']);
  const disk = applied(sampleDisk(), first);

  const second = planGenerate(sourcesOf(withVerb(fixture, archive)), disk, t);
  assert.deepEqual(toolNames(second.writes.get('contract.json')), ['demo_archive', 'demo_search', 'demo_session_open']);
  assert.notEqual(second.digest, first.digest);
  assert.equal(second.move, 'minor');
  assert.equal(second.versionFrom, '0.1.0');
  assert.equal(second.versionTo, '0.2.0');
});

test('rewording a summary changes the tool description and moves the version by a patch only', () => {
  const disk = applied(sampleDisk(), planGenerate(sourcesOf(fixture), sampleDisk(), t));
  const reworded: CliContract = { ...fixture, commands: fixture.commands.map((c) => (c.path[0] === 'search' ? { ...c, summary: 'looks documents up' } : c)) };
  const plan = planGenerate(sourcesOf(reworded), disk, t);
  assert.equal(plan.move, 'patch');
  assert.equal(plan.versionTo, '0.1.1');
});

test('changing the effect of a verb changes the hints of its tool and moves the version by a minor', () => {
  const disk = applied(sampleDisk(), planGenerate(sourcesOf(fixture), sampleDisk(), t));
  const stricter: CliContract = { ...fixture, commands: fixture.commands.map((c) => (c.path[0] === 'search' ? { ...c, effect: 'destructive' as const } : c)) };
  assert.equal(planGenerate(sourcesOf(stricter), disk, t).move, 'minor');
});

test('contract.json records the effect and the requirement of a verb next to its flags', () => {
  const cli: CliContract = { ...fixture, commands: [{ ...fixture.commands[1]!, requires: 'tmux' }] };
  const written = planGenerate(sourcesOf(cli), sampleDisk(), t).writes.get('contract.json');
  const parsed: JsonValue = parseJson(written ?? '');
  assert.ok(isJsonObject(parsed) && isJsonObject(parsed['cli']));
  const demo = parsed['cli']['tagents-demo'];
  assert.ok(isJsonObject(demo) && isJsonArray(demo['commands']));
  const [command] = demo['commands'];
  assert.ok(isJsonObject(command));
  assert.equal(command['effect'], 'spawn');
  assert.equal(command['requires'], 'tmux');
});

test('a verb without an effect is listed in a notice, and the plan is not made stale by it', () => {
  const unclassified: CliContract = { ...fixture, commands: [...fixture.commands, { path: ['config', 'convert'], positionals: [], options: {}, required: [], summary: 'converts the config' }] };
  const plan = planGenerate(sourcesOf(unclassified), sampleDisk(), t);
  assert.deepEqual(plan.unclassified, ['tagents-demo config convert']);
  assert.match(noticeLines(plan, t).join('\n'), /tagents-demo config convert/);
  assert.ok(!plan.stale.includes('tagents-demo config convert'));
  assert.deepEqual(planGenerate(sourcesOf(fixture), sampleDisk(), t).unclassified, []);
  assert.deepEqual(noticeLines(planGenerate(sourcesOf(fixture), sampleDisk(), t), t), []);
});
