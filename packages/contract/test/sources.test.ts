// node --test sources.test.ts
//
// The live sources: the real CLI specs, the real MCP server, the real scripts. The API reports are not collected here — fresh.test.ts covers them with the rest.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SERVER_NAME } from '../../knowledge/src/mcp/server.ts';
import { SCRIPT_NAMES, cliContracts, mcpServers, scriptEnv, scriptHelps } from '../src/sources.ts';
import { REPO_ROOT } from '../src/tree.ts';

test('both CLI contracts are present, each with verbs and exit codes', () => {
  const contracts = cliContracts();
  assert.deepEqual(contracts.map((c) => c.program), ['tagents-core', 'tagents-knowledge']);
  for (const c of contracts) {
    assert.ok(c.commands.length > 0, c.program);
    assert.equal(c.exit['ok'], 0, c.program);
  }
});

test('the real MCP server lists at least one tool with an object input schema', async () => {
  const servers = await mcpServers();
  assert.deepEqual(servers.map((s) => s.name), [SERVER_NAME]);
  const tools = servers.flatMap((s) => s.tools);
  assert.ok(tools.length >= 1);
  for (const tool of tools) {
    assert.equal(tool.inputSchema['type'], 'object', tool.name);
    assert.notEqual(tool.description, '', tool.name);
  }
  const names = tools.map((tool) => tool.name);
  assert.deepEqual(names, [...names].sort(), 'tools are sorted by name, so registration order cannot churn the contract');
});

test('each script prints a non-empty help that does not depend on the machine', async () => {
  const scripts = await scriptHelps(REPO_ROOT);
  assert.deepEqual(scripts.map((s) => s.name), [...SCRIPT_NAMES]);
  const home = process.env['HOME'];
  for (const s of scripts) {
    assert.notEqual(s.help.trim(), '', s.name);
    assert.ok(!s.help.includes('\r'), s.name);
    if (home !== undefined && home.length > 1) assert.ok(!s.help.includes(home), `${s.name} prints the home directory`);
  }
});

test('the script environment is the given home and the given PATH and nothing else', () => {
  assert.deepEqual(scriptEnv('/tmp/throwaway', '/opt/bin:/usr/bin'), { HOME: '/tmp/throwaway', PATH: '/opt/bin:/usr/bin' });
  assert.deepEqual(scriptEnv('/tmp/throwaway', undefined), { HOME: '/tmp/throwaway' });
});
