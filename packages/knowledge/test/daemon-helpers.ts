// Plumbing for the suites that start the shared server. Not a *.test.ts file on purpose, like helpers.ts.
//
// Everything runs in a "world": a short scratch directory that is TMPDIR for every process the case starts (so the sockets and pid files land inside it, and the machine's own server, which lives in the real TMPDIR, is never touched), with a `tagents-knowledge` first on PATH that runs THIS checkout's CLI (the machine's link points at the main checkout).
//
// A case may kill only what it started: a daemon is signalled only after `ps` shows the world's directory in its command line.
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { z } from 'zod';
import { NODE, PKG, baseEnv, cliEntry, copyKnowledge, doc, removeDir, writeDoc } from './helpers.ts';

export const BRIDGE = path.join(PKG, 'bin', 'knowledge-mcp');

export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export async function waitFor(what: string, ok: () => boolean | Promise<boolean>, ms = 8000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!(await ok())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(25);
  }
}

export interface World {
  /** TMPDIR of everything started here; short, because a socket address is 104 bytes on macOS. */
  readonly root: string;
  /** The directory the daemons keep their sockets and pid files in. */
  readonly sockDir: string;
  /** A directory of documents, a copy of the fixture corpus. */
  readonly docs: string;
  /** A directory whose only file is `tagents-knowledge`, running this checkout's CLI. */
  readonly bin: string;
  env(extra?: Record<string, string>): Record<string, string>;
}

/** An executable script in `dir`. */
export function writeScript(dir: string, name: string, lines: string[]): string {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  fs.writeFileSync(file, `${lines.join('\n')}\n`, { mode: 0o755 });
  return file;
}

export function makeWorld(): World {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tk-'));
  const bin = path.join(root, 'bin');
  writeScript(bin, 'tagents-knowledge', ['#!/bin/sh', `exec ${JSON.stringify(NODE)} ${JSON.stringify(cliEntry())} "$@"`]);
  const docs = copyKnowledge(path.join(root, 'docs'));
  const world: World = {
    root,
    sockDir: path.join(root, `tagents-${os.userInfo().uid}`),
    docs,
    bin,
    env: (extra = {}) =>
      baseEnv({
        PATH: `${bin}:${path.dirname(NODE)}:/usr/bin:/bin:/usr/sbin:/sbin`,
        TMPDIR: root,
        TAGENTS_KNOWLEDGE_DIR: docs,
        TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite'),
        // Nothing of the developer's Claude accounts: the sessions tools answer from an empty place.
        CLAUDE_HOMES: path.join(root, 'claude-homes'),
        ...extra,
      }),
  };
  return world;
}

/** A second corpus with one document that the fixture corpus does not have. */
export function otherDocs(world: World, id: string): string {
  const dir = path.join(world.root, `docs-${id}`);
  writeDoc(dir, `${id}.md`, doc({ id, title: `Only in ${id}` }));
  return dir;
}

export function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** The pids in the world's pid files, which is every daemon the world ever started and has not seen leave. */
export function daemonPids(world: World): number[] {
  let names: string[];
  try {
    names = fs.readdirSync(world.sockDir).filter((n) => n.endsWith('.pid'));
  } catch {
    return [];
  }
  return names.flatMap((n) => {
    const pid = Number(fs.readFileSync(path.join(world.sockDir, n), 'utf8').trim());
    return Number.isInteger(pid) && pid > 0 ? [pid] : [];
  });
}

export function sockets(world: World): string[] {
  try {
    return fs
      .readdirSync(world.sockDir)
      .filter((n) => n.endsWith('.sock'))
      .map((n) => path.join(world.sockDir, n));
  } catch {
    return [];
  }
}

/** The pids of every process whose command line names the world's directory: its daemons, and the `nc` of a bridge. */
function worldProcesses(world: World): number[] {
  const listing = spawnSync('ps', ['-A', '-o', 'pid=,command='], { encoding: 'utf8' }).stdout;
  return listing.split('\n').flatMap((line) => {
    const m = /^\s*(\d+)\s+(.*)$/.exec(line);
    return m?.[1] !== undefined && m[2]?.includes(world.root) && Number(m[1]) !== process.pid ? [Number(m[1])] : [];
  });
}

