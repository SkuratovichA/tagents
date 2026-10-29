// node --test sources.test.ts
//
// The live sources: the real CLI specs, the real MCP server, the real scripts. The API reports are not collected here — fresh.test.ts covers them with the rest.
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { SERVER_NAME } from '../../knowledge/src/mcp/server.ts';
import { SERVER_NAME as TAGENTS_SERVER_NAME } from '../../mcp/src/server.ts';
import { BASH_SPEC, SCRIPT_NAMES, cliContracts, mcpServers, scriptEnv, scriptHelps, tagentsServer } from '../src/sources.ts';
import { REPO_ROOT } from '../src/tree.ts';

test('every CLI contract is present, each with verbs and exit codes: the three packages\' and the script\'s', async () => {
  const contracts = await cliContracts(REPO_ROOT);
  assert.deepEqual(contracts.map((c) => c.program), ['tagents-core', 'tagents-knowledge', 'tagents-notify', 'tagents']);
  for (const c of contracts) {
    assert.ok(c.commands.length > 0, c.program);
    assert.equal(c.exit['ok'], 0, c.program);
  }
});

test('the real MCP servers list tools with an object input schema, and the plugin\'s own is made from the CLI contracts', async () => {
  const cli = await cliContracts(REPO_ROOT);
  const servers = await mcpServers(cli);
  assert.deepEqual(servers.map((s) => s.name), [SERVER_NAME, TAGENTS_SERVER_NAME]);
  assert.deepEqual(servers[1], tagentsServer(cli));
  const tools = servers.flatMap((s) => s.tools);
  assert.ok(tools.length >= 1);
  for (const tool of tools) {
    assert.equal(tool.inputSchema['type'], 'object', tool.name);
    assert.notEqual(tool.description, '', tool.name);
  }
  for (const server of servers) {
    const names = server.tools.map((tool) => tool.name);
    assert.deepEqual(names, [...names].sort(), `${server.name}: tools are sorted by name, so registration order cannot churn the contract`);
  }
});

test('the verbs that stop or remove something are destructive, the ones that only print are read, and the ones that serve have no tool', async () => {
  const clis = await cliContracts(REPO_ROOT);
  const effectOf = (program: string, ...path: string[]): string | undefined =>
    clis.find((c) => c.program === program)?.commands.find((c) => c.path.join(' ') === path.join(' '))?.effect;
  assert.equal(effectOf('tagents-core', 'session', 'abort'), 'destructive');
  assert.equal(effectOf('tagents-core', 'plugin', 'remove'), 'destructive');
  assert.equal(effectOf('tagents-notify', 'uninstall'), 'destructive');
  assert.equal(effectOf('tagents-core', 'session', 'last'), 'read');
  assert.equal(effectOf('tagents-core', 'session', 'list'), 'read');
  assert.equal(effectOf('tagents-notify', 'status'), 'read');
  assert.equal(effectOf('tagents-notify', 'run'), 'serve');
  assert.equal(effectOf('tagents-knowledge', 'serve'), 'serve');
  assert.equal(effectOf('tagents', '--new'), 'spawn');
});

test('a verb that starts something says so in the first words of its description, because that is what a permission prompt shows', async () => {
  for (const cli of await cliContracts(REPO_ROOT)) {
    for (const command of cli.commands.filter((c) => c.effect === 'spawn')) {
      assert.match(command.summary, /^(starts|opens|runs|installs) /, `${cli.program} ${command.path.join(' ')}`);
    }
  }
});

test('the plugin\'s own tools include the ones the plugin exists to offer, each with its hints', async () => {
  const tools = new Map(tagentsServer(await cliContracts(REPO_ROOT)).tools.map((tool) => [tool.name, tool]));
  for (const name of ['notify_send', 'tagents_new', 'tagents_window', 'core_session_last', 'core_session_list']) {
    assert.ok(tools.has(name), name);
  }
  for (const name of ['core_session_open', 'core_session_prompt', 'core_session_abort', 'core_plugin_add', 'notify_install', 'notify_uninstall', 'knowledge_search']) {
    assert.ok(!tools.has(name), `${name} is a CLI verb marked tool: false`);
  }
  assert.deepEqual(tools.get('core_session_list')?.annotations, { readOnlyHint: true, openWorldHint: false });
  assert.equal(tools.get('tagents_new')?.annotations?.['readOnlyHint'], false);
  assert.ok(!tools.has('notify_run') && !tools.has('knowledge_mcp') && !tools.has('knowledge_serve'), 'a verb that serves until it is stopped is not a tool');
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

test('a script spec that is missing, is not JSON or is not a CLI contract stops generation and names the file and the reason', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'tagents-spec-'));
  try {
    await assert.rejects(cliContracts(root), /cannot read the CLI spec tagents\.cli\.json: .*ENOENT/);
    await writeFile(path.join(root, BASH_SPEC), '{ not json');
    await assert.rejects(cliContracts(root), /cannot read the CLI spec tagents\.cli\.json: /);
    await writeFile(path.join(root, BASH_SPEC), '{"program":"tagents"}');
    await assert.rejects(cliContracts(root), /cannot read the CLI spec tagents\.cli\.json: /);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
