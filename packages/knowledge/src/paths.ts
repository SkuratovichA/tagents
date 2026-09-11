// Where the documents are, and where the index goes.
//
// Two answers, three sources each, in the order a person expects: what this
// invocation said (--dir / --db), what the environment says
// (TAGENTS_KNOWLEDGE_DIR / TAGENTS_KNOWLEDGE_DB), what the machine's config
// says (~/.config/tagents/config.yaml, the same file core's plugin host reads).
// There is no default knowledge directory on purpose: guessing one would index
// whatever happened to be under it.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parse as parseYaml } from 'yaml';
import { z } from 'zod';
import { configDir, configFile } from '@tagents/core';

export const DB_BASENAME = 'knowledge.sqlite';

/** '~/x' → '/Users/me/x'. A config file written by a human contains tildes. */
export function expandHome(p: string, home: string = os.homedir()): string {
  if (p === '~') return home;
  return p.startsWith('~/') ? path.join(home, p.slice(2)) : p;
}

// Only the knowledge section is described here; core owns `plugins:`, and a
// config carrying keys this package has never heard of is not an error.
const ConfigSchema = z.object({
  knowledge: z.object({ dir: z.string().min(1) }).loose().optional(),
});

/** `knowledge.dir` from config.yaml, resolved against the config dir. */
export function configuredDir(file: string = configFile()): string | null {
  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  let raw: unknown;
  try {
    raw = parseYaml(text) ?? {};
  } catch {
    return null;
  }
  const parsed = ConfigSchema.safeParse(raw);
  const dir = parsed.success ? parsed.data.knowledge?.dir : undefined;
  return dir === undefined ? null : path.resolve(path.dirname(file), expandHome(dir));
}

export type DirResult =
  | { readonly ok: true; readonly dir: string }
  /** 'unset': nobody said where. 'missing': they did, and it is not there. */
  | { readonly ok: false; readonly reason: 'unset' | 'missing'; readonly dir: string | null; readonly config: string };

export function resolveDir(
  explicit: string | null = null,
  env: NodeJS.ProcessEnv = process.env
): DirResult {
  const config = configFile(env);
  const fromEnv = env['TAGENTS_KNOWLEDGE_DIR'];
  const chosen =
    explicit && explicit.trim()
      ? path.resolve(expandHome(explicit))
      : fromEnv && fromEnv.trim()
        ? path.resolve(expandHome(fromEnv))
        : configuredDir(config);
  if (chosen === null) return { ok: false, reason: 'unset', dir: null, config };
  if (!fs.existsSync(chosen)) return { ok: false, reason: 'missing', dir: chosen, config };
  return { ok: true, dir: chosen };
}

/** The index file. Unlike the documents, this one has a default. */
export function resolveDb(explicit: string | null = null, env: NodeJS.ProcessEnv = process.env): string {
  if (explicit && explicit.trim()) return path.resolve(expandHome(explicit));
  const fromEnv = env['TAGENTS_KNOWLEDGE_DB'];
  if (fromEnv && fromEnv.trim()) return path.resolve(expandHome(fromEnv));
  return path.join(configDir(env), DB_BASENAME);
}
