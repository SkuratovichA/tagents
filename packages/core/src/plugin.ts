// What a tagents plugin is.
//
// A plugin is a package that exports one definition object. It never reaches
// into the core: everything it may touch arrives in the PluginContext, and
// everything it offers is data the host walks — CLI verbs, long-running
// services, MCP tools. The point of the shape is that the host can list a
// plugin's capabilities WITHOUT running any of its code beyond the import.
//
// apiVersion is the whole compatibility story: bump it when this file changes
// in a way a plugin must know about, and the host refuses the ones still on 1.
import type { z } from 'zod';
import type { TFunction } from 'i18next';
import type { SessionDriver } from './driver.ts';

export interface PluginContext {
  /** The session backend. A plugin never spawns `claude` itself. */
  readonly driver: SessionDriver;
  /** Translator, already on the caller's locale. */
  readonly t: TFunction;
  readonly log: (...parts: string[]) => void;
  /** The tagents config dir the host is running out of (~/.config/tagents). */
  readonly configDir: string;
}

/** One CLI verb. `args` validates argv-derived input before `run` sees it. */
export interface CliCommand<S extends z.ZodType> {
  readonly name: string;
  readonly describe: string;
  readonly args: S;
  /** Resolves with the process exit code the verb wants. */
  run(a: z.infer<S>, ctx: PluginContext): Promise<number>;
}

/**
 * What a started service hands back: `drain` to stop taking new work and finish
 * what is in flight, `stop` to give up now. Never kill a live worker — ask it to
 * drain (orchestrator/LEARNING.md, 11.09.2026).
 *
 * `stop` takes the supervisor's word for WHY (a signal name, 'drain'), because
 * a daemon logs its own shutdown and "SIGTERM" and "SIGINT" are different lines
 * to whoever reads that log. It is optional: a service that does not care keeps
 * the `stop(): void` it was written with.
 *
 * `done` is how a service says IT decides when it is over — the orchestrator's
 * runner exits on its own drain handshake, not because a supervisor asked — so
 * a host that merely started it still has something to await. Optional: a
 * service that only ever stops when told has nothing to put in it, and
 * `runService` then resolves `done` when drain/stop has been asked for.
 */
export interface ServiceHandle {
  drain(): Promise<void>;
  stop(reason?: string): void;
  readonly done?: Promise<void>;
}

/** Something that keeps running. */
export interface ServiceDef {
  readonly name: string;
  start(ctx: PluginContext): Promise<ServiceHandle>;
}

/** One MCP tool the host may expose on the plugin's behalf. */
export interface McpToolDef<S extends z.ZodType> {
  readonly name: string;
  readonly describe: string;
  readonly input: S;
  run(a: z.infer<S>, ctx: PluginContext): Promise<unknown>;
}

/** The heterogeneous forms the host stores: each entry keeps its own schema. */
export type CliCommandDef = CliCommand<z.ZodType>;
export type McpTool = McpToolDef<z.ZodType>;

export interface PluginDef {
  readonly name: string;
  readonly apiVersion: 1;
  /** Extra i18next resources, keyed by locale then namespace. */
  readonly locales?: Readonly<Record<string, Readonly<Record<string, unknown>>>>;
  readonly commands?: readonly CliCommandDef[];
  readonly services?: readonly ServiceDef[];
  readonly mcpTools?: readonly McpTool[];
}

/** Identity with a type — the one function a plugin author has to remember. */
export function definePlugin(def: PluginDef): PluginDef {
  return def;
}

export const PLUGIN_API_VERSION = 1;
