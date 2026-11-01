// The process section of the knowledge vectors: what the server's socket is named from, what `serve` does with its arguments, and what the MCP SDK answers to arguments that are wrong.
//
// The environment cases run in a child process, because `os.tmpdir()` reads the process's own environment; the numbers a user id would change are written `UID`.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { connect, scratch, relativize, type JsonRpcMessage } from './util.mts';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NODE = process.execPath;

function child(script: string, argument: string, env: NodeJS.ProcessEnv): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync(NODE, [path.join(HERE, script), argument], { env, encoding: 'utf8', timeout: 60_000 });
  if (result.error) throw result.error;
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

// ---- the socket ------------------------------------------------------------------------------

interface EnvCase {
  readonly name: string;
  readonly env: Record<string, string>;
  readonly cwd?: string;
}

const LONG = `/${'a'.repeat(90)}`;

const TMP_CASES: EnvCase[] = [
  { name: 'nothing set', env: {} },
  { name: 'TMPDIR empty', env: { TMPDIR: '' } },
  { name: 'TMPDIR blank', env: { TMPDIR: '  ' } },
  { name: 'TMPDIR padded', env: { TMPDIR: '  /var/x  ' } },
  { name: 'TMPDIR with a trailing slash', env: { TMPDIR: '/var/x/' } },
  { name: 'TMPDIR with doubled slashes', env: { TMPDIR: '/var//x//' } },
  { name: 'TMPDIR the root', env: { TMPDIR: '/' } },
  { name: 'TMPDIR relative', env: { TMPDIR: 'rel/tmp' } },
  { name: 'TMPDIR with dots', env: { TMPDIR: '/var/./x/../y' } },
  { name: 'TMPDIR too long for a socket address', env: { TMPDIR: LONG } },
  { name: 'TMPDIR padded and too long', env: { TMPDIR: `  ${LONG}  ` } },
  { name: 'TMPDIR short, TMP long', env: { TMPDIR: '/short', TMP: LONG } },
  { name: 'only TMP', env: { TMP: '/var/tmp-x' } },
  { name: 'only TEMP', env: { TEMP: '/var/temp-x' } },
  { name: 'TMP and TEMP', env: { TMP: '/var/tmp-x', TEMP: '/var/temp-x' } },
  { name: 'TMP empty, TEMP set', env: { TMP: '', TEMP: '/var/temp-x' } },
  { name: 'TMPDIR empty, TMP set', env: { TMPDIR: '', TMP: '/var/tmp-x' } },
  { name: 'TMPDIR blank, TMP set', env: { TMPDIR: '   ', TMP: '/var/tmp-x' } },
  { name: 'TMP with a trailing slash', env: { TMP: '/var/tmp-x/' } },
  { name: 'TMP with two trailing slashes', env: { TMP: '/var/tmp-x//' } },
  { name: 'TEMP the root', env: { TEMP: '/' } },
  { name: 'TMP long', env: { TMP: LONG } },
  { name: 'TMPDIR with a tab and a newline around it', env: { TMPDIR: '\t/var/x\n' } },
  { name: 'TMPDIR of non-ASCII characters', env: { TMPDIR: '/var/тмп' } },
  { name: 'TMPDIR of non-ASCII characters, too long in bytes and short in characters', env: { TMPDIR: `/${'я'.repeat(45)}` } },
];

