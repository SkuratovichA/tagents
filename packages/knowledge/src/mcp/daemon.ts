// One knowledge server for every session that has the same environment.
//
// `runMcp` (server.ts) is one node process per Claude session: about 30 MB resident each, started and stopped with the session. This file is the other arrangement. A daemon listens on a unix socket and gives every connection its own MCP server over the same stdio framing; a session reaches it through `nc -U` (bin/knowledge-mcp), which costs a few hundred kilobytes.
//
//   ensureDaemon  — what `tagents-knowledge serve` does: find the daemon for this environment, or start one detached, and say where it listens.
//   runDaemon     — what `serve --foreground` does, and what ensureDaemon starts: listen, serve, and leave after a quiet spell.
//
// Races this has to survive: sessions that start together (a reboot resurrects many at once) all ask for a daemon in the same few milliseconds; and a daemon that died hard leaves a socket file behind that refuses connections. The first is settled by the kernel: bind() on a taken name fails with EADDRINUSE, and the loser finds a live server and leaves. The second is settled under a lock, so two daemons that both see the dead file do not unlink each other's fresh one.
//
// stdout and stderr of the daemon are /dev/null. Nothing in here may print, except what a fault leaves on stderr (see `fault`): a first line, `tagents-knowledge: <what>: <message or first stack line>`, followed by the rest of the error's stack, which goes to /dev/null too when the daemon is detached and to the terminal under `serve --foreground`.
//
// ONE BAD CONNECTION MUST NOT END THE DAEMON. It is shared: every session's tools go through it, since the bridge `exec`s into `nc` and has no server of its own to fall back on once the daemon is gone. So a failure while a connection is being set up destroys that connection and nothing else, and an exception that nothing caught (a late callback, a rejected promise) is logged and the daemon keeps serving. Two things stay as they are on purpose: the server does not set `allowHalfOpen`, so a peer that closes its writing side (which is what `nc -U` does when its stdin ends) is closed on the daemon's side at once and is released, and the idle timer then runs; and a signal still stops the daemon.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './server.ts';
import {
  CLI_ENTRY,
  canonicalEnv,
  codeStamp,
  ensurePrivateDir,
  lockDirOf,
  pidFileOf,
  probe,
  socketPath,
} from './socket.ts';

export const DEFAULT_IDLE_SECONDS = 600;
/** How long `serve` waits for a daemon it started to accept connections. */
const START_WAIT_MS = 8000;
const POLL_MS = 10;
/** A lock older than this was left by a daemon that died inside the critical section, which takes milliseconds. */
const LOCK_STALE_MS = 3000;
const LOCK_WAIT_MS = 5000;
const BIND_ATTEMPTS = 5;

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** The socket for this process's environment, with the paths in it made absolute. */
export function defaultSocket(env: NodeJS.ProcessEnv = process.env, cwd: string = process.cwd()): string {
  return socketPath(canonicalEnv(env, cwd), codeStamp());
}

/**
 * The socket of a daemon that answers for this environment, starting one if none does.
 *
 * The daemon is a child of this process only until `unref()` lets go of it: `detached` makes it a process group of its own, so it outlives the Claude session whose bridge happened to start it.
 */
export async function ensureDaemon(
  env: NodeJS.ProcessEnv = process.env,
  idleSeconds: number = DEFAULT_IDLE_SECONDS,
  waitMs: number = START_WAIT_MS
): Promise<string> {
  const daemonEnv = canonicalEnv(env, process.cwd());
  const socket = socketPath(daemonEnv, codeStamp());
  ensurePrivateDir(path.dirname(socket));
  if ((await probe(socket)) === 'live') return socket;

  const child = spawn(
    process.execPath,
    [CLI_ENTRY, 'serve', '--foreground', '--socket', socket, '--idle', String(idleSeconds)],
    // cwd '/': a daemon must not hold the directory of a session (a worktree about to be removed) open.
    { detached: true, stdio: 'ignore', env: daemonEnv, cwd: '/' }
  );
  let gone = false;
  let spawnError: Error | null = null;
  child.once('exit', () => {
    gone = true;
  });
  child.once('error', (e) => {
    gone = true;
    spawnError = e;
  });
  child.unref();

  const deadline = Date.now() + waitMs;
  for (;;) {
    if ((await probe(socket)) === 'live') return socket;
    // A daemon that lost the race to another one exits 0 having found it live: the probe above sees that one.
    if (gone) {
      if ((await probe(socket)) === 'live') return socket;
      throw spawnError ?? new Error('the knowledge server exited before it was listening');
    }
    if (Date.now() > deadline) throw new Error(`the knowledge server did not listen on ${socket} within ${waitMs} ms`);
    await sleep(POLL_MS);
  }
}

/** Run `fn` while holding a directory-shaped lock: mkdir either creates it or fails, never both. */
async function withLock<T>(lockDir: string, fn: () => Promise<T>): Promise<T> {
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      fs.mkdirSync(lockDir);
      break;
    } catch (e) {
      if (!(e instanceof Error) || !('code' in e) || e.code !== 'EEXIST') throw e;
    }
    try {
      if (Date.now() - fs.statSync(lockDir).mtimeMs > LOCK_STALE_MS) fs.rmSync(lockDir, { recursive: true, force: true });
    } catch {
      // released between the mkdir and the stat: try again
    }
    if (Date.now() > deadline) throw new Error(`could not take ${lockDir}`);
    await sleep(20);
  }
  try {
    return await fn();
  } finally {
    fs.rmSync(lockDir, { recursive: true, force: true });
  }
}

