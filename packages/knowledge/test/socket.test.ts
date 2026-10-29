// node --test socket.test.ts
//
// The pieces of the shared server that do not need a process: how the socket is named, where it lives, how a starter reads one, and a scan that keeps the environment key honest.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { KEY_VARS, canonicalEnv, ensurePrivateDir, probe, serverKey, socketDir, socketPath } from '../src/mcp/socket.ts';
import { NODE, removeDir, tmpDir } from './helpers.ts';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STAMP = 'build-1';

test('the key follows every variable the server reads, the code stamp, and nothing else', () => {
  const base: NodeJS.ProcessEnv = { HOME: '/home/a', TAGENTS_KNOWLEDGE_DIR: '/k' };
  const key = serverKey(base, STAMP);
  assert.match(key, /^[0-9a-f]{12}$/);
  assert.equal(serverKey({ ...base }, STAMP), key, 'stable');
  assert.ok(KEY_VARS.includes('TAGENTS_KNOWLEDGE_USAGE_DB'), 'two usage stores are two environments: each gets a server of its own');
  for (const name of KEY_VARS) {
    assert.notEqual(serverKey({ ...base, [name]: '/changed' }, STAMP), key, name);
  }
  assert.notEqual(serverKey(base, 'build-2'), key, 'a rebuilt checkout does not join the old build\'s server');
  // not read by the server: no split
  assert.equal(serverKey({ ...base, CLAUDE_CONFIG_DIR: '/account', PATH: '/x', TZ: 'UTC' }, STAMP), key);
  // unset and empty are one thing to the code that reads them
  assert.equal(serverKey({ ...base, XDG_CONFIG_HOME: '' }, STAMP), key);
});

test('a path relative to the session becomes absolute, because the daemon starts elsewhere', () => {
  const env = canonicalEnv(
    {
      TAGENTS_KNOWLEDGE_DIR: 'docs',
      TAGENTS_KNOWLEDGE_DB: '~/index.sqlite',
      TAGENTS_KNOWLEDGE_USAGE_DB: 'usage/events.sqlite',
      TAGENTS_CONFIG_DIR: '/abs/config',
      CLAUDE_HOMES: ' a , /b ,,c ',
      HOME: '/home/a',
    },
    '/work/project'
  );
  assert.equal(env['TAGENTS_KNOWLEDGE_DIR'], '/work/project/docs');
  assert.equal(env['TAGENTS_KNOWLEDGE_DB'], '~/index.sqlite', 'paths.ts expands ~ itself');
  assert.equal(env['TAGENTS_KNOWLEDGE_USAGE_DB'], '/work/project/usage/events.sqlite');
  assert.equal(env['TAGENTS_CONFIG_DIR'], '/abs/config');
  assert.equal(env['CLAUDE_HOMES'], '/work/project/a,/b,/work/project/c');
  assert.equal(env['XDG_CONFIG_HOME'], undefined, 'unset stays unset');
  assert.deepEqual(canonicalEnv(env, '/elsewhere'), env, 'idempotent');
});

test('the socket lives in a private directory under TMPDIR, and falls back to /tmp when the name would not fit', () => {
  const uid = os.userInfo().uid;
  const short = socketDir({ TMPDIR: '/var/t' });
  assert.equal(short, `/var/t/tagents-${uid}`);
  const file = socketPath({ TMPDIR: '/var/t', HOME: '/h' }, STAMP);
  assert.ok(file.startsWith(`${short}/knowledge-`) && file.endsWith('.sock'), file);
  assert.ok(Buffer.byteLength(file) < 104, 'fits sockaddr_un on macOS');

  const tooLong = `/var/${'x'.repeat(100)}`;
  assert.equal(socketDir({ TMPDIR: tooLong }), `/tmp/tagents-${uid}`);
  assert.equal(socketDir({ TMPDIR: ' ' }), socketDir({}), 'a blank TMPDIR means the OS default');
});

test('ensurePrivateDir makes a 0700 directory, tightens a looser one of ours and refuses a file', (t) => {
  const root = tmpDir('private');
  t.after(() => removeDir(root));
  const dir = path.join(root, 'a', 'b');
  ensurePrivateDir(dir);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  fs.chmodSync(dir, 0o755);
  ensurePrivateDir(dir);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  const file = path.join(root, 'file');
  fs.writeFileSync(file, '');
  assert.throws(() => ensurePrivateDir(file));
});

test('probe tells a live socket from a dead one from none', async (t) => {
  const root = tmpDir('probe');
  t.after(() => removeDir(root));
  // the unix-socket path must stay short: use a directory directly under the OS temp dir
  const sock = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tk-')), 's');
  t.after(() => removeDir(path.dirname(sock)));
  assert.equal(await probe(sock), 'absent');

  // A socket file whose owner was killed: bind, then die without unlinking.
  const dying = spawnSync(
    NODE,
    ['-e', `require('node:net').createServer().listen(${JSON.stringify(sock)}, () => process.kill(process.pid, 'SIGKILL'))`],
    { encoding: 'utf8' }
  );
  assert.equal(dying.signal, 'SIGKILL');
  assert.ok(fs.lstatSync(sock).isSocket());
  assert.equal(await probe(sock), 'stale');

  fs.rmSync(sock);
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  t.after(() => server.close());
  assert.equal(await probe(sock), 'live');
});

// The key is only as good as its list. This reads the sources the server runs on and fails when one of them starts reading an environment variable nobody decided about: add it to KEY_VARS if it changes an answer, or to IGNORED with the reason if it does not.
const IGNORED: Record<string, string> = {
  TMPDIR: 'where the socket goes (socket.ts): a different TMPDIR is a different directory, so it already separates the servers',
  PATH: 'finds `claude` for core\'s CLI and `git` for lint, neither of which a tool reaches',
  TAGENTS_LOCALE: 'the language of the CLI\'s own strings; tool text is English whatever it says',
  TA_STATE_DIR: 'the dashboard\'s state directory (agent-state.ts); no tool reads it',
  TA_CONFIG: 'the file `tagents config convert` converts by default (core\'s cli/config.ts); no tool reaches it, and the knowledge folder is looked up through the config directory, which the key covers',
  TA_LABEL: 'a session variable only the CLI reads, as the caller of an event (usage.ts); the daemon never reads it, a tool\'s caller is the name its client gave in the handshake',
};

test('every environment variable the sources read is in the key or has a reason not to be', () => {
  const sourceDirs = [path.resolve(HERE, '..', 'src'), path.resolve(HERE, '..', '..', 'core', 'src')];
  const read = /\benv(?:\['([A-Z][A-Z0-9_]*)'\]|\.([A-Z][A-Z0-9_]*))/g;
  const found = new Set<string>();
  const walk = (dir: string): void => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.ts')) {
        for (const m of fs.readFileSync(full, 'utf8').matchAll(read)) found.add(m[1] ?? m[2] ?? '');
      }
    }
  };
  for (const dir of sourceDirs) walk(dir);
  assert.ok(found.has('TAGENTS_KNOWLEDGE_DIR') && found.has('CLAUDE_HOMES'), `the scan found ${[...found].join(', ')}`);

  const decided = new Set<string>([...KEY_VARS, ...Object.keys(IGNORED)]);
  assert.deepEqual([...found].filter((name) => !decided.has(name)).sort(), [], 'undecided variables');
  // HOME is read by os.homedir(), not by name.
  for (const name of KEY_VARS.filter((n) => n !== 'HOME')) assert.ok(found.has(name), `${name} is in the key but nothing reads it`);
  for (const name of Object.keys(IGNORED)) assert.ok(found.has(name), `${name} is ignored but nothing reads it`);
});