const KEY_CASES: EnvCase[] = [
  { name: 'no variables', env: {} },
  { name: 'every variable absolute', env: { HOME: '/home/u', TAGENTS_CONFIG_DIR: '/c', XDG_CONFIG_HOME: '/x', TAGENTS_KNOWLEDGE_DIR: '/k', TAGENTS_KNOWLEDGE_DB: '/k.db', TAGENTS_KNOWLEDGE_USAGE_DB: '/u.db', CLAUDE_HOMES: '/a,/b' } },
  { name: 'relative values resolve against the directory', env: { TAGENTS_KNOWLEDGE_DIR: 'docs', TAGENTS_KNOWLEDGE_DB: './db/k.sqlite', TAGENTS_KNOWLEDGE_USAGE_DB: '../u.sqlite', TAGENTS_CONFIG_DIR: 'a//b/../c', XDG_CONFIG_HOME: '.' }, cwd: '/work/dir' },
  { name: 'the same from the root', env: { TAGENTS_KNOWLEDGE_DIR: 'docs', TAGENTS_KNOWLEDGE_DB: '../../x' }, cwd: '/' },
  { name: 'the same from a directory with a trailing slash', env: { TAGENTS_KNOWLEDGE_DIR: 'docs/' }, cwd: '/work/dir/' },
  { name: 'a value that is empty or blank stays as it is', env: { TAGENTS_KNOWLEDGE_DIR: '', TAGENTS_KNOWLEDGE_DB: '   ', TAGENTS_CONFIG_DIR: '\t', CLAUDE_HOMES: '  ' }, cwd: '/work/dir' },
  { name: 'a tilde stays, whatever follows', env: { TAGENTS_KNOWLEDGE_DIR: '~', TAGENTS_KNOWLEDGE_DB: '~/a/../b', TAGENTS_KNOWLEDGE_USAGE_DB: '~other/x', TAGENTS_CONFIG_DIR: '~x' }, cwd: '/work/dir' },
  { name: 'an absolute value is not normalised', env: { TAGENTS_KNOWLEDGE_DIR: '/abs/./x//y/../z/', TAGENTS_KNOWLEDGE_DB: '//double' }, cwd: '/work/dir' },
  { name: 'a value with spaces around it is not trimmed when it is resolved', env: { TAGENTS_KNOWLEDGE_DIR: '  docs  ', TAGENTS_KNOWLEDGE_DB: ' /abs ' }, cwd: '/work/dir' },
  { name: 'HOME is not resolved', env: { HOME: 'rel/home' }, cwd: '/work/dir' },
  { name: 'CLAUDE_HOMES is split, trimmed, filtered and resolved', env: { CLAUDE_HOMES: ' a , ,b/c,/abs , ~/h ,' }, cwd: '/work/dir' },
  { name: 'CLAUDE_HOMES of only separators', env: { CLAUDE_HOMES: ',,' }, cwd: '/work/dir' },
  { name: 'CLAUDE_HOMES of one entry', env: { CLAUDE_HOMES: 'only' }, cwd: '/work/dir' },
  { name: 'a path that climbs above the root', env: { TAGENTS_KNOWLEDGE_DIR: '../../../x' }, cwd: '/a' },
  { name: 'non-ASCII values', env: { TAGENTS_KNOWLEDGE_DIR: 'знания', HOME: '/home/пользователь' }, cwd: '/work/папка' },
  { name: 'variables that are not part of the key do not change it', env: { PATH: '/bin', LANG: 'ru_RU.UTF-8', CLAUDE_CONFIG_DIR: '/c', TA_LABEL: 'x' } },
];

function socketCase(c: EnvCase): unknown {
  const result = child('socket-child.mts', JSON.stringify({ cwd: c.cwd ?? '/' }), c.env);
  if (result.status !== 0) throw new Error(`the socket child failed for ${c.name}: ${result.stderr.slice(0, 500)}`);
  const parsed: { uid: number; dir: string; lines: string[]; key: string } = JSON.parse(result.stdout);
  if (typeof process.getuid === 'function' && parsed.uid !== process.getuid()) throw new Error('the child runs as another user');
  const name = `tagents-${parsed.uid}`;
  if (!parsed.dir.includes(name)) throw new Error(`the socket directory of ${c.name} does not hold ${name}: ${parsed.dir}`);
  return { name: c.name, env: c.env, cwd: c.cwd ?? '/', dir: parsed.dir.replace(name, 'tagents-UID'), lines: parsed.lines, key: parsed.key };
}

const RESOLVE: ReadonlyArray<readonly [string, string]> = [
  ['/a/b', 'c'], ['/a/b', './c'], ['/a/b', '../c'], ['/a/b', '../../c'], ['/a/b', '../../../c'], ['/', 'a'], ['/', '../a'], ['/', ''], ['/a', ''], ['/a', '.'], ['/a', '..'], ['/a/', 'b/'], ['/a//b', 'c//d'],
  ['/a', '/x//y/../z/'], ['/a', '//x'], ['/a', ' '], ['/a', ' b '], ['/a', 'b/ '], ['/a', 'b/./c/../d'], ['/a', '....'], ['/a', '.../b'], ['/a', 'b/..'], ['/a/b/c', '../..'], ['/a', 'ключ/знач'], ['/a', 'a\\b'],
  ['/a', '/'], ['/a', '/..'], ['/a/./b', '../c'], ['/a/../b', 'c'],
];

function resolveVectors(): unknown {
  return RESOLVE.map(([base, p]) => ({ base, path: p, result: path.resolve(base, p) }));
}

// ---- serve -----------------------------------------------------------------------------------

