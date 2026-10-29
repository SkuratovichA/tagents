// node --test smoke.test.ts
//
// The server as a client starts it: a process on stdio, reading the real contract.json. What it lists is what the contract records for the server, and one read-only tool answers against a scratch config and state directory. The program behind the tool is the real tagents-core run from source, found through a PATH that holds nothing else of the machine's.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const CONTRACT = path.join(ROOT, 'contract.json');

interface ListedTool {
  readonly name: string;
  readonly description?: string | undefined;
  readonly inputSchema: unknown;
  readonly annotations?: unknown;
}

function recordedTools(): ListedTool[] {
  const parsed: unknown = JSON.parse(fs.readFileSync(CONTRACT, 'utf8'));
  assert.ok(typeof parsed === 'object' && parsed !== null && 'mcp' in parsed);
  const mcp: unknown = parsed.mcp;
  assert.ok(typeof mcp === 'object' && mcp !== null && 'tagents' in mcp);
  const server: unknown = mcp.tagents;
  assert.ok(typeof server === 'object' && server !== null && 'tools' in server && Array.isArray(server.tools));
  return server.tools;
}

test('tools/list is the list the contract records, and a read-only tool answers against scratch state', async () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-smoke-'));
  const bin = path.join(scratch, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'tagents-core'), `#!/bin/sh\nexec node ${path.join(ROOT, 'packages', 'core', 'src', 'cli', 'main.ts')} "$@"\n`, { mode: 0o755 });
  const nodeDir = path.dirname(process.execPath);
  const client = new Client({ name: 'smoke', version: '0.0.0' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.join(ROOT, 'packages', 'mcp', 'src', 'main.ts'), '--contract', CONTRACT],
    env: {
      PATH: `${bin}:${nodeDir}:/usr/bin:/bin`,
      HOME: scratch,
      TAGENTS_CONFIG_DIR: path.join(scratch, 'config'),
      TA_STATE_DIR: path.join(scratch, 'state'),
    },
    stderr: 'pipe',
  });
  try {
    await client.connect(transport);
    const { tools } = await client.listTools();
    const listed = tools.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema, annotations: t.annotations }));
    assert.deepEqual(JSON.parse(JSON.stringify(listed)), recordedTools().map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema, annotations: t.annotations })));

    const result = await client.callTool({ name: 'core_plugin_list', arguments: { json: true } });
    assert.notEqual(result.isError, true);
    const content = result.content;
    assert.ok(Array.isArray(content));
    const first: unknown = content[0];
    assert.ok(typeof first === 'object' && first !== null && 'text' in first && typeof first.text === 'string');
    const body = JSON.parse(first.text);
    assert.equal(body.exit, 0);
    assert.equal(body.outcome, 'ok');
  } finally {
    await client.close();
  }
});
