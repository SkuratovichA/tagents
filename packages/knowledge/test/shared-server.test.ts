// node --test shared-server.test.ts
//
// The shared server end to end: the bridge script a session runs, the `serve` verb it calls, and the daemon behind them, all started for real in a scratch TMPDIR (see daemon-helpers.ts). Each case leaves no process behind: its daemons are signalled by pid file, and only after `ps` shows the scratch directory in their command line.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { test, type TestContext } from 'node:test';
import {
  TOOL_NAMES,
  alive,
  daemonPids,
  disposeWorld,
  makeWorld,
  onlyDaemon,
  otherDocs,
  sleep,
  sockets,
  startBridge,
  waitFor,
  writeScript,
  type World,
} from './daemon-helpers.ts';
import { HERE, NODE, cliEntry, runCli } from './helpers.ts';
import { z } from 'zod';

function newWorld(t: TestContext): World {
  const world = makeWorld();
  t.after(() => disposeWorld(world));
  return world;
}

/** The process group of a pid, from ps. */
function pgidOf(pid: number): number {
  return Number(spawnSync('ps', ['-o', 'pgid=', '-p', String(pid)], { encoding: 'utf8' }).stdout.trim());
}

const DocList = z.array(z.object({ id: z.string() }));

/** One session: open the bridge, say hello, list the tools, run `fn`, close. */
async function session<T>(world: World, fn: (peer: ReturnType<typeof startBridge>) => Promise<T>, extra: Record<string, string> = {}): Promise<T> {
  const peer = startBridge(world, extra);
  try {
    await peer.handshake();
    assert.deepEqual(await peer.toolNames(), TOOL_NAMES);
    return await fn(peer);
  } finally {
    await peer.end();
  }
}

test('two bridges started together are served by one daemon, in a process group of its own', async (t) => {
  const world = newWorld(t);
  const [a, b] = await Promise.all([
    session(world, async () => daemonPids(world)),
    session(world, async () => daemonPids(world)),
  ]);
  assert.equal(a.length, 1, 'one daemon while the first session is open');
  assert.equal(b.length, 1);
  assert.equal(a[0], b[0], 'both sessions saw the same daemon');
  const pid = await onlyDaemon(world);
  assert.ok(alive(pid), 'the daemon outlives the sessions that used it');
  assert.equal(pgidOf(pid), pid, 'the daemon leads a process group of its own, so it survives the session that started it');
  assert.equal(sockets(world).length, 1);

  // A later session joins the same daemon and sees the corpus.
  const listed = await session(world, (peer) => peer.callText('knowledge_list', { kind: 'runbook' }));
  assert.deepEqual(DocList.parse(JSON.parse(listed)).map((d) => d.id), ['deploy-runbook']);
  assert.deepEqual(daemonPids(world), [pid]);
});

test('a daemon that left cleanly between sessions is started again by the next bridge', async (t) => {
  const world = newWorld(t);
  await session(world, async () => undefined);
  const first = await onlyDaemon(world);
  process.kill(first, 'SIGTERM');
  await waitFor('the daemon to leave', () => !alive(first));
  assert.deepEqual(sockets(world), [], 'a clean exit removes the socket');
  assert.deepEqual(daemonPids(world), [], 'and the pid file');

  await session(world, async () => undefined);
  const now = daemonPids(world);
  assert.equal(now.length, 1);
  assert.notEqual(now[0], first);
});

test('a socket file left by a daemon that was killed is replaced, even when several bridges meet it at once', async (t) => {
  const world = newWorld(t);
  await session(world, async () => undefined);
  const first = await onlyDaemon(world);
  const [sock] = sockets(world);
  assert.ok(sock !== undefined);
  process.kill(first, 'SIGKILL');
  await waitFor('the daemon to die', () => !alive(first));
  assert.ok(fs.lstatSync(sock).isSocket(), 'SIGKILL leaves the socket file behind');
  const code = await new Promise<string | undefined>((resolve) => {
    const probe = net.connect(sock);
    probe.once('error', (e: NodeJS.ErrnoException) => resolve(e.code));
    probe.once('connect', () => {
      probe.destroy();
      resolve('connected');
    });
  });
  assert.equal(code, 'ECONNREFUSED', 'and nothing listens on it');

  await Promise.all([1, 2, 3, 4].map(() => session(world, async () => undefined)));
  const now = daemonPids(world);
  assert.equal(now.length, 1, 'four bridges, one new daemon');
  assert.notEqual(now[0], first);
  assert.deepEqual(sockets(world), [sock], 'on the same name');
});