const SERVE_ARGS: string[][] = [
  [], ['--idle', '5'], ['--idle', '0.5'], ['--idle', '1e3'], ['--idle=5'], ['--idle', ' 5 '], ['--idle', '0x10'], ['--idle', '1_0'], ['--idle', '5', '--idle', '6'], ['--idle', 'Infinity'], ['--idle', '-Infinity'], ['--idle', 'NaN'],
  ['--idle', '0'], ['--idle', '-1'], ['--idle', ''], ['--idle', 'abc'], ['--idle', '1e999'], ['--idle', '1e-9'], ['--idle', '.5'], ['--idle', '5.'], ['--idle', '+5'], ['--idle', '٥'], ['--idle=-5'], ['--idle', '-5'], ['--idle='], ['--idle'], ['--idle', '--foreground'],
  ['--foreground'], ['--foreground', '--foreground'], ['--foreground=x'], ['--foreground=true'], ['--no-foreground'],
  ['--socket', '{socket}'], ['--socket={socket}'], ['--socket'], ['--socket', '--idle'], ['--socket', '{socket}', '--socket', '{socket}'],
  ['--unknown'], ['--unknown=1'], ['-f'], ['-i', '5'], ['-x'], ['--IDLE', '5'], ['--idl', '5'], ['--idle5'], ['--foregroun'],
  ['extra'], ['--idle', '5', 'extra'], ['extra', '--idle', '5'], ['--', 'x'], ['--', '--idle', '5'], ['--idle', '5', '--', 'x'], ['-'], ['--', ''], [''],
  ['--help'], ['-h'], ['help'], ['--version'],
  ['--idle', '5', '--unknown'], ['--unknown', '--idle', 'x'], ['--idle', 'x', '--unknown'], ['--foreground=x', '--idle', 'abc'],
];

function serveCases(): unknown {
  const dir = scratch('serve');
  const regular = path.join(dir, 'regular-file');
  fs.writeFileSync(regular, '');
  const socket = path.join(regular, 'x.sock');
  return SERVE_ARGS.map((args) => {
    const full = ['serve', '--foreground', '--socket', socket, ...args.map((a) => a.replace('{socket}', socket))];
    // The arguments of the case come last, so a missing value takes nothing from the arguments this driver adds.
    const result = child('serve-child.mts', JSON.stringify(full), { TAGENTS_LOCALE: 'en' });
    if (result.status !== 0) throw new Error(`the serve child failed for ${JSON.stringify(args)}: ${result.stderr.slice(0, 500)}`);
    const parsed: { exit: number; stdout: string; stderr: string } = JSON.parse(result.stdout);
    const stderr = relativize(parsed.stderr, dir);
    const named = /'(-{1,2}[^'\s<=]*)/.exec(stderr)?.[1] ?? null;
    const positional = /Unexpected argument '([^']*)'/.exec(stderr)?.[1] ?? null;
    return { args, exit: parsed.exit, stdout: parsed.stdout, stderr, option: positional === null ? named : null, positional };
  });
}

// ---- the SDK ---------------------------------------------------------------------------------

interface SdkCase {
  readonly name: string;
  readonly params?: unknown;
}

const call = (tool: string, args: unknown): SdkCase => ({ name: `${tool} ${JSON.stringify(args)}`, params: { name: tool, arguments: args } });

