// node --test render.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createT } from '../src/i18n/index.ts';
import { renderCli, renderMcp, renderScripts, schemaType, usageLine } from '../src/render.ts';
import { sampleCli, sampleHelp, sampleServer, sampleTool } from './sample.ts';

const t = createT();

test('every verb path and every flag of the contract is in cli.md', () => {
  const md = renderCli([sampleCli], t);
  assert.match(md, /^## demo-cli$/m);
  for (const command of sampleCli.commands) {
    assert.ok(md.includes(`### ${command.path.join(' ')}`), command.path.join(' '));
    assert.ok(md.includes(command.summary), command.summary);
    assert.ok(md.includes(usageLine('demo-cli', command)), 'usage');
    for (const flag of Object.keys(command.options)) assert.ok(md.includes(`\`--${flag}\``), flag);
  }
  for (const [outcome, code] of Object.entries(sampleCli.exit)) assert.ok(md.includes(`| ${code} | ${outcome} |`), outcome);
});

test('the usage line follows the spec: positionals first, flags in spec order, required ones without brackets', () => {
  const [open, search] = sampleCli.commands;
  assert.ok(open && search);
  assert.equal(usageLine('demo-cli', open), 'demo-cli session open --cwd <cwd> [--tag <tag>…] [--json]');
  assert.equal(usageLine('demo-cli', search), 'demo-cli search <query…> [--limit <limit>]');
});

test('the flags table says what is required and what repeats', () => {
  const md = renderCli([sampleCli], t);
  assert.ok(md.includes('| `--cwd` | string | yes | no |'));
  assert.ok(md.includes('| `--tag` | string | no | yes |'));
  assert.ok(md.includes('| `--json` | boolean | no | no |'));
});

test('a pipe or a newline in an input description cannot break a table row', () => {
  const noisy = { ...sampleTool, name: 'noisy', inputSchema: { type: 'object', properties: { a: { type: 'string', description: 'x | y\nz' } } } };
  assert.ok(renderMcp([{ name: 's', tools: [noisy] }], t).includes('| x \\| y z |'));
});

test('every tool name and every input is in mcp.md, with the raw schema', () => {
  const md = renderMcp([sampleServer], t);
  assert.match(md, /^## demo-server$/m);
  assert.ok(md.includes(`### ${sampleTool.name}`));
  assert.ok(md.includes(sampleTool.description));
  assert.ok(md.includes('| `query` | string | yes | words to look for |'));
  assert.ok(md.includes('| `limit` | integer | no | how many |'));
  assert.ok(md.includes('| `kinds` | string[] | no |  |'));
  assert.ok(md.includes(JSON.stringify(sampleTool.inputSchema, null, 2)));
  assert.ok(!md.includes(t('outputSchema')), 'a tool without an output schema has no such section');
});

test('an output schema gets its own block and a tool without inputs says so', () => {
  const md = renderMcp([{ name: 's', tools: [{ name: 'ping', description: 'pong', inputSchema: { type: 'object' }, outputSchema: { type: 'object', properties: { ok: { type: 'boolean' } } } }] }], t);
  assert.ok(md.includes(t('noInputs')));
  assert.ok(md.includes(`#### ${t('outputSchema')}`));
  assert.ok(md.includes('"ok"'));
});

test('schemaType reads enums, unions and arrays', () => {
  assert.equal(schemaType({ enum: ['a', 'b'] }, t), '"a" | "b"');
  assert.equal(schemaType({ anyOf: [{ type: 'string' }, { type: 'null' }] }, t), 'string | null');
  assert.equal(schemaType({ type: ['string', 'null'] }, t), 'string | null');
  assert.equal(schemaType({ type: 'array', items: { type: 'integer' } }, t), 'integer[]');
  assert.equal(schemaType({}, t), t('typeUnspecified'));
});

test('a script help is reproduced verbatim, even one that contains a code fence', () => {
  const tricky = '```\nnot the end\n```\nlast line';
  const md = renderScripts(
    [
      { name: 'tagents', help: sampleHelp },
      { name: 'tricky', help: tricky },
    ],
    t
  );
  assert.ok(md.includes(sampleHelp));
  assert.ok(md.includes(tricky));
  assert.ok(md.includes('````text\n'), 'the fence is longer than any run inside the help');
});

test('rendering is deterministic and ends in one newline', () => {
  const md = renderCli([sampleCli], t);
  assert.equal(md, renderCli([sampleCli], t));
  assert.ok(md.endsWith('\n') && !md.endsWith('\n\n'));
  assert.ok(!md.includes('\r'));
});
