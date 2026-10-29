#!/usr/bin/env node
// tagents-mcp --contract <contract.json>
//
// The plugin's own tools over stdio: one per verb of every structured CLI spec the contract records. The file is read once, at start; a plugin update brings a new file and the next session sees the new tools.
import fs from 'node:fs';
import { parseArgs } from 'node:util';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { cliContractsOf } from './contract-file.ts';
import { createServer } from './server.ts';
import { toolSpecs } from './tools.ts';

/** A backstop for a verb that hangs, not a limit on a long one: a headless turn is given 50 minutes by tagents-core itself (`DEFAULT_TIMEOUT_MS`), and its own timeout should be the one that ends it. */
const CALL_TIMEOUT_MS = 60 * 60 * 1000;

async function main(argv: readonly string[]): Promise<number> {
  let contract: string | undefined;
  try {
    contract = parseArgs({ args: [...argv], options: { contract: { type: 'string' } }, strict: true }).values.contract;
  } catch {
    contract = undefined;
  }
  if (contract === undefined) {
    process.stderr.write('usage: tagents-mcp --contract <contract.json>\n');
    return 2;
  }
  try {
    const tools = toolSpecs(cliContractsOf(fs.readFileSync(contract, 'utf8')));
    await createServer(tools, { env: process.env, timeoutMs: CALL_TIMEOUT_MS }).connect(new StdioServerTransport());
    return 0;
  } catch (error) {
    process.stderr.write(`tagents-mcp: ${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

// A server that connected stays up on the transport; only a failure to start has an exit code to set.
const code = await main(process.argv.slice(2));
if (code !== 0) process.exitCode = code;
