// `tagents plugin new <name>` — the smallest package that is already a plugin.
//
// What "minimal" has to mean here: it TYPECHECKS AND RUNS as written. A
// scaffold whose first act is to fail `tsc` teaches the author that the
// contract is fiddly, when the whole point of definePlugin is that it is one
// object. So the files are the reference plugin's shape with everything
// optional taken out — one verb, one test, a tsconfig that mirrors core's (the
// same strictness the host is written under) and a README that says what to do
// next.
//
// The files are one text, spec/cli/scaffold/plugin.txt, which the Rust
// `tagents-core` compiles in and this reads at run time, so the two cannot
// write different bytes: a line `@@ <path>` starts a file and its body runs to
// the next such line. `{{name}}`, `{{dir}}` and `{{core|json}}` are replaced in
// one pass, so a value that holds `{{name}}` is written as typed.
//
// @tagents/core is depended on as `link:<relative path>`, the way the first
// real plugin depends on it: a scaffold made from a checkout points at that
// checkout and installs with no registry at all. Publishing one means swapping
// that for a version range, which the README says.
import fs from 'node:fs';
import path from 'node:path';

export interface ScaffoldFile {
  /** Relative to the package directory, with forward slashes. */
  readonly path: string;
  readonly body: string;
}

/** The core package this CLI is running out of — src/cli/… or dist/cli/…. */
export function corePackageDir(here = import.meta.dirname): string {
  return path.resolve(here, '..', '..');
}

/** A relative specifier, always with a leading `./` or `../`. */
function relativeSpecifier(from: string, to: string): string {
  const rel = path.relative(from, to).split(path.sep).join('/');
  if (!rel) return '.';
  return rel.startsWith('.') ? rel : `./${rel}`;
}

const TEMPLATE_FILE = new URL('../../../../spec/cli/scaffold/plugin.txt', import.meta.url);

interface Values {
  /** The plugin's name: a config key, so it needs no JSON escape in package.json. */
  readonly name: string;
  /** The directory the files are written to, as typed. */
  readonly dir: string;
  /** What follows `link:`: the relative specifier of core from `dir`. */
  readonly core: string;
}

const FILLERS: Record<string, (values: Values) => string> = {
  name: (v) => v.name,
  dir: (v) => v.dir,
  // The relative specifier of core, as the JSON string escape without the quotes: the one place a value lands inside a JSON string.
  'core|json': (v) => JSON.stringify(v.core).slice(1, -1),
};

/** `text` with each placeholder replaced once. A replacement is a function's result, so `$&` in a value is written as typed. */
function render(text: string, values: Values): string {
  return text.replace(/\{\{([\w|]+)\}\}/g, (whole, key: string) => FILLERS[key]?.(values) ?? whole);
}

/** Every file `plugin new` writes, in the order it writes them. */
export function scaffoldFiles(name: string, dir: string, coreDir = corePackageDir()): ScaffoldFile[] {
  const values: Values = { name, dir, core: relativeSpecifier(dir, coreDir) };
  const parts = fs.readFileSync(TEMPLATE_FILE, 'utf8').split(/^@@ (.*)\n/m).slice(1);
  const files: ScaffoldFile[] = [];
  for (let i = 0; i + 1 < parts.length; i += 2) files.push({ path: parts[i] ?? '', body: render(parts[i + 1] ?? '', values) });
  return files;
}
