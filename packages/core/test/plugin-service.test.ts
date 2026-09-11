// Running a plugin's service in-process: the half of the host a daemon uses.
//
// The consumer this was written for is the tg-orchestrator: its permanent entry
// point (`node src/runner.mjs`, what launchd runs) imports its own plugin and
// asks core to run one service of it. There is no config.yaml in that path —
// the process already knows which plugin it is — so everything here is driven
// the way that entry point drives it: a definition object, a context built from
// it, one named service, and the three handles a supervisor holds.
import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
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

test('with signals:true a SIGTERM stops the service, and the listener leaves with it', async () => {
  const { def, calls } = trackedPlugin();
  const before = process.listenerCount('SIGTERM');
  const svc = await runService(def, 'daemon', createContext({ plugin: def }), { signals: true });
  assert.equal(process.listenerCount('SIGTERM'), before + 1);
  process.emit('SIGTERM', 'SIGTERM');
  await svc.done;
  assert.deepEqual(calls, ['start:claude-headless', 'stop:SIGTERM'], 'the signal name is what the service logs');
  assert.equal(process.listenerCount('SIGTERM'), before, 'a stopped service leaves the process as it found it');
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
    const file = path.join(tmp, 'config.yaml');
    fs.writeFileSync(file, `plugins:\n  fixture:\n    from: ${path.join(FIXTURES, 'plugin', 'good')}\n`);
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