/** The one daemon the world has, once it has written its pid file (it does that a moment after it starts listening). */
export async function onlyDaemon(world: World): Promise<number> {
  await waitFor('the daemon\'s pid file', () => daemonPids(world).length === 1);
  const [pid] = daemonPids(world);
  if (pid === undefined) throw new Error('no daemon');
  return pid;
}

/**
 * Stop everything the world started, then remove it. A daemon that lost a race to another one exits by itself a moment after its starter has gone, and one that is still starting when the directory is removed would recreate it, so the sweep runs until the world has been empty for a moment.
 */
export async function disposeWorld(world: World): Promise<void> {
  for (let quiet = 0; quiet < 3; ) {
    const pids = worldProcesses(world);
    if (pids.length === 0) {
      quiet++;
      await sleep(100);
      continue;
    }
    quiet = 0;
    for (const pid of pids) {
      try {
        process.kill(pid, 'SIGTERM');
      } catch {
        // gone already
      }
    }
    await sleep(100);
  }
  removeDir(world.root);
}

const Message = z.object({
  id: z.number().optional(),
  result: z.unknown().optional(),
  error: z.unknown().optional(),
});

const Tools = z.object({ tools: z.array(z.object({ name: z.string() })) });
const ToolResult = z.object({ content: z.array(z.object({ text: z.string().optional() })) });

/** A process that speaks newline-delimited JSON-RPC on stdin and stdout, here the bridge script. */
export class Peer {
  readonly child: ChildProcessWithoutNullStreams;
  readonly exited: Promise<number | null>;
  private buffer = '';
  private nextId = 1;
  private readonly waiting = new Map<number, (m: z.infer<typeof Message>) => void>();

  constructor(command: string, args: string[], env: Record<string, string>) {
    this.child = spawn(command, args, { env, cwd: PKG });
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (chunk: string) => {
      this.buffer += chunk;
      for (let nl = this.buffer.indexOf('\n'); nl !== -1; nl = this.buffer.indexOf('\n')) {
        const line = this.buffer.slice(0, nl);
        this.buffer = this.buffer.slice(nl + 1);
        if (!line.trim()) continue;
        const message = Message.parse(JSON.parse(line));
        if (message.id !== undefined) this.waiting.get(message.id)?.(message);
      }
    });
    this.exited = new Promise((resolve) => this.child.once('close', (code) => resolve(code)));
  }

  /** Send a request and resolve with its `result`; an error reply or silence is a rejection. */
  request(method: string, params: Record<string, unknown> = {}, ms = 10000): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no answer to ${method} within ${ms} ms`)), ms);
      this.waiting.set(id, (m) => {
        clearTimeout(timer);
        if (m.error !== undefined) reject(new Error(`${method}: ${JSON.stringify(m.error)}`));
        else resolve(m.result);
      });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }

  /** The MCP opening: initialize, then the initialized notification. */
  async handshake(): Promise<void> {
    await this.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'daemon-suite', version: '0.0.0' },
    });
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
  }

  async toolNames(): Promise<string[]> {
    return Tools.parse(await this.request('tools/list')).tools.map((t) => t.name).sort();
  }

  async callText(name: string, args: Record<string, unknown> = {}): Promise<string> {
    const result = ToolResult.parse(await this.request('tools/call', { name, arguments: args }));
    return result.content.map((c) => c.text ?? '').join('');
  }

  /** Close stdin, which is how a session ends its server; resolve with the exit code. */
  async end(ms = 5000): Promise<number | null> {
    this.child.stdin.end();
    const timer = setTimeout(() => this.child.kill('SIGKILL'), ms);
    try {
      return await this.exited;
    } finally {
      clearTimeout(timer);
    }
  }
}

export const TOOL_NAMES = [
  'knowledge_get',
  'knowledge_list',
  'knowledge_search',
  'knowledge_usage',
  'sessions_recent',
  'sessions_search',
];

/** A session's MCP server as the plugin starts it: `sh bin/knowledge-mcp`. */
export function startBridge(world: World, extra: Record<string, string> = {}): Peer {
  return new Peer('sh', [BRIDGE], world.env(extra));
}
