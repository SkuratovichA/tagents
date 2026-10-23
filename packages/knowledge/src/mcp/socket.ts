// Where the shared knowledge server listens, and how a starter learns whether anything answers there.
//
// One server per ENVIRONMENT, not per session: two sessions whose settings make the tools answer differently must never share a process, and two that would answer alike should. So the socket is named after a hash of the variables the server (and the core renderers behind its sessions tools) actually read, plus a stamp of the code that is running, so a rebuilt checkout gets a fresh server instead of the previous build's.
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Every variable that changes what a tool answers, and where it is read:
 *   HOME                    os.homedir(): `~` in paths.ts, core's default config dir, transcripts.ts' home
 *   TAGENTS_CONFIG_DIR      core host.ts configDir(): the config.yaml that names the documents, and the default index
 *   XDG_CONFIG_HOME         the same function, when the line above is unset
 *   TAGENTS_KNOWLEDGE_DIR   paths.ts resolveDir(): the documents
 *   TAGENTS_KNOWLEDGE_DB    paths.ts resolveDb(): the index
 *   TAGENTS_KNOWLEDGE_USAGE_DB paths.ts resolveUsageDb(): the store the read tools record into
 *   CLAUDE_HOMES            core transcripts.ts discoverAccounts(): which Claude accounts the sessions tools list
 * CLAUDE_CONFIG_DIR is deliberately absent: nothing under the server reads it (the sessions tools list every account on the machine). test/socket.test.ts scans the sources and fails when a read appears that is neither here nor in its list of reasons to ignore one.
 */
export const KEY_VARS = [
  'HOME',
  'TAGENTS_CONFIG_DIR',
  'XDG_CONFIG_HOME',
  'TAGENTS_KNOWLEDGE_DIR',
  'TAGENTS_KNOWLEDGE_DB',
  'TAGENTS_KNOWLEDGE_USAGE_DB',
  'CLAUDE_HOMES',
] as const;

/** The key variables that hold a path (CLAUDE_HOMES a comma-separated list of them). */
const PATH_VARS = [
  'TAGENTS_CONFIG_DIR',
  'XDG_CONFIG_HOME',
  'TAGENTS_KNOWLEDGE_DIR',
  'TAGENTS_KNOWLEDGE_DB',
  'TAGENTS_KNOWLEDGE_USAGE_DB',
  'CLAUDE_HOMES',
] as const;

/** 108 on Linux, 104 on macOS, and the terminating NUL counts. */
const MAX_SOCKET_BYTES = 100;
const KEY_HEX = 12;

const HERE = fileURLToPath(import.meta.url);
/** The CLI that runs `serve`: `.js` beside this file in dist/, `.ts` in src/. */
export const CLI_ENTRY = path.join(path.dirname(HERE), '..', 'cli', `main${path.extname(HERE)}`);

/** The running build, as a string: a rebuild rewrites the entry, so a new build never joins an old build's server. */
export function codeStamp(entry: string = CLI_ENTRY): string {
  return `${entry}:${fs.statSync(entry).mtimeMs}`;
}

/**
 * The environment as the daemon will see it: a path that is relative to the session's directory is made absolute, because the daemon outlives the session and starts somewhere else. `~…` stays, since paths.ts expands it itself.
 */
export function canonicalEnv(env: NodeJS.ProcessEnv, cwd: string): NodeJS.ProcessEnv {
  const absolute = (p: string): string => (p.startsWith('~') || path.isAbsolute(p) ? p : path.resolve(cwd, p));
  const out: NodeJS.ProcessEnv = { ...env };
  for (const name of PATH_VARS) {
    const value = out[name];
    if (value === undefined || !value.trim()) continue;
    out[name] =
      name === 'CLAUDE_HOMES'
        ? value
            .split(',')
            .map((d) => d.trim())
            .filter(Boolean)
            .map(absolute)
            .join(',')
        : absolute(value);
  }
  return out;
}

/** A short hex digest of the key variables and the code stamp. Unset and empty are the same thing, as they are to the code that reads them. */
export function serverKey(env: NodeJS.ProcessEnv, stamp: string): string {
  const hash = createHash('sha256');
  for (const name of KEY_VARS) hash.update(`${name}=${env[name] ?? ''}\0`);
  hash.update(`code=${stamp}`);
  return hash.digest('hex').slice(0, KEY_HEX);
}

/**
 * The private directory sockets go in: $TMPDIR/tagents-<uid>, or /tmp/tagents-<uid> when that would not fit in a socket address. Short on purpose.
 */
export function socketDir(env: NodeJS.ProcessEnv): string {
  const name = `tagents-${os.userInfo().uid}`;
  const dir = path.join(env['TMPDIR']?.trim() || os.tmpdir(), name);
  const longest = path.join(dir, `knowledge-${'0'.repeat(KEY_HEX)}.sock`);
  return Buffer.byteLength(longest) > MAX_SOCKET_BYTES ? path.join('/tmp', name) : dir;
}

export function socketPath(env: NodeJS.ProcessEnv, stamp: string): string {
  return path.join(socketDir(env), `knowledge-${serverKey(env, stamp)}.sock`);
}

/** The pid file beside a socket: the daemon writes it once it listens, and removes it on the way out. */
export const pidFileOf = (socket: string): string => `${socket}.pid`;
/** The lock a daemon takes while it replaces a dead socket. */
export const lockDirOf = (socket: string): string => `${socket}.lock`;

/**
 * Make the directory and refuse it unless it is ours alone: the name is predictable, and /tmp is shared.
 */
export function ensurePrivateDir(dir: string): void {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.uid !== os.userInfo().uid) throw new Error(`${dir} is not a directory of this user`);
  if ((st.mode & 0o077) !== 0) fs.chmodSync(dir, 0o700);
}

/** 'live' answers; 'stale' is a socket file nobody listens on; 'absent' is no file at all. */
export type Probe = 'live' | 'stale' | 'absent';

export function probe(socket: string): Promise<Probe> {
  return new Promise((resolve, reject) => {
    const conn = net.connect(socket);
    conn.once('connect', () => {
      conn.destroy();
      resolve('live');
    });
    conn.once('error', (e: NodeJS.ErrnoException) => {
      if (e.code === 'ENOENT') resolve('absent');
      else if (e.code === 'ECONNREFUSED') resolve('stale');
      else reject(e);
    });
  });
}
