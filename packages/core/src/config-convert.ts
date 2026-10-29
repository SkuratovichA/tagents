// A YAML config turned into the TOML twin that tagents reads the same way.
//
// What makes this safe is not the translation but the check after it: the converted text is handed to the real `tagents --config` (the bash dashboard's own reader) next to the YAML it came from, and the two dumps must agree. A conversion tagents would read differently is refused, never offered, so the only way to get a wrong login out of this is for tagents to read the YAML wrongly in the first place, and then it was already wrong.
//
// The types come from the YAML as it is WRITTEN, not as a YAML library resolves it: `true` and `850` stay a boolean and a number. A scalar the YAML library reads as a number or a boolean that TOML writes differently (`0x10`, `.5`, `True`) or as null (`~`) is refused with what to write instead, never turned into a string; typeMismatch below is the check that nothing was retyped, because the `--config` dumps print every value as text and cannot show it.
//
// Comments cannot be carried across (a YAML parser does not keep them in a form that maps onto TOML's), and the output says so on its second line.
//
// TOML puts a table's plain keys above its sub-tables, so a plain key written after a table in the YAML moves up. That changes the order of the dump's lines and nothing tagents reads from it; sameConfig below is the definition of "nothing it reads".
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LineCounter, isAlias, isMap, isNode, isScalar, isSeq, parseDocument, type Scalar, type YAMLMap } from 'yaml';
import { parseConfigText, tomlKey, tomlString } from './config-file.ts';
import { findOnPath } from './path-lookup.ts';

/** What `#:schema` points a TOML language server at; the schema's own `$id` is this too (test/config-schema.test.ts). */
export const CONFIG_SCHEMA_URL = 'https://raw.githubusercontent.com/SkuratovichA/tagents/main/schemas/config.schema.json';

export type Converted = { ok: true; toml: string } | { ok: false; problem: string };

export interface ConvertOptions {
  /** the `tagents` bash script to check against; by default the one in this checkout, else the first on PATH */
  tagents?: string;
  /** how long one `tagents --config` run may take before the conversion is refused; DUMP_TIMEOUT_MS by default */
  timeoutMs?: number;
}

// ------------------------------------------------------------- the model ----

/** A table as it will be written: its plain keys (already rendered as TOML values), then its sub-tables, each in file order. */
interface Table {
  plain: Array<{ key: string; value: string }>;
  sub: Array<{ key: string; table: Table } | { key: string; items: Table[] }>;
}

const emptyTable = (): Table => ({ plain: [], sub: [] });

/** A YAML construct that has no TOML twin, with the line it is on. */
class Refusal extends Error {
  readonly line: number;
  constructor(line: number, message: string) {
    super(message);
    this.line = line;
  }
}

// A number as the YAML wrote it, which is also how TOML writes one: decimal digits, an optional fraction.
const DECIMAL = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/;

