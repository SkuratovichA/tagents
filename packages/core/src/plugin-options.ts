// A plugin's options, read from a file of their own.
//
// The neovim way: config.toml holds the list of what is enabled, and each plugin's options live in `<configDir>/plugins/<name>.toml`. One file per plugin keeps the enable list short enough to read at a glance, lets a plugin grow options without anyone editing a shared file, and lets a dotfiles repo commit each plugin's settings on their own.
//
// Nothing here throws: a missing file is the schema's defaults, and a file that does not parse or does not fit the schema comes back as a list of problems, one line each, for the caller to print before it gives up.
import path from 'node:path';
import type { z } from 'zod';
import { parseConfigFile } from './config-file.ts';
import { issueLines } from './zod-issues.ts';

export const PLUGIN_OPTIONS_DIR = 'plugins';

/** `<configDir>/plugins/<name>.toml`, whether it is there yet or not. */
export function pluginOptionsFile(configDir: string, name: string): string {
  return path.join(configDir, PLUGIN_OPTIONS_DIR, `${name}.toml`);
}

export type OptionsResult<T> =
  | { readonly ok: true; readonly value: T; readonly file: string; readonly found: boolean }
  | { readonly ok: false; readonly file: string; readonly problems: readonly string[] };

/** The options file of plugin `name`, checked against `schema`. */
export function loadPluginOptions<S extends z.ZodType>(
  configDir: string,
  name: string,
  schema: S
): OptionsResult<z.infer<S>> {
  const file = pluginOptionsFile(configDir, name);
  let raw: unknown = {};
  let found = false;
  try {
    raw = parseConfigFile(file);
    found = true;
  } catch (e) {
    const code = e instanceof Error ? (e as NodeJS.ErrnoException).code : undefined;
    if (code !== 'ENOENT') {
      return { ok: false, file, problems: [`${file}: ${e instanceof Error ? e.message : String(e)}`] };
    }
  }
  const checked = schema.safeParse(raw);
  if (!checked.success) return { ok: false, file, problems: issueLines(checked.error) };
  return { ok: true, value: checked.data, file, found };
}
