// Where the contract is read from: the code itself. The specs of core and notify are imported by relative path, not through the package names, because a package name resolves to a built dist and a stale dist would write a stale contract. The core CLI spec is the data file spec/cli/tagents-core.json, read live by the loader in core's cli/spec.ts; only the English text of its summary keys comes from core's catalogue.
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { z } from 'zod';
import { coreCliContract } from '../../core/src/cli/spec.ts';
import { notifyCliContract } from '../../notify/src/cli/spec.ts';
import { apiReports } from './api.ts';
import { parseCliContract } from './contract-file.ts';
import { createT, type Translate } from './i18n/index.ts';
import { isJsonObject, toJson } from './json.ts';
import { byCodeUnit } from './order.ts';
import { KNOWLEDGE_SERVER_NAME } from './plugins.ts';
import { toolSpecs } from './tools.ts';
import type { CliContract, McpServerSpec, McpTool, Script, Sources } from './types.ts';

const run = promisify(execFile);

/** The scripts at the repo root that print their own help. */
export const SCRIPT_NAMES = ['tagents', 'tusage', 'tnotes'] as const;

/** The bash script has no argument parser to read, so its verbs are a file of their own, which test/bash-spec.test.ts pins to `tagents --help`. */
export const BASH_SPEC = 'tagents.cli.json';

/** The verbs of `okb`, which the binary prints with `okb --spec` and a test of the crate pins to the file. */
export const OKB_SPEC = 'spec/cli/okb.json';

async function readCliFile(root: string, file: string, t: Translate): Promise<CliContract> {
  try {
    return parseCliContract(JSON.parse(await readFile(path.join(root, file), 'utf8')));
  } catch (error) {
    throw new Error(t('cliSpecUnreadable', { file, reason: error instanceof Error ? error.message : String(error) }));
  }
}

/** Every CLI the plugin has: the specs of core and notify, the data files of okb and of the script. */
export async function cliContracts(root: string, t: Translate = createT()): Promise<readonly CliContract[]> {
  const script = await readCliFile(root, BASH_SPEC, t);
  return [coreCliContract(), await readCliFile(root, OKB_SPEC, t), notifyCliContract(), script];
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

/** The plugin's own server: a tool for each verb of the CLI specs, made by the same function the server runs on at start, and the tools the server answers itself (`answered`), so what contract.json records is what a client is offered. */
export function tagentsServer(cli: readonly CliContract[], t: Translate = createT(), answered: readonly McpTool[] = []): McpServerSpec {
  const tools = [...toolSpecs(cli).map((tool) => toTool(tool, t)), ...answered];
  tools.sort((a, b) => byCodeUnit(a.name, b.name));
  return { name: TAGENTS_SERVER_NAME, tools };
}

/** The name the plugin's own server goes by in the contract; the knowledge server's is in plugins.ts, with the plugin that owns it. */
export const TAGENTS_SERVER_NAME = 'tagents';

/** The `tools/list` of the knowledge server, which the binary serves and embeds: the file was written from the node server before it was deleted, and is frozen. */
export const KNOWLEDGE_TOOLS_FILE = 'crates/okb/src/knowledge/tools.json';

/** The `tools/list` entries of the two session tools, which the tagents server answers itself and which no CLI verb stands behind. */
export const SESSION_TOOLS_FILE = 'crates/tagents-core/src/mcp/sessions_tools.json';

/** One entry of the frozen tool list: the fields `toTool` reads; the schemas are checked there. */
const FrozenTool = z.object({
  name: z.string(),
  description: z.string().optional(),
  inputSchema: z.unknown(),
  outputSchema: z.unknown().optional(),
  annotations: z.unknown().optional(),
});

/** The tools of a frozen list, with `$schema` last in each schema unless `keepOrder` says the server lists them as the file has them. */
async function frozenTools(root: string, file: string, t: Translate, keepOrder = false): Promise<McpTool[]> {
  const parsed = z.array(FrozenTool).safeParse(JSON.parse(await readFile(path.join(root, file), 'utf8')));
  if (!parsed.success) throw new Error(`${file} is not a list of tools: ${parsed.error.message}`);
  // The SDK wrote `$schema` after the other keys of an input schema; the file has it first, and the contract keeps the order it had.
  const schemaLast = (schema: unknown): unknown => {
    if (keepOrder || typeof schema !== 'object' || schema === null || !('$schema' in schema)) return schema;
    const { $schema, ...rest } = schema;
    return { ...rest, $schema };
  };
  return parsed.data.map((tool) => toTool({ ...tool, inputSchema: schemaLast(tool.inputSchema), outputSchema: schemaLast(tool.outputSchema) }, t));
}

/** The tools the knowledge server lists, sorted by name, and the plugin's own server made from the CLI specs and the session tools. */
export async function mcpServers(cli: readonly CliContract[], t: Translate = createT(), root: string = fileURLToPath(new URL('../../../', import.meta.url))): Promise<readonly McpServerSpec[]> {
  const tools = await frozenTools(root, KNOWLEDGE_TOOLS_FILE, t);
  tools.sort((a, b) => byCodeUnit(a.name, b.name));
  return [{ name: KNOWLEDGE_SERVER_NAME, tools }, tagentsServer(cli, t, await frozenTools(root, SESSION_TOOLS_FILE, t, true))];
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
  const [mcp, scripts, api] = await Promise.all([mcpServers(cli, t, root), scriptHelps(root, t), apiReports(root)]);
  return { cli, mcp, api, scripts };
}