function build(doc: ReturnType<typeof parseDocument>, lines: LineCounter): Table {
  const lineOf = (node: unknown): number => (isNode(node) && node.range ? lines.linePos(node.range[0]).line : 1);
  const fail = (node: unknown, why: string): never => {
    throw new Refusal(lineOf(node), why);
  };

  /** The tag and the alias checks every node of any kind goes through. */
  const plainNode = (node: unknown): void => {
    if (isAlias(node)) fail(node, `an alias (*${node.source}) has no TOML twin — write the value out where it is used`);
    if ((isScalar(node) || isMap(node) || isSeq(node)) && node.tag) {
      fail(node, `an explicit tag (${node.tag.replace(/^tag:yaml\.org,2002:/, '!!')}) has no TOML twin — write the value without it`);
    }
  };

  /** One scalar, rendered the way TOML writes the value tagents reads from the YAML. */
  const scalar = (node: Scalar): string => {
    const value = node.value;
    if (typeof value === 'string') {
      if (value.includes('\n')) fail(node, 'a value with a line break in it cannot be one line of a config');
      const written = tomlString(value);
      if (written === null) return fail(node, 'a control character (a tab included) in a value cannot be written in the TOML tagents reads');
      return written;
    }
    const written = node.source ?? '';
    const quoted = JSON.stringify(written);
    if (typeof value === 'boolean') {
      if (node.type === 'PLAIN' && (written === 'true' || written === 'false')) return written;
      return fail(node, `${written} is a boolean in YAML, which TOML writes only as true or false — write one of those, or quote it (${quoted}) to keep the text`);
    }
    if (typeof value === 'number') {
      if (node.type === 'PLAIN' && DECIMAL.test(written)) return written;
      return fail(node, `${written} is a number in YAML that TOML does not write that way — write it as a plain decimal (850, -3, 1.5), or quote it (${quoted}) to keep the text`);
    }
    return fail(node, `${written} is null in YAML, which has no TOML twin — quote it (${quoted}) to keep the text, or leave the value out`);
  };

  const keyText = (key: unknown): string => {
    if (!isScalar(key)) return fail(key, 'a key that is not plain text has no TOML twin');
    const text = typeof key.value === 'string' ? key.value : (key.source ?? '');
    return text === '' ? fail(key, 'an empty key has no TOML twin') : text;
  };

  const isEmptyValue = (node: unknown): boolean => node == null || (isScalar(node) && node.value === null && (node.source ?? '') === '');

  /** `flat`: the table is a list item, which holds plain keys only. */
  const table = (map: YAMLMap, flat: boolean): Table => {
    const out = emptyTable();
    for (const pair of map.items) {
      const key = keyText(pair.key);
      const node = pair.value;
      plainNode(node);
      if (isEmptyValue(node)) {
        if (flat) fail(pair.key, `${key} has no value, and a list item can hold only plain keys`);
        out.sub.push({ key, table: emptyTable() });
      } else if (isMap(node)) {
        if (flat) fail(node, `${key} is a mapping inside a list item, which has no TOML twin the dashboard reads — a [[table]] holds plain keys only`);
        out.sub.push({ key, table: table(node, false) });
      } else if (isSeq(node)) {
        if (flat) fail(node, `${key} is a list inside a list item, which has no TOML twin the dashboard reads — a [[table]] holds plain keys only`);
        const listed = list(node);
        if (typeof listed === 'string') out.plain.push({ key, value: listed });
        else out.sub.push({ key, items: listed });
      } else if (isScalar(node)) {
        out.plain.push({ key, value: scalar(node) });
      } else {
        fail(node, `${key}: this value has no TOML twin`);
      }
    }
    return out;
  };

  /** A list of scalars is an inline array (a string); a list of mappings is an array of tables. */
  const list = (seq: { items: unknown[] }): string | Table[] => {
    const items = seq.items;
    const maps = items.filter((item) => isMap(item));
    if (maps.length === 0) {
      return `[${items
        .map((item) => {
          plainNode(item);
          if (isEmptyValue(item)) return fail(item, 'an empty list item has no TOML twin');
          if (!isScalar(item)) return fail(item, 'a list inside a list has no TOML twin the dashboard reads');
          return scalar(item);
        })
        .join(', ')}]`;
    }
    if (maps.length !== items.length) fail(seq, 'a list that mixes scalars and mappings has no TOML twin');
    return maps.map((item) => {
      plainNode(item);
      return table(item, true);
    });
  };

  const root = doc.contents;
  if (root == null) return emptyTable();
  if (!isMap(root)) return fail(root, 'the top level must be a mapping of settings, not a list or a single value');
  plainNode(root);
  return table(root, false);
}

// ------------------------------------------------------------- the writer ---

function blocks(t: Table, at: string[], out: string[]): void {
  const lines = t.plain.map((p) => `${tomlKey(p.key)} = ${p.value}`);
  // A table that only holds other tables needs no header of its own; one with nothing in it at all is a name, and is written as one.
  if (at.length > 0 && (lines.length > 0 || t.sub.length === 0)) out.push([`[${at.map(tomlKey).join('.')}]`, ...lines].join('\n'));
  else if (at.length === 0 && lines.length > 0) out.push(lines.join('\n'));
  for (const s of t.sub) {
    const into = [...at, s.key];
    if ('table' in s) blocks(s.table, into, out);
    else {
      for (const item of s.items) {
        out.push([`[[${into.map(tomlKey).join('.')}]]`, ...item.plain.map((p) => `${tomlKey(p.key)} = ${p.value}`)].join('\n'));
      }
    }
  }
}

