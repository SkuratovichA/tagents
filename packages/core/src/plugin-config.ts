// Finding a plugin package, and editing the `plugins:` map of config.yaml —
// nothing else in that file.
//
// The file is the OWNER'S. It carries comments explaining why a rule exists,
// the key order they chose, the spacing they aligned by hand, and (see
// config.example.yaml) a sibling config.<hostname>.yaml whose subtrees replace
// the ones here. A round trip through yaml's stringifier keeps the meaning of
// all of that and still rewrites bytes it had no business touching: `args: x
// # why` loses the alignment somebody put there, and anything after a `---`
// the parser never looked at is simply gone.
//
// So the parse is yaml's — a Document is what knows whether an entry already
// exists and exactly which byte range one occupies — and the EDIT is a splice
// of that range. Everything outside it comes back byte for byte.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { isMap, isNode, isScalar, parseDocument, type Document, type Pair, type YAMLMap } from 'yaml';
import { z } from 'zod';
import { writeAtomic } from './atomic.ts';
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

// ------------------------------------------------------------------- yaml ----

export type AddOutcome = 'added' | 'exists';
export type RemoveOutcome = 'removed' | 'absent';

const keyText = (key: unknown): string | null =>
  isScalar(key) && typeof key.value === 'string' ? key.value : null;

const rangeOf = (node: unknown): readonly [number, number, number] | null =>
  isNode(node) && node.range ? node.range : null;

