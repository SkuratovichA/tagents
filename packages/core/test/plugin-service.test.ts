// Running a plugin's service in-process: the half of the host a daemon uses.
//
// The consumer this was written for is the tg-orchestrator: its permanent entry
// point (`node src/runner.mjs`, what launchd runs) imports its own plugin and
// asks core to run one service of it. There is no config.toml in that path —
// the process already knows which plugin it is — so everything here is driven
// the way that entry point drives it: a definition object, a context built from
// it, one named service, and the three handles a supervisor holds.
import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { createAgentFeed } from '../src/agent-events.ts';
import { stateDir } from '../src/agent-state.ts';
import { loadPlugins } from '../src/host.ts';
import { definePlugin, type PluginDef, type ServiceHandle } from '../src/plugin.ts';
import { createContext, mergeLocales, runService } from '../src/service.ts';
import { tmpDir } from '../src/testkit.ts';
import { FIXTURES } from './helpers.ts';
import fs from 'node:fs';

/** A service that records every lifecycle call and ends on its own terms. */
function trackedPlugin(): { def: PluginDef; calls: string[]; finish: () => void } {
  const calls: string[] = [];
  let finish: () => void = () => undefined;
  const done = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const def = definePlugin({
    name: 'tracked',
    apiVersion: 1,
    locales: { en: { tracked: { hello: 'hello from the plugin' } }, de: { tracked: { hello: 'hallo' } } },
    services: [
      {
        name: 'daemon',
        start: async (ctx): Promise<ServiceHandle> => {
          calls.push(`start:${ctx.driver.name}`);
          return {
            drain: async (): Promise<void> => {
              calls.push('drain');
            },
            stop: (reason?: string): void => {
              calls.push(`stop:${reason ?? ''}`);
              finish();
            },
            done,
          };
        },
      },
    ],
  });
  return { def, calls, finish };
}

test('createContext hands the plugin a driver, its own catalogue and a config dir', () => {
  const { def } = trackedPlugin();
  const lines: string[] = [];
  const ctx = createContext({
    plugin: def,
    log: (...parts) => lines.push(parts.join(' ')),
    configDir: '/x/tagents',
  });
  assert.equal(ctx.driver.name, 'claude-headless');
  assert.equal(ctx.configDir, '/x/tagents');
  ctx.log('a', 'b');
  assert.deepEqual(lines, ['a b']);
  // The plugin's namespace is reachable, and core's own still is. A plugin key
  // needs the defaultValue overload to typecheck: core's `declare module
  // 'i18next'` types TFunction against core's OWN catalogue, so a plugin with
  // its own key union keeps its own `t` and uses ctx.t for core's strings.
  assert.equal(ctx.t('tracked:hello', { defaultValue: 'MISS' }), 'hello from the plugin');
  assert.equal(ctx.t('unknownCommand', { command: 'x' }), 'unknown command: x');
});

test('a locale only the plugin speaks is a locale the context can be asked for', () => {
  const { def } = trackedPlugin();
  const say = (locale: string): string =>
    createContext({ plugin: def, locale }).t('tracked:hello', { defaultValue: 'MISS' });
  assert.equal(say('de'), 'hallo');
  // ...and an unknown one falls back rather than printing keys.
  assert.equal(say('xx'), 'hello from the plugin');
});

test('mergeLocales lays the plugin over core without either shadowing the other', () => {
  const merged = mergeLocales(trackedPlugin().def);
  assert.deepEqual(Object.keys(merged).sort(), ['de', 'en', 'ru']);
  assert.deepEqual(Object.keys(merged['en'] ?? {}).sort(), ['core', 'tracked']);
  assert.ok(Object.keys(merged['ru'] ?? {}).includes('core'), 'core keeps the locales the plugin does not speak');
});

test('runService starts the named service and hands back drain / stop / done', async () => {
  const { def, calls } = trackedPlugin();
  const ctx = createContext({ plugin: def });
  const svc = await runService(def, 'daemon', ctx);
  assert.deepEqual(calls, ['start:claude-headless']);
  await svc.drain();
  assert.deepEqual(calls, ['start:claude-headless', 'drain']);
  svc.stop('drain');
  assert.deepEqual(calls, ['start:claude-headless', 'drain', 'stop:drain']);
  await svc.done; // the service's own `done`, resolved by its stop
});

