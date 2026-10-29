// node --test server.test.ts
//
// The server over an in-memory transport: what a client lists is the specs' tools with their hints, and a call goes through the runner. The spawned-process version of this, against the real contract, is smoke.test.ts.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CliContract } from '@tagents/core';
import { createServer } from '../src/server.ts';
import { toolSpecs } from '../src/tools.ts';

const cli: CliContract = {
  program: 'tagents-fake',
  exit: { ok: 0, error: 1, usage: 2, refused: 3 },
  commands: [
    { path: ['show'], positionals: ['<id>'], options: {}, required: [], summary: 'prints one thing', effect: 'read' },
    { path: ['forget'], positionals: ['<id>'], options: {}, required: [], summary: 'removes one thing', effect: 'destructive' },
  ],
};

async function connected(): Promise<{ client: Client; close: () => Promise<void> }> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-server-'));
  fs.writeFileSync(path.join(dir, 'tagents-fake'), '#!/bin/sh\nprintf \'{"args":"%s"}\' "$*"\n', { mode: 0o755 });
  const server = createServer(toolSpecs([cli]), { env: { PATH: `${dir}:/usr/bin:/bin` }, timeoutMs: 5000 });
  const client = new Client({ name: 'test', version: '0.0.0' });
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverSide), client.connect(clientSide)]);
  return { client, close: async () => void (await client.close(), await server.close()) };
}

test('a client lists one tool per verb, with the hints of its effect', async () => {
  const { client, close } = await connected();
  try {
    const { tools } = await client.listTools();
    assert.deepEqual(tools.map((t) => t.name), ['fake_forget', 'fake_show']);
    const show = tools.find((t) => t.name === 'fake_show');
    assert.deepEqual(show?.annotations, { readOnlyHint: true, openWorldHint: false });
    assert.equal(show?.description, 'Prints one thing.');
    assert.deepEqual(show?.inputSchema.required, ['id']);
  } finally {
    await close();
  }
});

test('a call runs the verb and answers with its result', async () => {
  const { client, close } = await connected();
  try {
    const result = await client.callTool({ name: 'fake_show', arguments: { id: 'abc' } });
    assert.notEqual(result.isError, true);
    const content = result.content;
    assert.ok(Array.isArray(content));
    const first: unknown = content[0];
    assert.ok(typeof first === 'object' && first !== null && 'text' in first && typeof first.text === 'string');
    assert.deepEqual(JSON.parse(first.text).stdout, { args: 'show abc' });
  } finally {
    await close();
  }
});

test('a call for a tool that does not exist is a protocol error, not a result', async () => {
  const { client, close } = await connected();
  try {
    await assert.rejects(client.callTool({ name: 'fake_nothing', arguments: {} }), /fake_nothing/);
  } finally {
    await close();
  }
});
