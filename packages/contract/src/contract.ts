// contract.json: the plugin's contract as data, for a script that wants to check a verb or a tool schema without reading markdown.
import { sha256 } from './hash.ts';
import { toJson, type JsonObject } from './json.ts';
import type { Sources } from './types.ts';

export const CONTRACT_VERSION = 1;

/** What an API report is pinned by in contract.json: the hash of its markdown, not the markdown. */
export const apiHash = (markdown: string): string => `sha256:${sha256(markdown)}`;

export function buildContract(sources: Sources): JsonObject {
  return {
    contractVersion: CONTRACT_VERSION,
    cli: Object.fromEntries(
      sources.cli.map((c) => [
        c.program,
        {
          exit: toJson(c.exit),
          commands: c.commands.map((command) => ({
            path: command.path,
            positionals: command.positionals,
            options: toJson(command.options),
            required: command.required,
            summary: command.summary,
            ...(command.effect === undefined ? {} : { effect: command.effect }),
            ...(command.requires === undefined ? {} : { requires: command.requires }),
          })),
        },
      ])
    ),
    mcp: Object.fromEntries(
      sources.mcp.map((server) => [
        server.name,
        {
          tools: server.tools.map((tool) => ({
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
            ...(tool.outputSchema === undefined ? {} : { outputSchema: tool.outputSchema }),
            ...(tool.annotations === undefined ? {} : { annotations: tool.annotations }),
          })),
        },
      ])
    ),
    api: Object.fromEntries(sources.api.map((report) => [report.package, apiHash(report.markdown)])),
  };
}
