// The MCP server: the tools it is given, listed with their hints, and a call that runs the verb behind the tool. It is given the tools and knows no verb; which tools there are comes from the CLI specs through tools.ts.
//
// stdout belongs to the JSON-RPC framing. Nothing in this package may print to it.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema, ErrorCode, ListToolsRequestSchema, McpError } from '@modelcontextprotocol/sdk/types.js';
import { callTool, type RunDeps } from './run.ts';
import type { ToolSpec } from './tools.ts';

export const SERVER_NAME = 'tagents';
export const SERVER_VERSION = '0.1.0';

export function createServer(tools: readonly ToolSpec[], deps: RunDeps): Server {
  const server = new Server({ name: SERVER_NAME, version: SERVER_VERSION }, { capabilities: { tools: {} } });
  const byName = new Map(tools.map((tool) => [tool.name, tool]));

  server.setRequestHandler(ListToolsRequestSchema, () => ({
    tools: tools.map((tool) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: { ...tool.inputSchema, required: [...tool.inputSchema.required] },
      annotations: tool.annotations,
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const tool = byName.get(request.params.name);
    if (tool === undefined) throw new McpError(ErrorCode.InvalidParams, `unknown tool ${request.params.name}`);
    const result = await callTool(tool, request.params.arguments ?? {}, deps);
    return { isError: result.isError, content: [...result.content] };
  });

  return server;
}
