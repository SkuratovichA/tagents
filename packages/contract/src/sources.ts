// Where the contract is read from: the code itself. The two CLI specs and the MCP server are imported by relative path, not through the package names, because a package name resolves to a built dist and a stale dist would write a stale contract. The core CLI spec is the data file spec/cli/tagents-core.json, read live by the loader in core's cli/spec.ts; only the English text of its summary keys comes from core's catalogue.
import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { coreCliContract } from '../../core/src/cli/spec.ts';
import { knowledgeCliContract } from '../../knowledge/src/cli/spec.ts';
import { SERVER_NAME, createServer } from '../../knowledge/src/mcp/server.ts';
import { apiReports } from './api.ts';
import { createT, type Translate } from './i18n/index.ts';
import { isJsonObject, toJson } from './json.ts';
import { byCodeUnit } from './order.ts';
import type { CliContract, McpServerSpec, McpTool, Script, Sources } from './types.ts';

const run = promisify(execFile);

/** The scripts at the repo root that print their own help. */
export const SCRIPT_NAMES = ['tagents', 'tusage', 'tnotes'] as const;

export function cliContracts(): readonly CliContract[] {
  return [coreCliContract(), knowledgeCliContract()];
}

function toTool(tool: { name: string; description?: string | undefined; inputSchema: unknown; outputSchema?: unknown }, t: Translate): McpTool {
  const inputSchema = toJson(tool.inputSchema);
  if (!isJsonObject(inputSchema)) throw new Error(t('toolSchemaNotObject', { tool: tool.name }));
  const outputSchema = tool.outputSchema === undefined ? undefined : toJson(tool.outputSchema);
  if (outputSchema !== undefined && !isJsonObject(outputSchema)) {
    throw new Error(t('toolSchemaNotObject', { tool: tool.name }));
  }
  return {
    name: tool.name,
    description: tool.description ?? '',
    inputSchema,
    ...(outputSchema === undefined ? {} : { outputSchema }),
  };
}

/** The tools the knowledge server lists to a client linked to it in memory, sorted by name. No database is opened to list them. */
export async function mcpServers(t: Translate = createT()): Promise<readonly McpServerSpec[]> {
  const server = createServer({});
  const client = new Client({ name: 'tagents-contract', version: '0.0.0' });
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  try {
    await Promise.all([server.connect(serverSide), client.connect(clientSide)]);
    const tools: McpTool[] = [];
    let cursor: string | undefined;
    do {
      const page = await client.listTools(cursor === undefined ? {} : { cursor });
      tools.push(...page.tools.map((tool) => toTool(tool, t)));
      cursor = page.nextCursor;
    } while (cursor !== undefined);
    tools.sort((a, b) => byCodeUnit(a.name, b.name));
    return [{ name: SERVER_NAME, tools }];
  } finally {
    await client.close();
    await server.close();
  }
}

/** The environment a script runs in: the given home and the given `PATH` and nothing else from the parent, so the text cannot depend on the machine and the script cannot touch the real home. */
export function scriptEnv(home: string, searchPath: string | undefined): NodeJS.ProcessEnv {
  return { HOME: home, ...(searchPath === undefined ? {} : { PATH: searchPath }) };
}

/** `<script> --help` run with the caller's `PATH` and a throwaway home: `tusage` creates its state directory under `$HOME` before it reaches the help. */
export async function scriptHelps(root: string, t: Translate = createT()): Promise<readonly Script[]> {
  const home = await mkdtemp(path.join(tmpdir(), 'tagents-contract-home-'));
  const env = scriptEnv(home, process.env['PATH']);
  try {
    return await Promise.all(
      SCRIPT_NAMES.map(async (name): Promise<Script> => {
        try {
          const { stdout } = await run(path.join(root, name), ['--help'], { cwd: root, env, encoding: 'utf8' });
          return { name, help: stdout };
        } catch (error) {
          throw new Error(t('scriptFailed', { script: name, reason: error instanceof Error ? error.message : String(error) }));
        }
      })
    );
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

export async function collectSources(root: string, t: Translate = createT()): Promise<Sources> {
  const [mcp, scripts, api] = await Promise.all([mcpServers(t), scriptHelps(root, t), apiReports(root)]);
  return { cli: cliContracts(), mcp, api, scripts };
}