/** One listen(): 'inuse' means the name is taken, by a live server or by a dead socket file. Anything else is an error. */
function tryListen(server: net.Server, socket: string): Promise<'bound' | 'inuse'> {
  return new Promise((resolve, reject) => {
    const onError = (e: NodeJS.ErrnoException): void => {
      if (e.code === 'EADDRINUSE') resolve('inuse');
      else reject(e);
    };
    server.once('error', onError);
    server.listen(socket, () => {
      server.off('error', onError);
      resolve('bound');
    });
  });
}

/**
 * Take the socket name, or learn that a live server already has it.
 *
 * A dead file is removed and the new listen() happens in the same critical section: bind() and listen() are two system calls, and a probe that lands between them sees a socket that refuses connections and would unlink a server that is about to be live.
 */
async function bind(server: net.Server, socket: string): Promise<'bound' | 'taken'> {
  for (let attempt = 0; attempt < BIND_ATTEMPTS; attempt++) {
    if ((await tryListen(server, socket)) === 'bound') return 'bound';
    if ((await probe(socket)) === 'live') return 'taken';
    const outcome = await withLock(lockDirOf(socket), async () => {
      const state = await probe(socket);
      if (state === 'live') return 'taken' as const;
      if (state === 'stale') {
        if (!fs.lstatSync(socket).isSocket()) throw new Error(`${socket} exists and is not a socket`);
        fs.rmSync(socket);
      }
      return (await tryListen(server, socket)) === 'bound' ? ('bound' as const) : ('again' as const);
    });
    if (outcome !== 'again') return outcome;
  }
  throw new Error(`could not take ${socket}`);
}

export interface DaemonOptions {
  readonly socket: string;
  /** Quiet time after the last connection closes (or after start, if none ever arrives) before the daemon leaves. */
  readonly idleMs: number;
  readonly env?: NodeJS.ProcessEnv;
  /** The MCP server each connection gets: `createServer`, unless a test needs one that fails. */
  readonly makeServer?: (env: NodeJS.ProcessEnv) => McpServer;
}

/** A first line `tagents-knowledge: <what>: <error>` followed by the error's stack, on stderr, for a fault the daemon survives; a stderr that cannot be written to is no reason to fail again. */
function fault(what: string, e: unknown): void {
  try {
    fs.writeSync(2, `tagents-knowledge: ${what}: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}\n`);
  } catch {
    // nowhere to say it
  }
}

/**
 * Listen on the socket and serve until nothing has been connected for `idleMs`, or a signal arrives.
 * Resolves 'taken' at once when another daemon already holds the socket.
 */
export async function runDaemon(o: DaemonOptions): Promise<'served' | 'taken'> {
  const env = o.env ?? process.env;
  const makeServer = o.makeServer ?? createServer;
  ensurePrivateDir(path.dirname(o.socket));
  const connections = new Set<net.Socket>();
  let idleTimer: NodeJS.Timeout | null = null;
  let stopping = false;

  const disarm = (): void => {
    if (idleTimer !== null) clearTimeout(idleTimer);
    idleTimer = null;
  };
  // One shot, set when the last connection closes and cleared by the next one: nothing polls.
  const arm = (): void => {
    disarm();
    if (!stopping) idleTimer = setTimeout(stop, o.idleMs);
  };

  const server = net.createServer((conn) => {
    disarm();
    connections.add(conn);
    // A client that vanishes mid-write is not the daemon's problem, and an unhandled 'error' would end the process for every other client.
    conn.on('error', () => undefined);
    let mcp: McpServer | null = null;
    // Before anything below can throw, so that a connection that fails to set up is still counted out.
    conn.once('close', () => {
      connections.delete(conn);
      try {
        void mcp?.close().catch(() => undefined);
      } catch {
        // closing a server that never opened
      }
      if (connections.size === 0) arm();
    });
    try {
      mcp = makeServer(env);
      mcp.connect(new StdioServerTransport(conn, conn)).catch((e: unknown) => {
        fault('a connection could not be served', e);
        conn.destroy();
      });
    } catch (e) {
      fault('a connection could not be set up', e);
      conn.destroy();
    }
  });

  const closed = new Promise<void>((resolve) => server.once('close', resolve));
  function stop(): void {
    if (stopping) return;
    stopping = true;
    disarm();
    for (const conn of connections) conn.destroy();
    // Closing a unix-socket server removes the socket file.
    server.close();
  }

  if ((await bind(server, o.socket)) === 'taken') return 'taken';
  const pidFile = pidFileOf(o.socket);
  fs.writeFileSync(pidFile, `${process.pid}\n`);
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
  // Taken off again below: this function is also run in-process, and a handler left behind would swallow somebody else's failures.
  const onUncaught = (e: unknown): void => fault('uncaught exception', e);
  const onRejected = (e: unknown): void => fault('unhandled rejection', e);
  process.on('uncaughtException', onUncaught);
  process.on('unhandledRejection', onRejected);
  arm();
  await closed;
  process.off('uncaughtException', onUncaught);
  process.off('unhandledRejection', onRejected);
  try {
    if (fs.readFileSync(pidFile, 'utf8').trim() === String(process.pid)) fs.rmSync(pidFile);
  } catch {
    // already gone
  }
  return 'served';
}
