// Running ONE plugin's service, in this process, with no config.yaml.
//
// host.ts answers "which plugins did the machine choose?" — it reads the config
// and imports what it names. This file answers the other half: a plugin package
// whose own entry point is already running (a daemon started by launchd, a
// `node src/runner.mjs` somebody typed) needs the context and the supervision
// WITHOUT going back through a config file that would only point at itself.
//
// So: `createContext` builds the PluginContext a plugin is entitled to (a
// driver, a translator on the plugin's own catalogue, a log sink, the tagents
// config dir), and `runService` starts one named service under it and hands
// back the supervisor's three handles. Nothing here scans, reads YAML or
// imports anything: the caller already has the definition object.
import { createInstance, type Resource } from 'i18next';
import { ClaudeHeadlessDriver } from './claude-driver.ts';
import type { SessionDriver } from './driver.ts';
import { configDir as defaultConfigDir } from './host.ts';
import { DEFAULT_LOCALE, resources as coreResources } from './i18n/index.ts';
import type { PluginContext, PluginDef, ServiceHandle } from './plugin.ts';

const silent = (): void => undefined;

/**
 * Core's own catalogue with the plugin's laid over it, locale by locale and
 * namespace by namespace. The plugin owns its namespaces ('tg', 'fixture', …)
 * and core keeps 'core', so neither can quietly shadow the other's keys, and a
 * locale only the plugin speaks is still a locale this context can be asked for.
 */
export function mergeLocales(plugin: PluginDef): Resource {
  const merged: Record<string, Record<string, unknown>> = {};
  for (const [lng, namespaces] of Object.entries(coreResources)) merged[lng] = { ...namespaces };
  for (const [lng, namespaces] of Object.entries(plugin.locales ?? {})) {
    merged[lng] = { ...merged[lng], ...namespaces };
  }
  return merged as Resource;
}

export interface ContextOptions {
  /** Whose context this is: its locales are what `t` is bound to. */
  readonly plugin: PluginDef;
  readonly log?: (...parts: string[]) => void;
  /** ~/.config/tagents unless the caller knows better (TAGENTS_CONFIG_DIR). */
  readonly configDir?: string;
  /** Falls back to TAGENTS_LOCALE, then to a locale the catalogue has, then 'en'. */
  readonly locale?: string;
  /** A backend other than headless `claude` — the tests pass their own. */
  readonly driver?: SessionDriver;
}

/**
 * The PluginContext, assembled. One driver (a plugin never spawns `claude`
 * itself), one translator, one log sink, one config dir — and no globals: two
 * contexts in one process are two independent i18next instances.
 */
export function createContext(o: ContextOptions): PluginContext {
  const log = o.log ?? silent;
  const resources = mergeLocales(o.plugin);
  const wanted = o.locale ?? process.env['TAGENTS_LOCALE'];
  const lng = wanted && resources[wanted] ? wanted : DEFAULT_LOCALE;
  const ns = [...new Set(Object.values(resources).flatMap((l) => Object.keys(l)))];
  const i18n = createInstance();
  void i18n.init({
    lng,
    fallbackLng: DEFAULT_LOCALE,
    defaultNS: 'core',
    ns,
    resources,
    interpolation: { escapeValue: false },
  });
  return {
    driver: o.driver ?? new ClaudeHeadlessDriver({ log }),
    t: i18n.t,
    log,
    configDir: o.configDir ?? defaultConfigDir(),
  };
}

/** A service under supervision: the same three handles whatever started it. */
export interface RunningService {
  /** Stop taking new work, finish what is in flight. */
  drain(): Promise<void>;
  /** Give up now. `reason` reaches the service so it can log its own shutdown. */
  stop(reason?: string): void;
  /** Resolves when the service is over — on its own terms, or once asked to stop. */
  readonly done: Promise<void>;
}

export interface RunServiceOptions {
  /**
   * Wire SIGINT/SIGTERM to `stop(<signal>)`. OFF by default: a library must not
   * take a process's signals away from whoever owns it. An entry point that IS
   * the daemon passes true and gets the wiring it would otherwise write itself.
   */
  readonly signals?: boolean;
}

/**
 * Start `serviceName` of `plugin` under `ctx`. Throws — with the names in the
 * sentence — when the plugin has no such service, because an entry point that
 * silently started nothing is a dead daemon nobody notices.
 */
export async function runService(
  plugin: PluginDef,
  serviceName: string,
  ctx: PluginContext,
  o: RunServiceOptions = {}
): Promise<RunningService> {
  const def = plugin.services?.find((s) => s.name === serviceName);
  if (!def) {
    const known = (plugin.services ?? []).map((s) => s.name).join(', ') || 'none';
    throw new Error(`plugin "${plugin.name}" has no service "${serviceName}" (it has: ${known})`);
  }
  const handle: ServiceHandle = await def.start(ctx);

  // Only used when the service carries no `done` of its own: then "over" means
  // "somebody asked it to stop and it did".
  let settle: () => void = silent;
  const asked = new Promise<void>((resolve) => {
    settle = resolve;
  });
  const done = handle.done ?? asked;

  const onSignal = (sig: NodeJS.Signals): void => running.stop(sig);
  const off = (): void => {
    process.removeListener('SIGINT', onSignal);
    process.removeListener('SIGTERM', onSignal);
  };

  const running: RunningService = {
    done,
    drain: async (): Promise<void> => {
      try {
        await handle.drain();
      } finally {
        settle();
        off();
      }
    },
    stop: (reason?: string): void => {
      try {
        handle.stop(reason);
      } finally {
        settle();
        off();
      }
    },
  };

  if (o.signals) {
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
  }
  void done.then(off, off);
  return running;
}
