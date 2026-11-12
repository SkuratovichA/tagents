// node --test tools.test.ts
//
// The tool surface is a function of the CLI specs and nothing else: a spec in, tools out. Nothing here knows a verb of the product.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CliContract } from '@tagents/core';
import { toolSpecs } from '../src/tools.ts';

const demo: CliContract = {
  program: 'tagents-demo',
  exit: { ok: 0, error: 1, usage: 2, refused: 3 },
  commands: [
    {
      path: ['session', 'open'],
      positionals: [],
      options: { cwd: { type: 'string' }, tag: { type: 'string', multiple: true }, json: { type: 'boolean' } },
      required: ['cwd'],
      summary: 'starts a demo session',
      effect: 'spawn',
    },
    { path: ['search'], positionals: ['<query…>'], options: { limit: { type: 'string' } }, required: [], summary: 'finds things.', effect: 'read' },
    { path: ['label'], positionals: ['<key>', '[name]'], options: {}, required: [], summary: 'names a thing', effect: 'write' },
    { path: ['purge'], positionals: [], options: {}, required: [], summary: 'deletes the demo state', effect: 'destructive' },
    { path: ['serve'], positionals: [], options: {}, required: [], summary: 'serves until stopped', effect: 'serve' },
    { path: ['mystery'], positionals: [], options: {}, required: [], summary: 'does something unclassified' },
  ],
};

const bare: CliContract = {
  program: 'tagents',
  exit: { ok: 0, error: 1 },
  commands: [{ path: ['--new'], positionals: ['[dir]', '[profile]'], options: {}, required: [], summary: 'opens a window', effect: 'spawn' }],
};

const windowed: CliContract = {
  program: 'tagents',
  exit: { ok: 0, error: 1, usage: 2 },
  commands: [
    { path: ['--window'], positionals: ['<DIR>', '<COMMAND>'], options: { detach: { type: 'boolean' } }, toolDefaults: { detach: true }, required: [], summary: 'opens a window', effect: 'spawn' },
    { path: ['--prompt'], positionals: ['<text>'], options: {}, required: [], summary: 'runs an unattended turn', effect: 'spawn', tool: false },
  ],
};

const byName = (clis: readonly CliContract[]) => new Map(toolSpecs(clis).map((t) => [t.name, t]));

test('a tool per verb, named program short name and verb words, sorted, with serving verbs left out', () => {
  const names = toolSpecs([demo, bare]).map((t) => t.name);
  assert.deepEqual(names, ['demo_label', 'demo_mystery', 'demo_purge', 'demo_search', 'demo_session_open', 'tagents_new']);
  for (const name of names) assert.match(name, /^[a-zA-Z0-9_-]{1,64}$/, name);
});

test('two verbs that would get one name are an error at generation, not a silent overwrite', () => {
  const twin: CliContract = { ...demo, program: 'tagents-demo', commands: [demo.commands[1]!, { ...demo.commands[1]!, summary: 'again' }] };
  assert.throws(() => toolSpecs([twin]), /demo_search/);
});

test('options become properties by type, repeatable ones arrays, and the required list is carried over', () => {
  const tool = byName([demo]).get('demo_session_open');
  assert.deepEqual(tool?.inputSchema, {
    type: 'object',
    properties: {
      cwd: { type: 'string' },
      tag: { type: 'array', items: { type: 'string' } },
      json: { type: 'boolean' },
    },
    required: ['cwd'],
    additionalProperties: false,
  });
});

test('positionals become properties: <x> required, [x] optional, a trailing … an array of words', () => {
  const tools = byName([demo]);
  assert.deepEqual(tools.get('demo_search')?.inputSchema, {
    type: 'object',
    properties: { query: { type: 'array', items: { type: 'string' }, minItems: 1 }, limit: { type: 'string' } },
    required: ['query'],
    additionalProperties: false,
  });
  assert.deepEqual(tools.get('demo_label')?.inputSchema, {
    type: 'object',
    properties: { key: { type: 'string' }, name: { type: 'string' } },
    required: ['key'],
    additionalProperties: false,
  });
});

test('the description is the summary as a sentence', () => {
  const tools = byName([demo]);
  assert.equal(tools.get('demo_session_open')?.description, 'Starts a demo session.');
  assert.equal(tools.get('demo_search')?.description, 'Finds things.');
});

test('the effect of a verb sets the hints a client asks for permission by; a verb without one is not read-only', () => {
  const tools = byName([demo]);
  assert.deepEqual(tools.get('demo_search')?.annotations, { readOnlyHint: true, openWorldHint: false });
  assert.deepEqual(tools.get('demo_label')?.annotations, { readOnlyHint: false, destructiveHint: false, openWorldHint: false });
  assert.deepEqual(tools.get('demo_session_open')?.annotations, { readOnlyHint: false, destructiveHint: false, openWorldHint: true });
  assert.deepEqual(tools.get('demo_purge')?.annotations, { readOnlyHint: false, destructiveHint: true, openWorldHint: false });
  assert.deepEqual(tools.get('demo_mystery')?.annotations, { readOnlyHint: false });
});

test('a verb the spec marks tool: false is no tool', () => {
  assert.deepEqual(toolSpecs([windowed]).map((t) => t.name), ['tagents_window']);
});

test('a boolean option the spec defaults is in the schema with its default, and ', () => {
  const tool = byName([windowed]).get('tagents_window');
  assert.ok(tool);
  assert.deepEqual(tool.inputSchema.properties['detach'], { type: 'boolean', default: true });
});

test('a default for an option the verb does not have, or for one that is not a boolean, stops the tool list from being made', () => {
  const [window] = windowed.commands;
  assert.ok(window);
  const withDefaults = (command: CliContract['commands'][number]): CliContract => ({ ...windowed, commands: [command] });
  assert.throws(() => toolSpecs([withDefaults({ ...window, toolDefaults: { attach: true } })]), /tagents_window.*--attach.*does not have/);
  assert.throws(() => toolSpecs([withDefaults({ ...window, options: { detach: { type: 'string' } } })]), /tagents_window.*--detach.*string/);
});

