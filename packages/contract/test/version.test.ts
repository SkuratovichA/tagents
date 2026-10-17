// node --test version.test.ts
//
// The version move follows from the content: the first run only stores the digest, an unchanged payload changes nothing, wording changes are patches, and anything a caller can break on is a minor.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildContract } from '../src/contract.ts';
import { createT } from '../src/i18n/index.ts';
import { stringifyJson, type JsonValue } from '../src/json.ts';
import type { CliContract, McpTool, Sources } from '../src/types.ts';
import { bumpVersion, decideVersion, digestOf, structureOf } from '../src/version.ts';
import { sampleApi, sampleCli, sampleServer, sampleSources, sampleTool } from './sample.ts';

const t = createT();

/** A decision for a tree whose contract.json holds `before` and whose sources now say `after`, at 0.3.5 with a digest that no longer matches. */
function decide(before: Sources | undefined, after: Sources) {
  return decideVersion(
    {
      version: '0.3.5',
      storedDigest: 'sha256:old',
      digest: 'sha256:new',
      contractOnDisk: before === undefined ? undefined : stringifyJson(buildContract(before)),
      contract: buildContract(after),
    },
    t
  );
}

const base = sampleSources();

function withCommand(change: (c: CliContract) => CliContract): Sources {
  return { ...base, cli: [change(sampleCli)] };
}

function withTool(tool: McpTool): Sources {
  return { ...base, mcp: [{ ...sampleServer, tools: [tool] }] };
}

test('the first run, with no stored digest, keeps the version', () => {
  const d = decideVersion(
    { version: '0.1.0', storedDigest: undefined, digest: 'sha256:a', contractOnDisk: undefined, contract: buildContract(base) },
    t
  );
  assert.deepEqual(d, { move: 'first', version: '0.1.0' });
});

test('an unchanged payload changes nothing', () => {
  const d = decideVersion(
    { version: '0.1.0', storedDigest: 'sha256:a', digest: 'sha256:a', contractOnDisk: 'garbage', contract: buildContract(base) },
    t
  );
  assert.deepEqual(d, { move: 'same', version: '0.1.0' });
});

test('a changed summary is a patch', () => {
  const after = withCommand((c) => ({ ...c, commands: c.commands.map((x, i) => (i === 0 ? { ...x, summary: 'starts it' } : x)) }));
  assert.deepEqual(decide(base, after), { move: 'patch', version: '0.3.6' });
});

test('a changed tool description or input description is a patch', () => {
  const described = withTool({ ...sampleTool, description: 'Looks things up.' });
  assert.deepEqual(decide(base, described), { move: 'patch', version: '0.3.6' });
  const redescribed = withTool({
    ...sampleTool,
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'other words' },
        limit: { type: 'integer', description: 'how many' },
        kinds: { type: 'array', items: { type: 'string' } },
      },
      required: ['query'],
    },
  });
  assert.deepEqual(decide(base, redescribed), { move: 'patch', version: '0.3.6' });
});

test('an added flag is a minor and resets the patch', () => {
  const after = withCommand((c) => ({
    ...c,
    commands: c.commands.map((x, i) => (i === 0 ? { ...x, options: { ...x.options, model: { type: 'string' as const } } } : x)),
  }));
  assert.deepEqual(decide(base, after), { move: 'minor', version: '0.4.0' });
});

test('an added verb is a minor', () => {
  const after = withCommand((c) => ({ ...c, commands: [...c.commands, { path: ['doctor'], positionals: [], options: {}, required: [], summary: 'checks' }] }));
  assert.deepEqual(decide(base, after), { move: 'minor', version: '0.4.0' });
});

test('an added tool is a minor', () => {
  const after: Sources = { ...base, mcp: [{ ...sampleServer, tools: [sampleTool, { ...sampleTool, name: 'demo_get' }] }] };
  assert.deepEqual(decide(base, after), { move: 'minor', version: '0.4.0' });
});

test('a changed input schema is a minor', () => {
  const after = withTool({
    ...sampleTool,
    inputSchema: { type: 'object', properties: { query: { type: 'string', description: 'words to look for' } }, required: ['query'] },
  });
  assert.deepEqual(decide(base, after), { move: 'minor', version: '0.4.0' });
});

test('a changed API report hash is a minor', () => {
  const after: Sources = { ...base, api: [{ ...sampleApi, markdown: `${sampleApi.markdown}export const x: number;\n` }] };
  assert.deepEqual(decide(base, after), { move: 'minor', version: '0.4.0' });
});

test('a missing contract.json on disk counts as structural', () => {
  assert.deepEqual(decide(undefined, base), { move: 'minor', version: '0.4.0' });
});

test('a contract.json that is not JSON counts as structural', () => {
  const d = decideVersion({ version: '0.3.5', storedDigest: 'sha256:old', digest: 'sha256:new', contractOnDisk: '{', contract: buildContract(base) }, t);
  assert.deepEqual(d, { move: 'minor', version: '0.4.0' });
});

test('structureOf drops prose strings at any depth but keeps a property that is called description', () => {
  const contract: JsonValue = {
    summary: 'x',
    nested: [{ description: 'y', keep: 1 }],
    properties: { description: { type: 'string', description: 'z' }, summary: { type: 'string' } },
  };
  assert.deepEqual(structureOf(contract), {
    nested: [{ keep: 1 }],
    properties: { description: { type: 'string' }, summary: { type: 'string' } },
  });
});

test('a reordered option object is not a structural change', () => {
  const reordered = withCommand((c) => ({
    ...c,
    commands: c.commands.map((x, i) => (i === 0 ? { ...x, options: Object.fromEntries(Object.entries(x.options).reverse()) } : x)),
  }));
  assert.deepEqual(decide(base, reordered).move, 'patch');
});

test('bumpVersion resets the lower parts and refuses what is not major.minor.patch', () => {
  assert.equal(bumpVersion('1.2.3', 'minor', t), '1.3.0');
  assert.equal(bumpVersion('1.2.3', 'patch', t), '1.2.4');
  assert.throws(() => bumpVersion('1.2', 'patch', t), /major\.minor\.patch/);
});

test('the digest depends on content and path but not on the order files are listed in', () => {
  const a = { path: 'a.md', content: 'one' };
  const b = { path: 'b.md', content: 'two' };
  assert.equal(digestOf([a, b]), digestOf([b, a]));
  assert.notEqual(digestOf([a, b]), digestOf([a, { ...b, content: 'three' }]));
  assert.notEqual(digestOf([a, b]), digestOf([a, { ...b, path: 'c.md' }]));
  assert.match(digestOf([a]), /^sha256:[0-9a-f]{64}$/);
});
