#!/usr/bin/env node
// tagents-mcp --contract <contract.json>
//
// The plugin's own tools over stdio: one per verb of every structured CLI spec the contract records. The file is read once, at start; a plugin update brings a new file and the next session sees the new tools.
import fs from 'node:fs';
import { parseArgs } from 'node:util';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { cliContractsOf } from './contract-file.ts';
import { Calls } from './run.ts';
import { createServer } from './server.ts';
import { toolSpecs } from './tools.ts';

/** A call that has not ended in five minutes is stopped with its whole process group: a verb that takes longer than that is not one a tool call waits for, and the program's own timeout, where it has one, is shorter. */
const CALL_TIMEOUT_MS = 5 * 60 * 1000;
/** What a stopped group is given to leave on SIGTERM before it is killed, and the time the server then waits for the groups to be gone before it ends anyway. */
const KILL_GRACE_MS = 2000;
const SHUTDOWN_MARGIN_MS = 2000;
const END_SIGNALS = ['SIGTERM', 'SIGINT', 'SIGHUP'] as const;

/** The server ends when its client does: stdin closed or a signal. Whatever the calls in flight started is stopped first, because the client that asked for it is gone and nobody else would. */
function endWith(calls: Calls): void {
  let ending = false;
  const end = (): void => {
    if (ending) return;
    ending = true;
    setTimeout(() => process.exit(0), KILL_GRACE_MS + SHUTDOWN_MARGIN_MS).unref();
    void calls.stopAll().finally(() => process.exit(0));
  };
  // The SDK's stdio transport listens for data and errors only: it never learns that stdin ended.
  process.stdin.once('end', end);
  process.stdin.once('close', end);
  for (const signal of END_SIGNALS) process.once(signal, end);
}

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
    const calls = new Calls();
    await createServer(tools, { env: process.env, timeoutMs: CALL_TIMEOUT_MS, killGraceMs: KILL_GRACE_MS }, calls).connect(new StdioServerTransport());
    endWith(calls);
    return 0;
  } catch (error) {
    process.stderr.write(`tagents-mcp: ${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

// A server that connected stays up on the transport; only a failure to start has an exit code to set.
const code = await main(process.argv.slice(2));
if (code !== 0) process.exitCode = code;