function readText(file: string): string {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

/** Parse, or refuse: a file we cannot read is a file we must not rewrite. */
function parse(file: string, text: string): Document {
  const doc = parseDocument(text);
  const first = doc.errors[0];
  if (first) throw new Error(`${file}: ${first.message}`);
  return doc;
}

function pairOf(map: YAMLMap<unknown, unknown>, name: string): Pair<unknown, unknown> | null {
  for (const item of map.items) if (keyText(item.key) === name) return item;
  return null;
}

/** The index just past the newline that ends the line `at` sits on. */
function lineEnd(text: string, at: number): number {
  const nl = text.indexOf('\n', at);
  return nl === -1 ? text.length : nl + 1;
}

/** The index of the first character of the line `at` sits on. */
function lineStart(text: string, at: number): number {
  return text.lastIndexOf('\n', Math.max(0, at - 1)) + 1;
}

const SPACE = new Set([' ', '\t', '\n', '\r']);

/**
 * The end of the line the node really ENDS on. A block map's range runs past
 * its last newline (`from: y\n` ends at the index after the newline), so any
 * blank line behind it would otherwise be counted as part of the node — and an
 * entry inserted after one, or a removal that swallows the next key.
 */
function blockEnd(text: string, from: number, to: number): number {
  let i = Math.min(to, text.length);
  while (i > from && SPACE.has(text[i - 1] ?? '')) i -= 1;
  return lineEnd(text, i);
}

// A plain scalar unless the text would not survive as one. JSON's escaping is
// YAML's double-quoted style for everything we can produce here.
const PLAIN = /^[A-Za-z0-9_@~./+-][^#\n]*$/;

function scalar(value: string): string {
  const plain = PLAIN.test(value) && value.trim() === value && !value.includes(': ') && !value.endsWith(':');
  return plain ? value : JSON.stringify(value);
}

const entryBlock = (name: string, from: string, indent: string): string =>
  `${indent}${scalar(name)}:\n${indent}${indent}from: ${scalar(from)}\n`;

/** The indent the file already uses under `plugins:`, or two spaces. */
function indentOf(text: string, map: YAMLMap<unknown, unknown>): string {
  const first = map.items[0];
  const range = first ? rangeOf(first.key) : null;
  if (!range) return '  ';
  const column = range[0] - lineStart(text, range[0]);
  return column > 0 ? ' '.repeat(column) : '  ';
}

/** Where one entry's own lines begin and end, trailing newline included. */
function entryRange(text: string, pair: Pair<unknown, unknown>): { start: number; end: number } | null {
  const key = rangeOf(pair.key);
  if (!key) return null;
  const start = lineStart(text, key[0]);
  const value = rangeOf(pair.value);
  return { start, end: blockEnd(text, start, value ? value[1] : key[1]) };
}

function save(file: string, text: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  writeAtomic(file, text);
}

/**
 * Add `name: { from }` under `plugins:`, leaving every other byte alone.
 *
 * Three shapes, because a config in the wild has all three: no `plugins:` key
 * (append one at the end), a map with entries in it (insert after the last),
 * and a `plugins:` that is empty or `{}` (rewrite that one line into a block).
 */
export function addPluginEntry(file: string, name: string, from: string): AddOutcome {
  const text = readText(file);
  const doc = parse(file, text);
  const root = isMap(doc.contents) ? doc.contents : null;
  const pair = root ? pairOf(root, 'plugins') : null;
  const map = pair && isMap(pair.value) ? pair.value : null;

  if (map && pairOf(map, name)) return 'exists';

  let next: string;
  if (!pair || !map || map.items.length === 0) {
    const block = entryBlock(name, from, '  ');
    if (!pair) {
      // No plugins key at all. Append; a file that does not end in a newline
      // gets one, which is the only byte this branch adds outside the block.
      const head = text.length === 0 || text.endsWith('\n') ? text : `${text}\n`;
      next = `${head}plugins:\n${block}`;
    } else {
      // `plugins:` with nothing under it, or `plugins: {}`. Replace that line.
      const key = rangeOf(pair.key);
      if (!key) throw new Error(`${file}: cannot locate the plugins key`);
      const value = rangeOf(pair.value);
      const start = lineStart(text, key[0]);
      const end = blockEnd(text, start, value ? value[1] : key[1]);
      next = `${text.slice(0, start)}plugins:\n${block}${text.slice(end)}`;
    }
  } else {
    const last = map.items[map.items.length - 1];
    const where = last ? entryRange(text, last) : null;
    if (!where) throw new Error(`${file}: cannot locate the last plugins entry`);
    next = `${text.slice(0, where.end)}${entryBlock(name, from, indentOf(text, map))}${text.slice(where.end)}`;
  }

  verify(file, next, name, from);
  save(file, next);
  return 'added';
}

/**
 * Drop one entry. When it was the last one the `plugins:` line goes with it,
 * so the file comes back to the shape it had before anything was added.
 */
export function removePluginEntry(file: string, name: string): RemoveOutcome {
  const text = readText(file);
  if (!text) return 'absent';
  const doc = parse(file, text);
  const root = isMap(doc.contents) ? doc.contents : null;
  const pair = root ? pairOf(root, 'plugins') : null;
  const map = pair && isMap(pair.value) ? pair.value : null;
  const entry = map ? pairOf(map, name) : null;
  if (!pair || !map || !entry) return 'absent';

  const where = entryRange(text, entry);
  if (!where) throw new Error(`${file}: cannot locate the entry ${name}`);
  let start = where.start;
  if (map.items.length === 1) {
    const key = rangeOf(pair.key);
    if (key) start = lineStart(text, key[0]);
  }
  const next = `${text.slice(0, start)}${text.slice(where.end)}`;

  const after = parseDocument(next);
  if (after.hasIn(['plugins', name])) throw new Error(`${file}: ${name} survived the edit`);
  save(file, next);
  return 'removed';
}

/** Re-read what we are about to write. A splice bug must not reach the file. */
function verify(file: string, text: string, name: string, from: string): void {
  const doc = parseDocument(text);
  const first = doc.errors[0];
  if (first) throw new Error(`${file}: the edit would not parse (${first.message})`);
  if (doc.getIn(['plugins', name, 'from']) !== from) throw new Error(`${file}: the edit did not take`);
}
