// Finding a plugin package, and editing the `plugins` entries of the config — nothing else in that file.
//
// The file is the OWNER'S. It carries comments explaining why a rule exists, the key order they chose, the spacing they aligned by hand, and (see config.example.toml) a sibling config.<hostname>.toml whose subtrees replace the ones here. A round trip through a stringifier keeps the meaning of all of that and still rewrites bytes it had no business touching: `args = x # why` loses the alignment somebody put there, and a TOML library has no comments to write back at all.
//
// So the parse is the TOML parser's — it knows whether an entry already exists — and the EDIT is a splice of text: an entry is a `[plugins.NAME]` section appended at the end and cut out by its header lines. Everything outside the splice comes back byte for byte, and the result is parsed again before it is written.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { createRequire } from 'node:module';
import { parse as parseToml } from 'smol-toml';
import { z } from 'zod';
import { writeAtomic } from './atomic.ts';
import { tomlKey, tomlString } from './config-file.ts';
import { PLUGIN_API_VERSION } from './plugin.ts';

// ------------------------------------------------------------- the package ---

export interface PluginPackage {
  /** Where the package really is on disk. */
  readonly dir: string;
  /** What goes in the config as `from:` — an absolute path, or a package name. */
  readonly from: string;
  /** The `name` in its package.json. */
  readonly packageName: string;
  /** Its `tagents.entry`, resolved, and known to exist. */
  readonly entry: string;
}

/**
 * Why a package could not be added. `not-found` is an error (nothing was
 * resolved); the other two are refusals (something IS there and it is not a
 * plugin), and the CLI's exit codes keep them apart.
 */
export type PackageProblem = 'not-found' | 'bad-manifest' | 'no-entry';

export type ResolveResult =
  | { readonly ok: true; readonly pkg: PluginPackage }
  | { readonly ok: false; readonly problem: PackageProblem; readonly detail: string };

const ManifestSchema = z.object({
  name: z.string().min(1).optional(),
  tagents: z.object({
    apiVersion: z.literal(PLUGIN_API_VERSION),
    entry: z.string().min(1),
  }),
});

const looksLikePath = (spec: string): boolean =>
  spec.startsWith('.') || spec.startsWith('~') || path.isAbsolute(spec);

const expandTilde = (spec: string): string =>
  spec === '~' || spec.startsWith('~/') ? path.join(os.homedir(), spec.slice(1)) : spec;

/** Where `pnpm root -g` says globally installed packages live, if pnpm answers. */
function globalRoot(): string | null {
  try {
    const out = execFileSync('pnpm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const dir = out.trim();
    return dir && fs.existsSync(dir) ? dir : null;
  } catch {
    return null;
  }
}

/** A package name resolvable from `cwd`, then from the global store. */
function locateByName(spec: string, cwd: string): string | null {
  try {
    const require_ = createRequire(path.join(cwd, 'package.json'));
    return path.dirname(require_.resolve(`${spec}/package.json`));
  } catch {
    const global_ = globalRoot();
    if (!global_) return null;
    const dir = path.join(global_, spec);
    return fs.existsSync(path.join(dir, 'package.json')) ? dir : null;
  }
}

/**
 * Resolve what `plugin add <spec>` was given: a directory (`.`, `..`, `/x`,
 * `~/x`) or the name of a package installed where the caller stands.
 *
 * A directory is written back as an ABSOLUTE path, never as the relative one
 * that was typed: the host resolves a relative `from:` against the config file,
 * and the caller's cwd is somewhere else entirely. A package name is written
 * back as itself, so the host resolves it the same way npm would.
 */
export function resolvePluginPackage(spec: string, cwd: string): ResolveResult {
  const byPath = looksLikePath(spec);
  const dir = byPath ? path.resolve(cwd, expandTilde(spec)) : locateByName(spec, cwd);
  if (dir === null) return { ok: false, problem: 'not-found', detail: spec };

  const manifestFile = path.join(dir, 'package.json');
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  } catch {
    return { ok: false, problem: byPath ? 'not-found' : 'bad-manifest', detail: manifestFile };
  }
  const manifest = ManifestSchema.safeParse(raw);
  if (!manifest.success) return { ok: false, problem: 'bad-manifest', detail: manifestFile };

  const entry = path.resolve(dir, manifest.data.tagents.entry);
  if (!fs.existsSync(entry)) return { ok: false, problem: 'no-entry', detail: entry };

  return {
    ok: true,
    pkg: {
      dir,
      from: byPath ? dir : spec,
      packageName: manifest.data.name ?? path.basename(dir),
      entry,
    },
  };
}

/** `@tagents/plugin-telegram` → `telegram`: the key an entry gets by default. */
export function defaultPluginName(packageName: string): string {
  const slash = packageName.lastIndexOf('/');
  const bare = slash === -1 ? packageName : packageName.slice(slash + 1);
  const trimmed = bare.replace(/^tagents-plugin-/, '').replace(/^plugin-/, '');
  return trimmed || bare;
}

// ------------------------------------------------------------ the edits ----

export type AddOutcome = 'added' | 'exists';
export type RemoveOutcome = 'removed' | 'absent';

/** Add `name` under `plugins`. */
export function addPluginEntry(file: string, name: string, from: string): AddOutcome {
  return addTomlEntry(file, name, from);
}

/** Drop `name` from `plugins`. */
export function removePluginEntry(file: string, name: string): RemoveOutcome {
  return removeTomlEntry(file, name);
}

