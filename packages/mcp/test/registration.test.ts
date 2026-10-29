// node --test registration.test.ts
//
// The manifest is hand-written where it names a server, so the one thing worth pinning is that the entry for this server starts what this package builds, against the contract that ships beside the manifest.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function entry(): { readonly command: unknown; readonly args: unknown } {
  const manifest: unknown = JSON.parse(fs.readFileSync(path.join(ROOT, '.claude-plugin', 'plugin.json'), 'utf8'));
  assert.ok(typeof manifest === 'object' && manifest !== null && 'mcpServers' in manifest);
  const servers: unknown = manifest.mcpServers;
  assert.ok(typeof servers === 'object' && servers !== null && 'tagents' in servers, 'plugin.json has no mcpServers.tagents');
  const server: unknown = servers.tagents;
  assert.ok(typeof server === 'object' && server !== null && 'command' in server && 'args' in server);
  return server;
}

test('plugin.json registers the server as tagents-mcp, reading the contract.json that ships with the plugin', () => {
  const server = entry();
  assert.equal(server.command, 'tagents-mcp');
  assert.deepEqual(server.args, ['--contract', '${CLAUDE_PLUGIN_ROOT}/contract.json']);
});

test('the command the manifest names is the bin this package declares', () => {
  const pkg: unknown = JSON.parse(fs.readFileSync(path.join(ROOT, 'packages', 'mcp', 'package.json'), 'utf8'));
  assert.ok(typeof pkg === 'object' && pkg !== null && 'bin' in pkg && typeof pkg.bin === 'object' && pkg.bin !== null);
  assert.deepEqual(Object.keys(pkg.bin), [entry().command]);
});
