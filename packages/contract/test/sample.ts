// Sample inputs the unit tests drive the pure stages with. Not a test file: the runner's glob only picks up *.test.ts.
import { buildContract } from '../src/contract.ts';
import type { Disk, Plan } from '../src/plan.ts';
import { stringifyJson } from '../src/json.ts';
import type { ApiReport, CliContract, McpServerSpec, McpTool, Sources } from '../src/types.ts';

export const sampleCli: CliContract = {
  program: 'demo-cli',
  exit: { ok: 0, error: 1, usage: 2 },
  commands: [
    {
      path: ['session', 'open'],
      positionals: [],
      options: { cwd: { type: 'string' }, tag: { type: 'string', multiple: true }, json: { type: 'boolean' } },
      required: ['cwd'],
      summary: 'starts a session',
    },
    {
      path: ['search'],
      positionals: ['<query…>'],
      options: { limit: { type: 'string' } },
      required: [],
      summary: 'searches | and prints',
    },
  ],
};

export const sampleTool: McpTool = {
  name: 'demo_search',
  description: 'Searches the demo documents.',
  inputSchema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'words to look for' },
      limit: { type: 'integer', description: 'how many' },
      kinds: { type: 'array', items: { type: 'string' } },
    },
    required: ['query'],
  },
};

export const sampleServer: McpServerSpec = { name: 'demo-server', tools: [sampleTool] };

export const sampleApi: ApiReport = { package: '@demo/core', file: 'core.api.md', markdown: '# core api\n\nexport function f(): void;\n' };

export const sampleHelp = 'usage: tagents [--flag]\n\n  --flag   does a thing\n';

export function sampleSources(): Sources {
  return {
    cli: [sampleCli],
    mcp: [sampleServer],
    api: [sampleApi],
    scripts: [{ name: 'tagents', help: sampleHelp }],
  };
}

export const SAMPLE_PLUGIN = {
  $schema: 'https://example.invalid/plugin.schema.json',
  name: 'demo',
  version: '0.1.0',
  description: 'a demo plugin',
  author: { name: 'someone' },
  repository: 'https://example.invalid/repo',
  license: 'MIT',
  mcpServers: { knowledge: { command: 'demo', args: ['mcp'] } },
};

export function sampleDisk(): Disk {
  return {
    files: new Map<string, string | Uint8Array>([
      ['.claude-plugin/plugin.json', JSON.stringify(SAMPLE_PLUGIN)],
      ['.claude-plugin/marketplace.json', '{"name":"demo"}\n'],
      ['skills/tagents/SKILL.md', '# the skill\n'],
    ]),
  };
}

/** The disk after a plan is applied to it: what running the generator would leave behind. */
export function applied(disk: Disk, plan: Plan): Disk {
  const files = new Map(disk.files);
  for (const path of plan.deletes) files.delete(path);
  for (const [path, content] of plan.writes) files.set(path, content);
  return { files };
}

export const contractText = (sources: Sources): string => stringifyJson(buildContract(sources));

/** A copy of the sample sources with the CLI contract replaced. */
export function withCli(cli: CliContract): Sources {
  return { ...sampleSources(), cli: [cli] };
}