// ------------------------------------------------------- the check by tagents ---

/** The checkout's own `tagents` (this file is packages/core/src or dist, three levels below it), else the first one on PATH. */
function findTagents(): string | null {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const sibling = path.resolve(here, '..', '..', '..', 'tagents');
  return fs.existsSync(sibling) ? sibling : findOnPath('tagents');
}

/** One `tagents --config` run is a few milliseconds; a script that takes this long is stuck, and output this large is not a config. */
const DUMP_TIMEOUT_MS = 10_000;
const DUMP_MAX_BUFFER = 16 * 1024 * 1024;

const firstLine = (text: string): string => text.trim().split('\n')[0] ?? '';

/** What tagents itself reads out of `file`: its own `--config` dump, on a scratch HOME and tmux server and with no host overlay. */
function dumpOf(tagents: string, file: string, scratch: string, timeoutMs: number): { ok: true; dump: string } | { ok: false; why: string } {
  const r = spawnSync('/bin/bash', [tagents, '--config'], {
    encoding: 'utf8',
    timeout: timeoutMs,
    killSignal: 'SIGKILL',
    maxBuffer: DUMP_MAX_BUFFER,
    env: {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      HOME: scratch,
      TMUX_TMPDIR: scratch,
      TA_STATE_DIR: scratch,
      TA_HOST: 'no-such-host-for-the-dump',
      TA_CONFIG: file,
    },
  });
  if (r.error) {
    const code = (r.error as NodeJS.ErrnoException).code;
    if (code === 'ETIMEDOUT') return { ok: false, why: `tagents --config did not finish within ${timeoutMs / 1000} seconds` };
    if (code === 'ENOBUFS') return { ok: false, why: `tagents --config printed more than ${DUMP_MAX_BUFFER / 1024 / 1024} MiB` };
    return { ok: false, why: r.error.message };
  }
  if (r.status !== 0 || r.stderr !== '') return { ok: false, why: firstLine(r.stderr) || `exit ${r.status}` };
  return { ok: true, dump: r.stdout };
}

/**
 * Do two `--config` dumps mean the same to tagents? Every line is there in both, and every parent's children come in the same order within their kind:
 * the plain keys among themselves, the tables among themselves. A plain key and a table of one parent may swap places (TOML cannot write a plain key after a table), but two profiles may not, because the order of the profiles is the order of the account picker.
 */
export function sameConfig(a: string, b: string): boolean {
  if (a === b) return true;
  const shape = (dump: string): string => {
    const rows = dump.split('\n').filter((row) => row !== '');
    const paths = rows.map((row) => row.split('\t')[0] ?? '');
    const branches = new Set<string>();
    for (const p of paths) {
      const parts = p.split('.');
      for (let i = 1; i < parts.length; i++) branches.add(parts.slice(0, i).join('.'));
    }
    const order = new Map<string, string[]>();
    for (const p of paths) {
      const parts = p.split('.');
      for (let i = 1; i <= parts.length; i++) {
        const child = parts.slice(0, i).join('.');
        const slot = `${branches.has(child) ? 'table' : 'plain'} ${parts.slice(0, i - 1).join('.')}`;
        const seen = order.get(slot) ?? [];
        if (!seen.includes(child)) seen.push(child);
        order.set(slot, seen);
      }
    }
    return JSON.stringify([[...rows].sort(), [...order.entries()].sort(([x], [y]) => (x < y ? -1 : 1))]);
  };
  return shape(a) === shape(b);
}

/** A value as a person reads it in a message: a string quoted, anything else with its type. */
const describe = (value: unknown): string => (typeof value === 'string' ? JSON.stringify(value) : `${typeof value} ${String(value)}`);

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);