test('environments that differ get their own daemon, and each answers from its own corpus', async (t) => {
  const world = newWorld(t);
  const alpha = otherDocs(world, 'alpha');
  const beta = otherDocs(world, 'beta');
  const ids = async (dir: string): Promise<string[]> =>
    session(
      world,
      async (peer) => DocList.parse(JSON.parse(await peer.callText('knowledge_list'))).map((d) => d.id),
      { TAGENTS_KNOWLEDGE_DIR: dir }
    );
  assert.deepEqual(await ids(alpha), ['alpha']);
  assert.deepEqual(await ids(beta), ['beta']);
  const pids = daemonPids(world);
  assert.equal(pids.length, 2);
  assert.notEqual(pids[0], pids[1]);

  // The same environment again joins the daemon it already has.
  assert.deepEqual(await ids(alpha), ['alpha']);
  assert.deepEqual(daemonPids(world).sort(), [...pids].sort());
  // A variable the server does not read does not split the daemon.
  await session(world, async () => undefined, { TAGENTS_KNOWLEDGE_DIR: alpha, CLAUDE_CONFIG_DIR: path.join(world.root, 'account') });
  assert.equal(daemonPids(world).length, 2);
});

test('the bridge falls back to a server of its own when `tagents-knowledge serve` fails', async (t) => {
  const world = newWorld(t);
  const log = path.join(world.root, 'calls.log');
  const fake = path.join(world.root, 'fake-bin');
  writeScript(fake, 'tagents-knowledge', [
    '#!/bin/sh',
    `echo "$1" >> ${JSON.stringify(log)}`,
    '[ "$1" = serve ] && { echo "boom" >&2; exit 1; }',
    `exec ${JSON.stringify(NODE)} ${JSON.stringify(cliEntry())} "$@"`,
  ]);
  await session(world, async () => undefined, { PATH: `${fake}:${world.env()['PATH'] ?? ''}` });
  assert.deepEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['serve', 'mcp']);
  assert.deepEqual(daemonPids(world), [], 'no daemon was started');
});

test('the bridge falls back too when a checkout predates `serve`', async (t) => {
  const world = newWorld(t);
  const old = path.join(world.root, 'old-bin');
  writeScript(old, 'tagents-knowledge', [
    '#!/bin/sh',
    // what the previous release does with a verb it does not know: usage on stderr, exit 2
    '[ "$1" = mcp ] || { echo "unknown command: $1" >&2; exit 2; }',
    `exec ${JSON.stringify(NODE)} ${JSON.stringify(cliEntry())} "$@"`,
  ]);
  await session(world, async () => undefined, { PATH: `${old}:${world.env()['PATH'] ?? ''}` });
  assert.deepEqual(daemonPids(world), []);
});

test('the daemon leaves after its idle time, and not while a client is connected', async (t) => {
  const world = newWorld(t);
  const served = runCli(['serve', '--idle', '1'], world.env());
  assert.equal(served.code, 0, served.stderr);
  const sock = served.stdout.trim();
  assert.equal(path.dirname(sock), world.sockDir, 'the socket is in the private directory under TMPDIR');
  assert.equal(fs.statSync(world.sockDir).mode & 0o777, 0o700);
  const pid = await onlyDaemon(world);

  const client = net.connect(sock);
  await new Promise<void>((resolve, reject) => {
    client.once('connect', resolve);
    client.once('error', reject);
  });
  await sleep(2200);
  assert.ok(alive(pid), 'two idle periods passed with a client connected');

  client.destroy();
  await waitFor('the daemon to leave once the client is gone', () => !alive(pid), 6000);
  assert.deepEqual(sockets(world), []);
  assert.deepEqual(daemonPids(world), []);
});

