// The two files the Rust binary embeds, compared with the program they were written from: the `tools/list` of this MCP server and the sentences of the catalogue that `serve` prints. `node tests/rust-knowledge-embed.mts` writes them; a tool, a description or a text that moves fails here until it is run again.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { JSONRPCMessage } from '@modelcontextprotocol/sdk/types.js';
import { en } from '../src/i18n/en.ts';
import { ru } from '../src/i18n/ru.ts';
import { createServer } from '../src/mcp/server.ts';

const EMBEDDED = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../crates/tagents-core/src/knowledge');
const REGENERATE = 'run `node tests/rust-knowledge-embed.mts`';

function readEmbedded(name: string): unknown {
  return JSON.parse(fs.readFileSync(path.join(EMBEDDED, name), 'utf8'));
}

/** The `tools/list` result of the server, as it goes over the wire: no client schema in between to drop a key, and the JSON round trip a stdio transport does, which drops the keys the SDK leaves `undefined`. */
async function listedTools(): Promise<unknown> {
  const server = createServer({});
  const [client, serverSide] = InMemoryTransport.createLinkedPair();
  const response = new Promise<JSONRPCMessage>((resolve) => {
    client.onmessage = (message) => {
      if ('id' in message && message.id === 1) resolve(message);
    };
  });
  await server.connect(serverSide);
  await client.start();
  await client.send({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
  const message = await response;
  await server.close();
  assert.ok('result' in message, 'tools/list did not answer a result');
  return JSON.parse(JSON.stringify(message.result['tools']));
}

test('tools.json is the tools/list of the server, entry by entry and key by key', async () => {
  const listed = await listedTools();
  assert.deepEqual(readEmbedded('tools.json'), listed, `tools.json differs from the server: ${REGENERATE}`);
  assert.equal(
    JSON.stringify(readEmbedded('tools.json')),
    JSON.stringify(listed),
    `tools.json keeps the keys in another order than the server writes them: ${REGENERATE}`
  );
});

test('texts.json holds badIdle and serveFailed of the catalogue in both languages', () => {
  assert.deepEqual(
    readEmbedded('texts.json'),
    {
      en: { badIdle: en.badIdle, serveFailed: en.serveFailed },
      ru: { badIdle: ru.badIdle, serveFailed: ru.serveFailed },
    },
    `texts.json differs from the catalogue: ${REGENERATE}`
  );
});