/** The check `tagents --config` cannot make, because it prints every value as text: does every string, number and boolean of the YAML come back from the TOML as the same type and the same value? Null and empty values are left out (an empty table is how TOML says them). Returns what differs, or null when nothing does. */
export function typeMismatch(yamlText: string, toml: string): string | null {
  let yamlDoc: unknown;
  let tomlDoc: unknown;
  try {
    yamlDoc = parseConfigText(yamlText, 'yaml');
    tomlDoc = parseConfigText(toml, 'toml');
  } catch (err) {
    return `the values cannot be compared: ${firstLine(err instanceof Error ? err.message : String(err))}`;
  }
  const walk = (a: unknown, b: unknown, at: string): string | null => {
    if (typeof a === 'string' || typeof a === 'number' || typeof a === 'boolean') {
      return typeof b === typeof a && b === a ? null : `${at || 'the top level'} is ${describe(a)} in the YAML and ${b === undefined ? 'not there' : describe(b)} in the TOML`;
    }
    const entries: Array<[string, unknown, unknown]> = Array.isArray(a)
      ? a.map((item, i): [string, unknown, unknown] => [`${at}[${i}]`, item, Array.isArray(b) ? b[i] : undefined])
      : isRecord(a)
        ? Object.entries(a).map(([key, item]): [string, unknown, unknown] => [at === '' ? key : `${at}.${key}`, item, isRecord(b) ? b[key] : undefined])
        : [];
    for (const [where, left, right] of entries) {
      const drift = walk(left, right, where);
      if (drift !== null) return drift;
    }
    return null;
  };
  return walk(yamlDoc, tomlDoc, '');
}

// ---------------------------------------------------------------- the call ---

const refused = (problem: string): Converted => ({ ok: false, problem });

/** `file` (a YAML config) as TOML text, or why it cannot be. Nothing is written anywhere but a scratch directory that is gone on return. */
export function convertYamlConfig(file: string, options: ConvertOptions = {}): Converted {
  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    return refused(`${file}: ${err instanceof Error ? err.message : String(err)}`);
  }

  const lines = new LineCounter();
  const doc = parseDocument(text, { lineCounter: lines });
  const bad = doc.errors[0];
  if (bad) return refused(`${file}:${bad.linePos?.[0].line ?? 1}: ${firstLine(bad.message)}`);

  const out: string[] = [];
  try {
    blocks(build(doc, lines), [], out);
  } catch (err) {
    if (err instanceof Refusal) return refused(`${file}:${err.line}: ${err.message}`);
    throw err;
  }
  const toml = `#:schema ${CONFIG_SCHEMA_URL}\n# Converted from ${path.basename(file)} by tagents config convert. Comments are not carried over.\n\n${out.join('\n\n')}${out.length ? '\n' : ''}`;

  const tagents = options.tagents ?? findTagents();
  if (tagents === null) {
    return refused('the conversion cannot be checked: there is no tagents script next to this package and none on PATH');
  }
  const timeoutMs = options.timeoutMs ?? DUMP_TIMEOUT_MS;
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'tagents-convert-'));
  try {
    const converted = path.join(scratch, 'converted.toml');
    fs.writeFileSync(converted, toml);
    const before = dumpOf(tagents, path.resolve(file), scratch, timeoutMs);
    if (!before.ok) return refused(`${file}: tagents does not read this file cleanly (${before.why}), so a conversion cannot be checked against it`);
    const after = dumpOf(tagents, converted, scratch, timeoutMs);
    if (!after.ok) return refused(`${file}: the TOML made from it is not read cleanly by tagents (${after.why}), so nothing is offered`);
    if (!sameConfig(before.dump, after.dump)) {
      return refused(`${file}: tagents would read the TOML made from it differently from the YAML, so nothing is offered — see \`tagents --config\` on both`);
    }
    const retyped = typeMismatch(text, toml);
    if (retyped !== null) return refused(`${file}: the TOML made from it would give a different value than the YAML (${retyped}), so nothing is offered`);
    return { ok: true, toml };
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

/** The TOML file beside a YAML one: config.yaml → config.toml. */
export function tomlTwin(file: string): string {
  return path.join(path.dirname(file), `${path.basename(file).replace(/\.ya?ml$/i, '')}.toml`);
}

/** The per-host overlays of a YAML config that sit beside it (config.<host>.yaml for config.yaml), in name order. */
export function yamlOverlays(base: string): string[] {
  const dir = path.dirname(base);
  const name = path.basename(base);
  const stem = name.replace(/\.ya?ml$/i, '');
  return fs
    .readdirSync(dir)
    .filter((n) => n !== name && n.startsWith(`${stem}.`) && n.endsWith('.yaml'))
    .sort()
    .map((n) => path.join(dir, n));
}
