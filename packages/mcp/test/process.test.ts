// node --test process.test.ts
//
// Nothing started by a call outlives the call: the child leads a process group of its own, and the call ends by exit, timeout, cancellation of the request or closing of the server, with the whole group stopped each time. Every program here records the pids it starts, a test waits on a bounded poll for them to be gone, and `afterEach` kills what a failing test left.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { afterEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { callTool, resultText } from '../src/run.ts';
import { createServer } from '../src/server.ts';
import { toolSpecs } from '../src/tools.ts';
import { alive, fakeCli, fakeTool, rig, stopRigs, until, within } from './rig.ts';

afterEach(stopRigs);

/** A program that starts a `sleep 30` of its own and waits for it: two processes, both of which have to go. */
const WITH_GRANDCHILD = `echo $$ > "$D/main.pid"; sleep 30 & echo $! > "$D/grand.pid"; wait`;

const bothStarted = (made: ReturnType<typeof rig>): Promise<boolean> => until(() => Object.keys(made.pids()).length === 2, 5000);
const noneAlive = (made: ReturnType<typeof rig>): Promise<boolean> => until(() => Object.values(made.pids()).every((pid) => !alive(pid)), 5000);

test('a cancelled call stops the program and what it started, and says it was cancelled', async () => {
  const made = rig(WITH_GRANDCHILD);
  const controller = new AbortController();
  const call = callTool(fakeTool('fake_hang'), {}, { env: made.env, timeoutMs: 60_000, killGraceMs: 500 }, { signal: controller.signal });
  assert.ok(await bothStarted(made), 'the program and its sleep started');
  controller.abort();
  const result = await within(call, 5000);
  assert.ok(result !== undefined, 'the call resolved');
  assert.equal(result.isError, true);
  assert.equal(JSON.parse(resultText(result)).outcome, 'cancelled');
  assert.ok(await noneAlive(made), 'both processes are gone');
});

test('a call whose request was cancelled before it started never starts the program', async () => {
  const made = rig(`touch "$D/ran"`);
  const controller = new AbortController();
  controller.abort();
  const result = await within(callTool(fakeTool('fake_hang'), {}, { env: made.env, timeoutMs: 5000 }, { signal: controller.signal }), 5000);
  assert.ok(result !== undefined, 'the call resolved');
  assert.equal(JSON.parse(resultText(result)).outcome, 'cancelled');
  assert.equal(fs.existsSync(path.join(made.dir, 'ran')), false);
});

test('a program that ignores SIGTERM is killed once the grace is over, and not before', async () => {
  const made = rig(`trap '' TERM; echo $$ > "$D/main.pid"; while :; do sleep 1; done`);
  const controller = new AbortController();
  const started = Date.now();
  const call = callTool(fakeTool('fake_hang'), {}, { env: made.env, timeoutMs: 60_000, killGraceMs: 1500 }, { signal: controller.signal });
  assert.ok(await until(() => Object.keys(made.pids()).length === 1, 5000), 'the program started');
  controller.abort();
  const pid = made.pids()['main'];
  assert.ok(pid !== undefined);
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.ok(alive(pid), 'SIGTERM alone does not stop it');
  const result = await within(call, 8000);
  assert.ok(result !== undefined, 'the call resolved');
  assert.ok(Date.now() - started >= 1400, 'not before the grace was over');
  assert.ok(await noneAlive(made), 'SIGKILL did');
});

test('a timeout stops the whole group too, and keeps its own outcome', async () => {
  const made = rig(WITH_GRANDCHILD);
  const result = await within(callTool(fakeTool('fake_hang'), {}, { env: made.env, timeoutMs: 300, killGraceMs: 500 }), 8000);
  assert.ok(result !== undefined, 'the call resolved');
  const body = JSON.parse(resultText(result));
  assert.equal(body.outcome, 'timeout');
  assert.equal(body.exit, 4);
  assert.ok(await noneAlive(made), 'both processes are gone');
});

