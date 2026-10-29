// Where the contract is read from: the code itself. The two CLI specs and the MCP server are imported by relative path, not through the package names, because a package name resolves to a built dist and a stale dist would write a stale contract.
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { coreCliContract } from '../../core/src/cli/spec.ts';
import { knowledgeCliContract } from '../../knowledge/src/cli/spec.ts';
import { SERVER_NAME, createServer } from '../../knowledge/src/mcp/server.ts';
import { parseCliContract } from '../../mcp/src/contract-file.ts';
import { SERVER_NAME as TAGENTS_SERVER_NAME } from '../../mcp/src/server.ts';
import { toolSpecs } from '../../mcp/src/tools.ts';
import { notifyCliContract } from '../../notify/src/cli/spec.ts';
import { apiReports } from './api.ts';
import { createT, type Translate } from './i18n/index.ts';
import { isJsonObject, toJson } from './json.ts';
import { byCodeUnit } from './order.ts';
import type { CliContract, McpServerSpec, McpTool, Script, Sources } from './types.ts';

const run = promisify(execFile);

/** The scripts at the repo root that print their own help. */
export const SCRIPT_NAMES = ['tagents', 'tusage', 'tnotes'] as const;

/** The bash script has no argument parser to read, so its verbs are a file of their own, which test/bash-spec.test.ts pins to `tagents --help`. */
export const BASH_SPEC = 'tagents.cli.json';

/** Every CLI the plugin has: the three packages' own specs and the script's file. */
export async function cliContracts(root: string, t: Translate = createT()): Promise<readonly CliContract[]> {
  let script: CliContract;
  try {
    script = parseCliContract(JSON.parse(await readFile(path.join(root, BASH_SPEC), 'utf8')));
  } catch (error) {
    throw new Error(t('cliSpecUnreadable', { file: BASH_SPEC, reason: error instanceof Error ? error.message : String(error) }));
  }
  return [coreCliContract(), knowledgeCliContract(), notifyCliContract(), script];
}

function toTool(tool: { name: string; description?: string | undefined; inputSchema: unknown; outputSchema?: unknown; annotations?: unknown }, t: Translate): McpTool {
  const inputSchema = toJson(tool.inputSchema);
  if (!isJsonObject(inputSchema)) throw new Error(t('toolSchemaNotObject', { tool: tool.name }));
  const outputSchema = tool.outputSchema === undefined ? undefined : toJson(tool.outputSchema);
  if (outputSchema !== undefined && !isJsonObject(outputSchema)) {
    throw new Error(t('toolSchemaNotObject', { tool: tool.name }));
  }
  const annotations = tool.annotations === undefined ? undefined : toJson(tool.annotations);
  if (annotations !== undefined && !isJsonObject(annotations)) throw new Error(t('toolSchemaNotObject', { tool: tool.name }));
  return {
    name: tool.name,
    description: tool.description ?? '',
    inputSchema,
    ...(outputSchema === undefined ? {} : { outputSchema }),
    ...(annotations === undefined ? {} : { annotations }),
  };
}

/** The plugin's own server: a tool for each verb of the CLI specs, made by the same function the server runs on at start, so what contract.json records is what a client is offered. */
export function tagentsServer(cli: readonly CliContract[], t: Translate = createT()): McpServerSpec {
  return { name: TAGENTS_SERVER_NAME, tools: toolSpecs(cli).map((tool) => toTool(tool, t)) };
}

/** The tools the knowledge server lists to a client linked to it in memory, sorted by name (no database is opened to list them), and the plugin's own server made from the CLI specs. */
export async function mcpServers(cli: readonly CliContract[], t: Translate = createT()): Promise<readonly McpServerSpec[]> {
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
    return [{ name: SERVER_NAME, tools }, tagentsServer(cli, t)];
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
  const cli = await cliContracts(root, t);
  const [mcp, scripts, api] = await Promise.all([mcpServers(cli, t), scriptHelps(root, t), apiReports(root)]);
  return { cli, mcp, api, scripts };
}