const SDK_CASES: SdkCase[] = [
  // knowledge_search
  call('knowledge_search', {}), call('knowledge_search', { query: '' }), call('knowledge_search', { query: 5 }), call('knowledge_search', { query: null }), call('knowledge_search', { query: ['a'] }), call('knowledge_search', { query: 'x', tag: 5 }),
  call('knowledge_search', { query: 'x', type: [] }), call('knowledge_search', { query: 'x', kind: {} }), call('knowledge_search', { query: 'x', limit: 0 }), call('knowledge_search', { query: 'x', limit: -1 }), call('knowledge_search', { query: 'x', limit: 1.5 }),
  call('knowledge_search', { query: 'x', limit: 51 }), call('knowledge_search', { query: 'x', limit: '5' }), call('knowledge_search', { query: 'x', limit: null }), call('knowledge_search', { query: 'x', limit: true }), call('knowledge_search', { query: 'x', limit: 1e21 }),
  call('knowledge_search', { query: [], limit: 'x', tag: 1, type: 2, kind: 3 }), call('knowledge_search', { limit: 0, query: '' }), call('knowledge_search', { query: 'x', limit: 5.0 }),
  // knowledge_get
  call('knowledge_get', {}), call('knowledge_get', { id: '' }), call('knowledge_get', { id: 5 }), call('knowledge_get', { id: 'x', heading: 5 }), call('knowledge_get', { id: 'x', heading: null }), call('knowledge_get', { id: null, heading: [] }), call('knowledge_get', { heading: 'h' }),
  // knowledge_list
  call('knowledge_list', { type: 5 }), call('knowledge_list', { tag: [] }), call('knowledge_list', { kind: true }), call('knowledge_list', { type: null }), call('knowledge_list', { type: 1, kind: 2, tag: 3 }),
  // knowledge_usage
  call('knowledge_usage', { since: 5 }), call('knowledge_usage', { since: null }), call('knowledge_usage', { top: 0 }), call('knowledge_usage', { top: 1.5 }), call('knowledge_usage', { top: '3' }), call('knowledge_usage', { top: -2 }), call('knowledge_usage', { type: 5 }),
  call('knowledge_usage', { all: 'yes' }), call('knowledge_usage', { all: 1 }), call('knowledge_usage', { candidates: 1 }), call('knowledge_usage', { candidates: null }), call('knowledge_usage', { min_gets: 0 }), call('knowledge_usage', { min_days: -1 }),
  call('knowledge_usage', { min_gets: 1.5 }), call('knowledge_usage', { min_days: 'x' }), call('knowledge_usage', { since: 1, top: 0, type: 2, all: 3, candidates: 4, min_gets: 5.5, min_days: 0 }),
  // sessions_recent and sessions_search: only calls that fail, because a valid one reads the machine
  call('sessions_recent', { limit: 0 }), call('sessions_recent', { limit: 51 }), call('sessions_recent', { limit: 'a' }), call('sessions_recent', { limit: 1.5 }), call('sessions_recent', { limit: null }), call('sessions_recent', { limit: -1 }),
  call('sessions_search', {}), call('sessions_search', { words: '' }), call('sessions_search', { words: 5 }), call('sessions_search', { words: null }), call('sessions_search', { words: ['a'] }),
  // the call itself
  call('nope', {}), call('', {}), call('Knowledge_Get', { id: 'x' }), call('knowledge_get ', { id: 'x' }),
  { name: 'unknown tool, no arguments', params: { name: 'nope' } },
  { name: 'name is a number', params: { name: 5, arguments: {} } },
  { name: 'name is null', params: { name: null, arguments: {} } },
  { name: 'no name', params: { arguments: {} } },
  { name: 'no parameters', params: undefined },
  { name: 'parameters are an empty object', params: {} },
  { name: 'parameters are a list', params: [] },
  { name: 'parameters are a string', params: 'knowledge_get' },
  { name: 'knowledge_get without an arguments object', params: { name: 'knowledge_get' } },
  { name: 'knowledge_get with null arguments', params: { name: 'knowledge_get', arguments: null } },
  { name: 'knowledge_get with a number as arguments', params: { name: 'knowledge_get', arguments: 5 } },
  { name: 'knowledge_get with a list as arguments', params: { name: 'knowledge_get', arguments: [] } },
  { name: 'knowledge_get with a string as arguments', params: { name: 'knowledge_get', arguments: 'x' } },
  { name: 'knowledge_search without an arguments object', params: { name: 'knowledge_search' } },
  { name: 'sessions_search without an arguments object', params: { name: 'sessions_search' } },
  { name: 'sessions_search with a list as arguments', params: { name: 'sessions_search', arguments: [] } },
];

function shape(response: JsonRpcMessage | null): unknown {
  if (response === null) return { silent: true };
  return response.error === undefined ? { result: response.result } : { error: response.error };
}

async function sdkCases(): Promise<unknown> {
  const dir = scratch('sdk');
  const folder = path.join(dir, 'folder');
  fs.mkdirSync(folder);
  const env: NodeJS.ProcessEnv = {
    HOME: dir,
    TAGENTS_CONFIG_DIR: path.join(dir, 'config'),
    TAGENTS_KNOWLEDGE_DIR: folder,
    TAGENTS_KNOWLEDGE_DB: path.join(dir, 'index.sqlite'),
    TAGENTS_KNOWLEDGE_USAGE_DB: path.join(dir, 'usage.sqlite'),
  };
  const conn = await connect(env);
  try {
    const out: unknown[] = [];
    for (const c of SDK_CASES) out.push({ name: c.name, ...(c.params === undefined ? {} : { params: c.params }), response: shape(await conn.request('tools/call', c.params, 1000)) });
    return out;
  } finally {
    await conn.close();
  }
}

export async function processVectors(): Promise<unknown> {
  return {
    socket: {
      tmp: TMP_CASES.map(socketCase),
      key: KEY_CASES.map(socketCase),
      resolve: resolveVectors(),
      stamp: 'vectors',
    },
    serve: serveCases(),
    sdk: await sdkCases(),
  };
}
