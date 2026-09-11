// The MCP surface, driven the way a client drives it: spawn the binary, speak
// the protocol over stdio, call the tools, read what comes back.
//
// The child is started by the SDK transport and killed by closing it — a test
// that leaves an MCP server running is a test that leaves an MCP server
// running on the developer's machine forever.
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { z } from 'zod';
import { NODE, baseEnv, cliEntry, copyKnowledge, removeDir, tmpDir } from './helpers.ts';

const ResultSchema = z.object({
  content: z.array(z.object({ type: z.string(), text: z.string().optional() })),
  isError: z.boolean().optional(),
});

function textOf(result: unknown): string {
  return ResultSchema.parse(result)
    .content.map((c) => c.text ?? '')
    .join('');
}

function failed(result: unknown): boolean {
  return ResultSchema.parse(result).isError === true;
}

test('an MCP client can search, read and list over stdio', async (t) => {
  const root = tmpDir('mcp');
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  // No Claude account dirs: the sessions tools must answer, not explode.
  const homes = path.join(root, 'claude-homes');
  const transport = new StdioClientTransport({
    command: NODE,
    args: [cliEntry(), 'mcp'],
    env: baseEnv({
      TAGENTS_KNOWLEDGE_DIR: dir,
      TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite'),
      CLAUDE_HOMES: homes,
      HOME: os.homedir(),
    }),
    stderr: 'pipe',
  });
  const client = new Client({ name: 'knowledge-suite', version: '0.0.0' });
  t.after(async () => {
    await client.close();
    removeDir(root);
  });
  await client.connect(transport);

  const { tools } = await client.listTools();
  assert.deepEqual(
    tools.map((x) => x.name).sort(),
    ['knowledge_get', 'knowledge_list', 'knowledge_search', 'sessions_recent', 'sessions_search']
  );
  const search = tools.find((x) => x.name === 'knowledge_search');
  assert.equal(search?.inputSchema.type, 'object');
  assert.deepEqual(Object.keys(search?.inputSchema.properties ?? {}).sort(), [
    'kind',
    'limit',
    'query',
    'tag',
  ]);
  assert.deepEqual(search?.inputSchema.required, ['query']);

  const hits: unknown = JSON.parse(
    textOf(await client.callTool({ name: 'knowledge_search', arguments: { query: 'rollback' } }))
  );
  assert.ok(Array.isArray(hits) && hits.length >= 2);
  const first = hits[0] as { id: string; heading: string; snippet: string; score: number };
  assert.equal(first.id, 'deploy-runbook');
  assert.equal(first.heading, 'Rollback');
  assert.equal(typeof first.score, 'number');

  const russian: unknown = JSON.parse(
    textOf(await client.callTool({ name: 'knowledge_search', arguments: { query: 'бэкапы', limit: 5 } }))
  );
  assert.deepEqual(
    (russian as Array<{ id: string }>).map((h) => h.id),
    ['mashina-karta']
  );

  const whole = textOf(await client.callTool({ name: 'knowledge_get', arguments: { id: 'mashina-karta' } }));
  assert.match(whole, /^---\nid: mashina-karta/);
  assert.match(whole, /## Сервисы/);

  const section = textOf(
    await client.callTool({ name: 'knowledge_get', arguments: { id: 'mashina-karta', heading: 'Диски' } })
  );
  assert.match(section, /^## Диски\n\n/);
  assert.ok(!section.includes('Сервисы'));

  const missing = await client.callTool({ name: 'knowledge_get', arguments: { id: 'no-such-doc' } });
  assert.ok(failed(missing), 'an unknown id is a tool error, not an empty answer');

  const docs: unknown = JSON.parse(
    textOf(await client.callTool({ name: 'knowledge_list', arguments: { kind: 'runbook' } }))
  );
  assert.deepEqual(
    (docs as Array<{ id: string; headings: string[] }>).map((d) => d.id),
    ['deploy-runbook']
  );

  const recent = textOf(await client.callTool({ name: 'sessions_recent', arguments: { limit: 3 } }));
  assert.match(recent, /sessions\.mjs show <id-prefix>/);
  const found = textOf(await client.callTool({ name: 'sessions_search', arguments: { words: 'nothing here' } }));
  assert.match(found, /nothing matches/);
});

test('the server refuses politely when no knowledge directory is configured', async (t) => {
  const root = tmpDir('mcp-unset');
  const transport = new StdioClientTransport({
    command: NODE,
    args: [cliEntry(), 'mcp'],
    env: baseEnv({ TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite') }),
    stderr: 'pipe',
  });
  const client = new Client({ name: 'knowledge-suite', version: '0.0.0' });
  t.after(async () => {
    await client.close();
    removeDir(root);
  });
  await client.connect(transport);
  const result = await client.callTool({ name: 'knowledge_list', arguments: {} });
  assert.ok(failed(result));
  assert.match(textOf(result), /TAGENTS_KNOWLEDGE_DIR/);
});