test('a daemon nobody ever connects to also leaves', async (t) => {
  const world = newWorld(t);
  const served = runCli(['serve', '--idle', '1'], world.env());
  assert.equal(served.code, 0, served.stderr);
  const pid = await onlyDaemon(world);
  await waitFor('the daemon to leave', () => !alive(pid), 6000);
});

test('serve prints the same socket while the daemon lives, and rejects a bad --idle', async (t) => {
  const world = newWorld(t);
  const first = runCli(['serve'], world.env());
  const second = runCli(['serve'], world.env());
  assert.equal(first.code, 0, first.stderr);
  assert.equal(second.stdout, first.stdout);
  await onlyDaemon(world);

  for (const bad of ['0', '-3', 'soon']) {
    const r = runCli(['serve', '--idle', bad], world.env());
    assert.equal(r.code, 2, bad);
    assert.match(r.stderr, /--idle/);
  }
});

/** Connect to a unix socket; resolves once connected. The socket is left open for the caller. */
function connectTo(sock: string, allowHalfOpen = false): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const conn = net.connect({ path: sock, allowHalfOpen });
    conn.once('connect', () => resolve(conn));
    conn.once('error', reject);
  });
}

/** Resolves true when the other side closes the connection within `ms`, false when it does not. */
function closedWithin(conn: net.Socket, ms: number): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ms);
    conn.once('close', () => {
      clearTimeout(timer);
      resolve(true);
    });
    conn.on('error', () => undefined);
    conn.resume();
  });
}

/** One `initialize` request on a raw connection: true when the answer to it arrives. */
function answersInitialize(conn: net.Socket, ms = 5000): Promise<boolean> {
  return new Promise((resolve) => {
    let buffer = '';
    const timer = setTimeout(() => resolve(false), ms);
    conn.setEncoding('utf8');
    conn.on('data', (chunk: string) => {
      buffer += chunk;
      const answered = buffer.split('\n').some((line) => {
        try {
          const message: unknown = JSON.parse(line);
          return typeof message === 'object' && message !== null && 'id' in message && message.id === 1 && 'result' in message;
        } catch {
          return false;
        }
      });
      if (answered) {
        clearTimeout(timer);
        resolve(true);
      }
    });
    conn.on('error', () => undefined);
    conn.write(
      `${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'fault-suite', version: '0.0.0' } } })}\n`
    );
  });
}

// THE DAEMON IS SHARED, so a peer that sends rubbish costs the others nothing. These are the kinds of rubbish a socket can carry: not JSON, JSON that is not a request, bytes that are not UTF-8, a request that names a method nobody has, and one that cuts off in the middle.
test('a connection that sends garbage leaves the daemon serving another one', async (t) => {
  const world = newWorld(t);
  const served = runCli(['serve', '--idle', '30'], world.env());
  assert.equal(served.code, 0, served.stderr);
  const sock = served.stdout.trim();
  const pid = await onlyDaemon(world);

  const garbage: Array<[string, string | Buffer]> = [
    ['plain text', 'this is not json\n'],
    ['json that is not a request', '[1, 2, 3]\n{}\n"x"\nnull\n'],
    ['a request with params of the wrong type', '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":null}\n'],
    ['an unknown method', '{"jsonrpc":"2.0","id":8,"method":"no/such/method"}\n'],
    ['bytes that are not text', Buffer.from([0xff, 0xfe, 0x00, 0x0a, 0xc3, 0x28, 0x0a])],
    ['a line cut off in the middle', '{"jsonrpc":"2.0","id":9,"meth'],
    ['a deeply nested array', `${'['.repeat(50000)}\n`],
  ];
  for (const [what, payload] of garbage) {
    const conn = await connectTo(sock);
    conn.on('error', () => undefined);
    conn.resume();
    conn.write(payload);
    await sleep(100);
    conn.destroy();
    assert.ok(alive(pid), `the daemon is alive after ${what}`);
  }

  // A well-behaved peer still gets its answers, from the same daemon.
  const peer = await session(world, async (p) => p.callText('knowledge_list', { kind: 'runbook' }));
  assert.deepEqual(DocList.parse(JSON.parse(peer)).map((d) => d.id), ['deploy-runbook']);
  assert.deepEqual(daemonPids(world), [pid], 'the same daemon');
});