// ------------------------------------------------------------------- toml ----

function tomlEntry(file: string, name: string, from: string): string {
  const written = tomlString(from);
  if (written === null) throw new Error(`${file}: ${JSON.stringify(from)} has a control character or a lone surrogate in it, which cannot be written in a config tagents reads`);
  const key = tomlKey(name);
  if (key === null) throw new Error(`${file}: ${JSON.stringify(name)} has a control character or a lone surrogate in it, which cannot be written in a config tagents reads`);
  return `[plugins.${key}]\nfrom = ${written}\n`;
}

const TomlDoc = z.object({ plugins: z.record(z.string(), z.unknown()).optional() });

/** The parsed document and its `plugins` table. Throws, naming the file, on text that is not TOML. */
function parseTomlFile(file: string, text: string, what = ''): { doc: Record<string, unknown>; plugins: Record<string, unknown> } {
  let doc: Record<string, unknown>;
  try {
    doc = parseToml(text);
  } catch (e) {
    throw new Error(`${file}: ${what}${e instanceof Error ? e.message : String(e)}`);
  }
  const shaped = TomlDoc.safeParse(doc);
  if (!shaped.success) throw new Error(`${file}: ${what}plugins must be a table of tables`);
  return { doc, plugins: shaped.data.plugins ?? {} };
}

const fromOf = (entry: unknown): unknown =>
  typeof entry === 'object' && entry !== null && 'from' in entry ? entry.from : undefined;

/**
 * Append `[plugins.NAME]` after everything that is there, behind one blank line.
 * A section header at the end of the file is valid whatever precedes it, so nothing in the file has to be understood to place it — and a `plugins` that is written inline (`plugins = { … }`), where it is not valid, fails the parse that follows and is refused with the file untouched.
 */
function addTomlEntry(file: string, name: string, from: string): AddOutcome {
  const text = readText(file);
  if (Object.hasOwn(parseTomlFile(file, text).plugins, name)) return 'exists';

  const head = text === '' || text.endsWith('\n') ? text : `${text}\n`;
  const next = `${head}${head === '' ? '' : '\n'}${tomlEntry(file, name, from)}`;

  const after = parseTomlFile(file, next, 'the edit would not parse: ');
  if (fromOf(after.plugins[name]) !== from) throw new Error(`${file}: the edit did not take`);
  save(file, next);
  return 'added';
}

/** The table a `[a.b]` / `[[a.b]]` header line names, as a key path; null for any other line. */
function headerPath(line: string): string[] | null {
  if (!line.trimStart().startsWith('[')) return null;
  let parsed: unknown;
  try {
    parsed = parseToml(line);
  } catch {
    return null;
  }
  const keys: string[] = [];
  while (typeof parsed === 'object' && parsed !== null) {
    const node: unknown = Array.isArray(parsed) ? parsed[0] : parsed;
    if (typeof node !== 'object' || node === null) break;
    const own = Object.entries(node);
    const only = own[0];
    if (own.length !== 1 || only === undefined) break;
    keys.push(only[0]);
    parsed = only[1];
  }
  return keys;
}

const blank = (line: string): boolean => line.trim() === '';
const commentOnly = (line: string): boolean => line.trimStart().startsWith('#');

/**
 * Cut every section of `plugins.NAME` — its own `[plugins.NAME]` and any `[plugins.NAME.…]` under it — out of the lines. A section runs from its header to the next header, less the comment lines just above that header, which belong to it. Comments above the removed header stay: they are somebody's note, and a note about an entry is not part of the entry.
 */
function cutSections(lines: string[], name: string): string[] {
  const cut = new Set<number>();
  let inside = false;
  let start = 0;
  const close = (end: number): void => {
    let stop = end;
    while (stop > start && commentOnly(lines[stop - 1] ?? '')) stop -= 1;
    // At the end of the file the blank line add put before the section goes with it.
    if (end === lines.length && blank(lines[start - 1] ?? 'x')) start -= 1;
    for (let i = start; i < stop; i += 1) cut.add(i);
  };
  lines.forEach((line, i) => {
    const keys = headerPath(line);
    if (keys === null) return;
    if (inside) close(i);
    inside = keys[0] === 'plugins' && keys[1] === name;
    start = i;
  });
  if (inside) close(lines.length);
  return lines.filter((_, i) => !cut.has(i));
}

function removeTomlEntry(file: string, name: string): RemoveOutcome {
  const text = readText(file);
  if (!text) return 'absent';
  const before = parseTomlFile(file, text);
  if (!Object.hasOwn(before.plugins, name)) return 'absent';

  const next = cutSections(text.split(/(?<=\n)/), name).join('');

  const after = parseTomlFile(file, next, 'the edit would not parse: ');
  if (Object.hasOwn(after.plugins, name))
    throw new Error(`${file}: ${name} is not written as a [plugins.${tomlKey(name) ?? JSON.stringify(name)}] section, so it cannot be removed here — remove it by hand`);
  const rest = Object.fromEntries(Object.entries(before.plugins).filter(([key]) => key !== name));
  if (!isDeepStrictEqual({ ...before.doc, plugins: rest }, { ...after.doc, plugins: after.plugins }))
    throw new Error(`${file}: removing ${name} would change something else, so nothing was written`);
  save(file, next);
  return 'removed';
}

// ------------------------------------------------------------------- file ----

function readText(file: string): string {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

function save(file: string, text: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  writeAtomic(file, text);
}