test('a service with no `done` of its own is over once it has been asked to stop', async () => {
  const def = definePlugin({
    name: 'plain',
    apiVersion: 1,
    services: [
      {
        name: 'ticker',
        start: async (): Promise<ServiceHandle> => ({
          drain: async (): Promise<void> => undefined,
          stop: (): void => undefined,
        }),
      },
    ],
  });
  const svc = await runService(def, 'ticker', createContext({ plugin: def }));
  let settled = false;
  void svc.done.then(() => {
    settled = true;
  });
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(settled, false, 'a running service is not done');
  svc.stop();
  await svc.done;
});

test('asking for a service a plugin does not have throws with both names', async () => {
  const { def } = trackedPlugin();
  await assert.rejects(() => runService(def, 'nope', createContext({ plugin: def })), {
    message: 'plugin "tracked" has no service "nope" (it has: daemon)',
  });
});

// SIGINT is not emitted here: the test runner may listen to it as well.
for (const sig of ['SIGTERM', 'SIGHUP'] as const) {
  test(`with signals:true a ${sig} stops the service, and the listeners leave with it`, async () => {
    const { def, calls } = trackedPlugin();
    const watched = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;
    const before = watched.map((s) => process.listenerCount(s));
    const svc = await runService(def, 'daemon', createContext({ plugin: def }), { signals: true });
    assert.deepEqual(
      watched.map((s) => process.listenerCount(s)),
      before.map((n) => n + 1),
      'a daemon handles the interrupt, the terminate and the hang-up the same way'
    );
    process.emit(sig, sig);
    await svc.done;
    assert.deepEqual(calls, ['start:claude-headless', `stop:${sig}`], 'the signal name is what the service logs');
    assert.deepEqual(
      watched.map((s) => process.listenerCount(s)),
      before,
      'a stopped service leaves the process as it found it'
    );
  });
}

/** A service whose start() waits for `release()`, then resolves with a handle that logs. */
function slowStart(o: { stopThrows?: boolean } = {}): { def: PluginDef; calls: string[]; release: () => void; fail: (e: Error) => void } {
  const calls: string[] = [];
  let release: () => void = () => undefined;
  let fail: (e: Error) => void = () => undefined;
  const gate = new Promise<void>((resolve, reject) => {
    release = resolve;
    fail = reject;
  });
  const def = definePlugin({
    name: 'slow',
    apiVersion: 1,
    services: [
      {
        name: 'daemon',
        start: async (): Promise<ServiceHandle> => {
          calls.push('start:begin');
          await gate;
          calls.push('start:end');
          return {
            drain: async (): Promise<void> => undefined,
            stop: (reason?: string): void => {
              calls.push(`stop:${reason ?? ''}`);
              if (o.stopThrows) throw new Error('stop failed');
            },
          };
        },
      },
    ],
  });
  return { def, calls, release, fail };
}

test('with signals:true a signal that arrives while start() is still running stops the service once start has resolved', async () => {
  const { def, calls, release } = slowStart();
  const watched = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;
  const before = watched.map((s) => process.listenerCount(s));
  const starting = runService(def, 'daemon', createContext({ plugin: def }), { signals: true });
  assert.deepEqual(
    watched.map((s) => process.listenerCount(s)),
    before.map((n) => n + 1),
    'the handlers are in before start() has returned, or the default action would kill the process'
  );

  process.emit('SIGTERM', 'SIGTERM');
  process.emit('SIGHUP', 'SIGHUP');
  assert.deepEqual(calls, ['start:begin'], 'nothing to stop yet: the signal is remembered, not acted on');

  release();
  const svc = await starting;
  await svc.done;
  assert.deepEqual(calls, ['start:begin', 'start:end', 'stop:SIGTERM'], 'stopped once, after start, by the first signal');
  assert.deepEqual(
    watched.map((s) => process.listenerCount(s)),
    before,
    'a stopped service leaves the process as it found it'
  );
});

test('with signals:true a start() that rejects leaves no handler behind and stops nothing', async () => {
  const { def, calls, fail } = slowStart();
  const watched = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;
  const before = watched.map((s) => process.listenerCount(s));
  const starting = runService(def, 'daemon', createContext({ plugin: def }), { signals: true });
  process.emit('SIGTERM', 'SIGTERM');
  fail(new Error('the lock is held'));
  await assert.rejects(starting, { message: 'the lock is held' });
  assert.deepEqual(calls, ['start:begin'], 'there was nothing to stop');
  assert.deepEqual(
    watched.map((s) => process.listenerCount(s)),
    before
  );
});

