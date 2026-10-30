// Where the documents are, and where the index goes.
//
// Two answers, three sources each, in the order a person expects: what this
// invocation said (--dir / --db), what the environment says
// (TAGENTS_KNOWLEDGE_DIR / TAGENTS_KNOWLEDGE_DB), what the machine's config
// says (~/.config/tagents/config.toml, the same file core's plugin host reads).
// There is no default knowledge directory on purpose: guessing one would index
// whatever happened to be under it.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { z } from 'zod';
import { configDir, configFile, parseConfigFile } from '@tagents/core';

export const DB_BASENAME = 'knowledge.sqlite';
/** What was read, kept apart from the index: the index is derived and rebuilt, this is not. */
export const USAGE_BASENAME = 'knowledge-usage.sqlite';

/** '~/x' → '/Users/me/x'. A config file written by a human contains tildes. */
export function expandHome(p: string, home: string = os.homedir()): string {
  if (p === '~') return home;
  return p.startsWith('~/') ? path.join(home, p.slice(2)) : p;
}

// Only the knowledge section is described here; core owns `plugins:`, and a
// config carrying keys this package has never heard of is not an error.
// schemas/config.schema.json describes this section too; test/config-schema.test.ts keeps the two from drifting.
export const ConfigSchema = z.object({
  knowledge: z.object({ dir: z.string().min(1) }).loose().optional(),
});

/** `knowledge.dir` from the config, resolved against the config dir. */
export function configuredDir(file: string = configFile()): string | null {
  let raw: unknown;
  try {
    raw = parseConfigFile(file);
  } catch {
    return null;
  }
  const parsed = ConfigSchema.safeParse(raw);
  const dir = parsed.success ? parsed.data.knowledge?.dir : undefined;
  return dir === undefined ? null : path.resolve(path.dirname(file), expandHome(dir));
}

/** What to write in the config to name the folder. */
export function dirSnippet(): string {
  return '  [knowledge]\n  dir = "~/git/personal/knowledge"';
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

/** The path a flag or, failing that, a variable gave, made absolute; null when neither said anything. */
function givenPath(explicit: string | null, fromEnv: string | undefined): string | null {
  for (const value of [explicit, fromEnv]) if (value && value.trim()) return path.resolve(expandHome(value));
  return null;
}

/** The index file. Unlike the documents, this one has a default. */
export function resolveDb(explicit: string | null = null, env: NodeJS.ProcessEnv = process.env): string {
  return givenPath(explicit, env['TAGENTS_KNOWLEDGE_DB']) ?? path.join(configDir(env), DB_BASENAME);
}

/**
 * The usage store: what this invocation said (--usage-db), what the environment
 * says, else a file of its own beside the index in use. Beside it, rather than
 * always in the config directory, so that a run on a scratch index (`--db`, a
 * test, a second corpus) gets a scratch store and cannot write into the real one.
 */
export function resolveUsageDb(
  explicit: string | null,
  indexFile: string,
  env: NodeJS.ProcessEnv = process.env
): string {
  return givenPath(explicit, env['TAGENTS_KNOWLEDGE_USAGE_DB']) ?? path.join(path.dirname(indexFile), USAGE_BASENAME);
}