test('a program that exits at once and leaves a grandchild holding its pipes does not hold the call: the call ends within the drain, and the grandchild is stopped', async () => {
  const made = rig(`sleep 30 & echo $! > "$D/grand.pid"; echo done`);
  const started = Date.now();
  const result = await within(callTool(fakeTool('fake_hang'), {}, { env: made.env, timeoutMs: 60_000, drainMs: 300 }), 5000);
  assert.ok(result !== undefined, 'the call resolved');
  assert.ok(Date.now() - started < 300 + 2000, 'within the drain and a margin');
  const body = JSON.parse(resultText(result));
  assert.equal(body.exit, 0);
  assert.equal(body.stdout, 'done\n');
  assert.ok(await noneAlive(made), 'the grandchild is gone');
});

test('a holder of the pipes that left the group cannot be killed, and still does not hold the call longer than the drain', { skip: fs.existsSync('/usr/bin/perl') ? false : 'no perl to start a process in a session of its own' }, async () => {
  const made = rig(`/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec "sleep", "30"' & echo $! > "$D/escaped.pid"; echo done`);
  const started = Date.now();
  const result = await within(callTool(fakeTool('fake_hang'), {}, { env: made.env, timeoutMs: 60_000, drainMs: 300 }), 5000);
  assert.ok(result !== undefined, 'the call resolved');
  assert.ok(Date.now() - started < 300 + 2000, 'within the drain and a margin');
  assert.equal(JSON.parse(resultText(result)).stdout, 'done\n');
});

test('over MCP, a request the client cancels stops the program it started', async () => {
  const made = rig(WITH_GRANDCHILD);
  const server = createServer(toolSpecs([fakeCli]), { env: made.env, timeoutMs: 60_000, killGraceMs: 500 });
  const client = new Client({ name: 'test', version: '0.0.0' });
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverSide), client.connect(clientSide)]);
  try {
    const controller = new AbortController();
    const pending = client.callTool({ name: 'fake_hang', arguments: {} }, undefined, { signal: controller.signal });
    const rejected = assert.rejects(pending);
    assert.ok(await bothStarted(made), 'the program and its sleep started');
    controller.abort();
    await rejected;
    assert.ok(await noneAlive(made), 'both processes are gone');
  } finally {
    await client.close();
    await server.close();
  }
});

const MAIN = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'src', 'main.ts');

/** The server as a client starts it, with a call to the program of `made` in flight once the pids are written. */
async function serverWithCallInFlight(made: ReturnType<typeof rig>) {
  const contract = path.join(made.dir, 'contract.json');
  fs.writeFileSync(contract, JSON.stringify({ cli: { 'tagents-fake': { exit: fakeCli.exit, commands: fakeCli.commands } } }));
  const server = spawn(process.execPath, [MAIN, '--contract', contract], { env: { PATH: `${made.env['PATH']}:${path.dirname(process.execPath)}` }, stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = new Promise<number | null>((resolve) => server.on('exit', resolve));
  const send = (message: object): void => void server.stdin.write(`${JSON.stringify(message)}\n`);
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0.0.0' } } });
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'fake_hang', arguments: {} } });
  assert.ok(await bothStarted(made), 'the program and its sleep started');
  return { server, exited };
}

test('the server as a process: with a call in flight and stdin closed, the program it started is gone within seconds, and so is the server', async () => {
  const made = rig(WITH_GRANDCHILD);
  const { server, exited } = await serverWithCallInFlight(made);
  try {
    server.stdin.end();
    assert.ok(await noneAlive(made), 'both processes are gone');
    assert.ok((await within(exited, 5000)) !== undefined, 'the server exited');
  } finally {
    server.kill('SIGKILL');
  }
});

for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP'] as const) {
  test(`the server as a process: ${signal} stops the program of a call in flight, and the server exits`, async () => {
    const made = rig(WITH_GRANDCHILD);
    const { server, exited } = await serverWithCallInFlight(made);
    try {
      server.kill(signal);
      assert.ok(await noneAlive(made), 'both processes are gone');
      assert.ok((await within(exited, 5000)) !== undefined, 'the server exited');
    } finally {
      server.kill('SIGKILL');
    }
  });
}