test('with signals:true a second signal while the stop is still draining is swallowed, and the handlers go when the service is done', async () => {
  const calls: string[] = [];
  let drained: () => void = () => undefined;
  const done = new Promise<void>((resolve) => {
    drained = resolve;
  });
  const def = definePlugin({
    name: 'held',
    apiVersion: 1,
    services: [
      {
        name: 'daemon',
        start: async (): Promise<ServiceHandle> => ({
          drain: async (): Promise<void> => undefined,
          // The stop begins at once and is over only when `done` resolves, as a
          // real service's is once its in-flight work has settled.
          stop: (reason?: string): void => {
            calls.push(`stop:${reason ?? ''}`);
          },
          done,
        }),
      },
    ],
  });
  const watched = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;
  const before = watched.map((s) => process.listenerCount(s));
  const svc = await runService(def, 'daemon', createContext({ plugin: def }), { signals: true });

  process.emit('SIGTERM', 'SIGTERM');
  process.emit('SIGHUP', 'SIGHUP');
  process.emit('SIGTERM', 'SIGTERM');
  assert.deepEqual(calls, ['stop:SIGTERM'], 'one stop, by the first signal');
  assert.deepEqual(
    watched.map((s) => process.listenerCount(s)),
    before.map((n) => n + 1),
    'the handlers stay while the stop drains: with none, a second signal would take the default action and kill the process with its lock held'
  );

  drained();
  await svc.done;
  assert.deepEqual(
    watched.map((s) => process.listenerCount(s)),
    before,
    'a stopped service leaves the process as it found it'
  );
  assert.deepEqual(calls, ['stop:SIGTERM']);
});

test('with signals:true a stop that throws for a signal received during start() rejects runService and leaves no handler behind', async () => {
  const { def, release } = slowStart({ stopThrows: true });
  const watched = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;
  const before = watched.map((s) => process.listenerCount(s));
  const starting = runService(def, 'daemon', createContext({ plugin: def }), { signals: true });
  process.emit('SIGTERM', 'SIGTERM');
  release();
  await assert.rejects(starting, { message: 'stop failed' });
  assert.deepEqual(
    watched.map((s) => process.listenerCount(s)),
    before,
    'nobody holds the handle, so nothing is left to swallow the next signal'
  );
});

test('without signals:true the process keeps its own SIGTERM handling', async () => {
  const { def } = trackedPlugin();
  const before = process.listenerCount('SIGTERM');
  const svc = await runService(def, 'daemon', createContext({ plugin: def }));
  assert.equal(process.listenerCount('SIGTERM'), before);
  svc.stop('done');
  await svc.done;
});

test('a plugin loaded from disk runs through the same two calls', async () => {
  const tmp = tmpDir('plugin-service-test');
  try {
    const file = path.join(tmp, 'config.toml');
    fs.writeFileSync(file, `[plugins.fixture]\nfrom = ${JSON.stringify(path.join(FIXTURES, 'plugin', 'good'))}\n`);
    const loaded = await loadPlugins(file);
    const plugin = loaded.plugins[0]?.def;
    assert.ok(plugin, 'the fixture plugin loads');
    const svc = await runService(plugin, 'ticker', createContext({ plugin, configDir: tmp }));
    svc.stop();
    await svc.done;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('a context without agents follows the default state dir and touches nothing there', () => {
  const dir = tmpDir('ctx-agents');
  const saved = process.env['TA_STATE_DIR'];
  process.env['TA_STATE_DIR'] = dir;
  try {
    const ctx = createContext({ plugin: definePlugin({ name: 'x', apiVersion: 1 }) });
    assert.equal(ctx.agents.dir, stateDir());
    assert.equal(ctx.agents.dir, dir);
    assert.deepEqual(fs.readdirSync(dir), []);
  } finally {
    if (saved === undefined) delete process.env['TA_STATE_DIR'];
    else process.env['TA_STATE_DIR'] = saved;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a context given an agent feed passes it through', () => {
  const agents = createAgentFeed('/somewhere/else');
  const ctx = createContext({ plugin: definePlugin({ name: 'x', apiVersion: 1 }), agents });
  assert.equal(ctx.agents, agents);
});