test('a failure while a connection is set up, or one nothing caught, ends only that connection', async (t) => {
  const world = newWorld(t);
  const sock = path.join(world.sockDir, 'faulty.sock');
  const child = spawn(NODE, [path.join(HERE, 'daemon-faulty.ts'), sock], {
    env: world.env(),
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk: string) => {
    stderr += chunk;
  });
  t.after(() => child.kill('SIGKILL'));
  await waitFor('the faulty daemon to listen', () => fs.existsSync(sock));

  // 1: the server cannot be made. The connection is closed on the daemon's side, and the daemon is still there.
  const first = await connectTo(sock);
  assert.ok(await closedWithin(first, 3000), 'the connection whose setup threw is closed');
  assert.equal(child.exitCode, null, 'the daemon is alive');

  // 2: a timer throws after the server was made. The connection itself is served, and so is the next one.
  const second = await connectTo(sock);
  assert.ok(await answersInitialize(second), 'a connection is served while an exception goes uncaught beside it');
  await sleep(100);
  assert.equal(child.exitCode, null, 'the daemon survived the exception');

  // 3: a promise rejects with nobody listening.
  const third = await connectTo(sock);
  assert.ok(await answersInitialize(third), 'and an unhandled rejection');
  const fourth = await connectTo(sock);
  assert.ok(await answersInitialize(fourth), 'a connection after all of them is served as usual');
  assert.equal(child.exitCode, null);
  assert.match(stderr, /no server for this connection/, 'what happened is said, on stderr');
  assert.match(stderr, /thrown from a timer/);
  assert.match(stderr, /rejected, and nobody asked/);

  for (const c of [second, third, fourth]) c.destroy();
  child.kill('SIGTERM');
  await new Promise((resolve) => child.once('close', resolve));
});

// `nc -U` closes its writing side when its own stdin ends, which is how a session's server is ended, and it then waits for the other side to close. A net.Server keeps a half-closed socket open for writing unless it is told otherwise (allowHalfOpen), so the daemon must NOT be told: the peer would wait for ever, the connection would stay counted, and the daemon would never idle out. The `nc` of this machine exits within a few milliseconds of the end of its stdin; this pins that, at the level the daemon controls.
test('a peer that closes its writing side is released, and the daemon idles out after it', async (t) => {
  const world = newWorld(t);
  const served = runCli(['serve', '--idle', '1'], world.env());
  assert.equal(served.code, 0, served.stderr);
  const sock = served.stdout.trim();
  const pid = await onlyDaemon(world);

  const conn = await connectTo(sock, true);
  assert.ok(await answersInitialize(conn), 'the connection is served');
  const released = closedWithin(conn, 2000);
  conn.end();
  assert.ok(await released, 'the daemon closed its side when the peer closed its own');

  await waitFor('the daemon to leave once the half-closed peer is gone', () => !alive(pid), 6000);
  assert.deepEqual(sockets(world), []);
  assert.deepEqual(daemonPids(world), []);
});

test('nc -U, as a bridge runs it, exits when its stdin ends', async (t) => {
  const world = newWorld(t);
  const peer = startBridge(world);
  t.after(() => peer.end());
  await peer.handshake();
  assert.deepEqual(await peer.toolNames(), TOOL_NAMES);
  const started = Date.now();
  peer.child.stdin.end();
  const code = await Promise.race([peer.exited, sleep(3000).then(() => 'timeout' as const)]);
  assert.notEqual(code, 'timeout', 'the bridge ended with its stdin');
  assert.ok(Date.now() - started < 3000);
});
