// Loading plugins.
//
// EXPLICIT LISTING ONLY. The host reads ~/.config/tagents/config.yaml and
// imports exactly what the `plugins:` map names — it never scans node_modules,
// never walks a directory looking for something that looks like a plugin.
// Scanning is how a machine ends up running code nobody chose; a list is a
// decision somebody can read.
//
//   plugins:
//     tg-orchestrator:
//       from: ../telegram-bots/orchestrator   # a path, or a package name
//
// `from` points at a PACKAGE, and the package says where its code is in its own
// package.json: { "tagents": { "entry": "./dist/plugin.js" } }. That indirection
// is what lets a plugin move its build output without every config on the
// machine following it.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { parse as parseYaml } from 'yaml';
import { z } from 'zod';
import { PLUGIN_API_VERSION, type PluginDef } from './plugin.ts';
import { tryCatch } from './result.ts';

export const CONFIG_BASENAME = 'config.yaml';

/** ~/.config/tagents, or $TAGENTS_CONFIG_DIR. */
export function configDir(env: NodeJS.ProcessEnv = process.env): string {
  const fromEnv = env['TAGENTS_CONFIG_DIR'];
  if (fromEnv && fromEnv.trim()) return fromEnv;
  const xdg = env['XDG_CONFIG_HOME'];
  return path.join(xdg && xdg.trim() ? xdg : path.join(os.homedir(), '.config'), 'tagents');
}

export function configFile(env: NodeJS.ProcessEnv = process.env): string {
  return path.join(configDir(env), CONFIG_BASENAME);
}

const EntrySchema = z.object({ from: z.string().min(1) });
const ConfigSchema = z.object({ plugins: z.record(z.string(), EntrySchema).optional() });
export type PluginEntry = z.infer<typeof EntrySchema>;

export interface PluginListing {
  readonly name: string;
  readonly from: string;
}

export interface LoadedPlugin extends PluginListing {
  readonly dir: string;
  readonly entry: string;
  readonly def: PluginDef;
}

export interface PluginError extends PluginListing {
  readonly error: string;
}

export interface LoadResult {
  readonly file: string;
  readonly plugins: readonly LoadedPlugin[];
  readonly errors: readonly PluginError[];
}

/** The configured plugins, in file order. A missing config file is not an error. */
export function readPluginList(file = configFile()): PluginListing[] {
  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return [];
  }
  const parsed = ConfigSchema.safeParse(parseYaml(text) ?? {});
  if (!parsed.success) return [];
  return Object.entries(parsed.data.plugins ?? {}).map(([name, e]) => ({ name, from: e.from }));
}

/** Where `from` lives on disk: a path (relative to the config) or a package. */
export function resolvePackageDir(from: string, base: string): string {
  if (from.startsWith('.') || path.isAbsolute(from)) return path.resolve(base, from);
  const require_ = createRequire(path.join(base, CONFIG_BASENAME));
  return path.dirname(require_.resolve(`${from}/package.json`));
}

const ManifestSchema = z.object({ tagents: z.object({ entry: z.string().min(1) }) });

const PluginDefSchema = z.object({
  name: z.string().min(1),
  apiVersion: z.literal(PLUGIN_API_VERSION),
});

/** Import one plugin. Throws with a sentence a human can act on. */
export async function loadPlugin(listing: PluginListing, base: string): Promise<LoadedPlugin> {
  const dir = resolvePackageDir(listing.from, base);
  const manifestFile = path.join(dir, 'package.json');
  let manifestText: string;
  try {
    manifestText = fs.readFileSync(manifestFile, 'utf8');
  } catch {
    throw new Error(`no package.json at ${dir}`);
  }
  const manifest = ManifestSchema.safeParse(JSON.parse(manifestText));
  if (!manifest.success) throw new Error(`${manifestFile} has no "tagents": { "entry": … }`);
  const entry = path.resolve(dir, manifest.data.tagents.entry);
  const [mod, importError] = await tryCatch<Record<string, unknown>>(import(pathToFileURL(entry).href));
  if (importError) throw new Error(`importing ${entry}: ${importError.message}`);
  const exported = mod?.['default'] ?? mod?.['plugin'];
  const shape = PluginDefSchema.safeParse(exported);
  if (!shape.success)
    throw new Error(`${entry} must default-export a definePlugin({ name, apiVersion: ${PLUGIN_API_VERSION} }) object`);
  return { ...listing, dir, entry, def: exported as PluginDef };
}

/**
 * Load everything the config lists. One broken plugin is reported, not thrown:
 * the host stays usable with the plugins that do work.
 */
export async function loadPlugins(file = configFile()): Promise<LoadResult> {
  const base = path.dirname(file);
  const plugins: LoadedPlugin[] = [];
  const errors: PluginError[] = [];
  for (const listing of readPluginList(file)) {
    const [loaded, error] = await tryCatch(loadPlugin(listing, base));
    if (error) errors.push({ ...listing, error: error.message });
    else if (loaded) plugins.push(loaded);
  }
  return { file, plugins, errors };
}
