// schemas/config.schema.json is what an editor reads to check config.toml and to show what a key means. Nothing in tagents reads it, so nothing would notice if it drifted from the readers: this file is the thing that notices. It pins the schema from four sides.
//   * the schema is itself valid, and says what every key is (description, examples);
//   * the shipped examples (config.example.toml, the YAML twin the converter
//     takes) and the converter's output validate, and wrong documents do not;
//   * every key the bash dashboard reads is in the schema, and every key in the
//     schema is read by it or by the TypeScript half (zod, below);
//   * the zod schemas of the TypeScript readers describe the same keys.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import AjvModule from 'ajv/dist/2020.js';
import { parse as parseToml } from 'smol-toml';
import { parse as parseYaml } from 'yaml';
import { z } from 'zod';
import { CONFIG_SCHEMA_URL, convertYamlConfig } from '../src/config-convert.ts';
import { ConfigSchema } from '../src/host.ts';
import { findOnPath } from '../src/path-lookup.ts';
import { HERE } from './helpers.ts';

const REPO = path.resolve(HERE, '..', '..', '..');
const SCHEMA_FILE = path.join(REPO, 'schemas', 'config.schema.json');
const EXAMPLE_TOML = path.join(REPO, 'config.example.toml');
const EXAMPLE_YAML = path.join(REPO, 'tests', 'fixtures', 'config.example.yaml');

// ------------------------------------------------------------ the schema ----

/** The slice of a JSON Schema node this file walks. Everything else a node carries is the validator's business. */
interface Node {
  $ref?: string | undefined;
  description?: string | undefined;
  examples?: unknown[] | undefined;
  properties?: Record<string, Node> | undefined;
  additionalProperties?: boolean | Node | undefined;
  items?: Node | undefined;
  oneOf?: Node[] | undefined;
  required?: string[] | undefined;
}
const NodeSchema: z.ZodType<Node> = z.lazy(() =>
  z.looseObject({
    $ref: z.string().optional(),
    description: z.string().optional(),
    examples: z.array(z.unknown()).optional(),
    properties: z.record(z.string(), NodeSchema).optional(),
    additionalProperties: z.union([z.boolean(), NodeSchema]).optional(),
    items: NodeSchema.optional(),
    oneOf: z.array(NodeSchema).optional(),
    required: z.array(z.string()).optional(),
  })
);
const FileSchema = z.looseObject({ $id: z.string(), $defs: z.record(z.string(), NodeSchema) });

const raw = z.record(z.string(), z.unknown()).parse(JSON.parse(fs.readFileSync(SCHEMA_FILE, 'utf8')));
const schema = NodeSchema.parse(raw);
const { $id, $defs } = FileSchema.parse(raw);

const Ajv2020 = AjvModule.default;
const validate = new Ajv2020({ strict: true, allErrors: true }).compile(raw);

/** `$ref: "#/$defs/x"` replaced by the node it names, the referring node's own words on top. */
function resolve(node: Node): Node {
  if (node.$ref === undefined) return node;
  const target = $defs[node.$ref.replace('#/$defs/', '')];
  assert.ok(target, `${node.$ref} names no definition`);
  const { $ref: _ref, ...own } = node;
  return { ...target, ...own };
}

interface Entry {
  /** dotted path, `*` for a map's key or a list's index */
  path: string;
  /** the node as written next to its name, before a $ref is followed */
  written: Node;
  /** true for a real key, false for the `*` of a map or a list */
  named: boolean;
}

function walk(node: Node, prefix: string, out: Entry[]): void {
  const here = resolve(node);
  for (const [name, child] of Object.entries(here.properties ?? {})) {
    const p = prefix === '' ? name : `${prefix}.${name}`;
    out.push({ path: p, written: child, named: true });
    walk(child, p, out);
  }
  const more = here.additionalProperties;
  if (typeof more === 'object') {
    out.push({ path: `${prefix}.*`, written: more, named: false });
    walk(more, `${prefix}.*`, out);
  }
  if (here.items) {
    out.push({ path: `${prefix}.*`, written: here.items, named: false });
    walk(here.items, `${prefix}.*`, out);
  }
  // `args` is a string or a list of strings: the list's items are keys of the dump too (claude.args.0)
  for (const alt of here.oneOf ?? []) if (alt.items) out.push({ path: `${prefix}.*`, written: alt.items, named: false });
}

const entries: Entry[] = [];
walk(schema, '', entries);
const leaves = entries.filter((e) => !entries.some((o) => o.path.startsWith(`${e.path}.`)));

test('the schema is a valid draft 2020-12 document whose $id is the URL config.example.toml points at', () => {
  assert.equal($id, CONFIG_SCHEMA_URL);
  assert.equal(fs.readFileSync(EXAMPLE_TOML, 'utf8').split('\n')[0], `#:schema ${$id}`);
});

test('every key says what it is: a description and at least one example', () => {
  const bare = entries.filter((e) => e.named && (!e.written.description?.trim() || !e.written.examples?.length));
  assert.deepEqual(bare.map((e) => e.path), []);
});

// ------------------------------------------------------------- documents ----

const example = (): unknown => parseToml(fs.readFileSync(EXAMPLE_TOML, 'utf8'));
const plain = (value: unknown): unknown => JSON.parse(JSON.stringify(value));
const ok = (doc: unknown): string => (validate(plain(doc)) ? '' : JSON.stringify(validate.errors));

test('config.example.toml validates', () => {
  assert.equal(ok(example()), '');
});

test('the YAML example the converter takes validates once its empty values are empty tables', () => {
  const yaml: unknown = parseYaml(fs.readFileSync(EXAMPLE_YAML, 'utf8'));
  assert.equal(ok(JSON.parse(JSON.stringify(yaml), (_k, v: unknown) => (v === null ? {} : v))), '');
});

test('what the converter makes of the YAML example validates', () => {
  const result = convertYamlConfig(EXAMPLE_YAML);
  assert.ok(result.ok, result.ok ? '' : result.problem);
  assert.equal(ok(parseToml(result.toml)), '');
});

test('a document with a mistake in it does not', () => {
  const mistakes: Record<string, unknown> = {
    'a misspelt key': { usage: { monthly_limit: 850 } },
    'a string where a boolean goes': { usage: { workdays: 'yes' } },
    'a number as text': { usage: { monthly_limit_usd: '850' } },
    'a margin over 100': { usage: { safety_margin_pct: 150 } },
    'a notes.send nobody reads': { notes: { send: 'whisper' } },
    'a rule with no profile': { claude: { rules: [{ dir: '~/git' }] } },
    'a badge of three characters': { claude: { profiles: { work: { badge: 'abc' } } } },
    'a meter in the wrong shape': { usage: { meter: 'yesterday' } },
    'a plugin with no from': { plugins: { demo: {} } },
    'a key with a number for a name': { keys: { closed: 5 } },
    'a table nobody reads': { colours: { fg: 'red' } },
  };
  for (const [what, doc] of Object.entries(mistakes)) assert.notEqual(ok(doc), '', what);
});

test('a document with only the optional parts left out validates', () => {
  assert.equal(ok({}), '');
  assert.equal(ok({ claude: { profiles: { work: {} } } }), '');
  assert.equal(ok({ claude: { args: ['--model', 'opus 4'] } }), '');
});

// ----------------------------------------------------------- the dashboard ---

const ROOTS = ['claude', 'usage', 'notes', 'resurrect', 'keys', 'plugins', 'knowledge'];
const read = (...parts: string[]): string => fs.readFileSync(path.join(REPO, ...parts), 'utf8');

/** `claude.profiles.$prof.env.$k` as `claude.profiles.*.env.*`: a variable, a number and a wildcard are one segment kind. */
const normalise = (p: string): string =>
  p
    .replace(/\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/g, '*')
    .split('.')
    .map((seg) => (/^[0-9]+$/.test(seg) ? '*' : seg))
    .join('.');

/** Every key path the bash side names: its cfg_get / cfg_children calls, the cases of cfg_check, tnotes' own lookup, the key table. */
function bashPaths(): Set<string> {
  const files = [
    ...fs.readdirSync(path.join(REPO, 'lib', 'tagents')).filter((f) => f.endsWith('.sh')).map((f) => path.join('lib', 'tagents', f)),
    'tagents',
    'tnotes',
    'tusage',
  ];
  const found = new Set<string>();
  const add = (p: string): void => {
    if (ROOTS.includes(p.split('.')[0] ?? '')) found.add(normalise(p));
  };
  for (const f of files) {
    for (const m of read(f).matchAll(/\bcfg_(?:get|children)\s+"?([A-Za-z0-9_.${}]+)"?/g)) add(m[1] ?? '');
  }
  const check = read('lib', 'tagents', 'config.sh').split(/^cfg_check\(\) \{/m)[1]?.split(/^\}/m)[0] ?? '';
  for (const m of check.matchAll(/^ {6}([a-z_.|]+)\)/gm)) for (const label of (m[1] ?? '').split('|')) add(label);
  for (const m of read('tnotes').matchAll(/\$1 == "([a-z_.]+)"/g)) add(m[1] ?? '');
  const table = read('lib', 'tagents', 'keys.sh').match(/^KEY_DEFAULTS="([^"]*)"/m)?.[1] ?? '';
  for (const row of table.split('\n')) if (row.trim()) add(`keys.${row.split(' ')[0]}`);
  return found;
}

/** Do two normalised paths name the same thing, a `*` standing for any one segment on either side? */
const matches = (a: string, b: string): boolean => {
  const x = a.split('.');
  const y = b.split('.');
  return x.length === y.length && x.every((seg, i) => seg === '*' || y[i] === '*' || seg === y[i]);
};

// Read by the TypeScript half, which the zod test below holds to the schema; the bash dashboard never looks at them.
const TYPESCRIPT_ONLY = ['plugins.*.from', 'knowledge.dir'];

test('the scan of the bash side finds the keys it should', () => {
  const found = [...bashPaths()];
  for (const expected of ['claude.rules.*.dir', 'claude.profiles.*.env.*', 'usage.meter', 'notes.send', 'keys.quit', 'resurrect.every', 'claude.args.*']) {
    assert.ok(found.includes(expected), `${expected} not found in ${found.join(' ')}`);
  }
});

test('every key the dashboard reads is in the schema', () => {
  // a table the dashboard only lists (cfg_children claude.profiles) is a key of the schema as well as its leaves
  const known = entries.map((e) => e.path);
  const missing = [...bashPaths()].filter((p) => !known.some((k) => matches(k, p)));
  assert.deepEqual(missing, []);
});

test('every key in the schema is read by the dashboard or by the TypeScript half', () => {
  const read = [...bashPaths()];
  const unread = leaves.map((e) => e.path).filter((k) => !TYPESCRIPT_ONLY.includes(k) && !read.some((p) => matches(k, p)));
  assert.deepEqual(unread, []);
});

// ------------------------------------------------------------- TypeScript ---

/** What z.toJSONSchema says of the part of the config the plugin host reads. */
const HostJson = z.looseObject({
  properties: z.looseObject({
    plugins: z.looseObject({
      additionalProperties: z.looseObject({ properties: z.record(z.string(), z.unknown()), required: z.array(z.string()) }),
    }),
  }),
});

test('the plugin entry the host reads is the one the schema describes', () => {
  const read = HostJson.parse(z.toJSONSchema(ConfigSchema, { io: 'input' })).properties.plugins.additionalProperties;
  const more = schema.properties?.['plugins']?.additionalProperties;
  assert.ok(typeof more === 'object', 'plugins has an entry per plugin name');
  const written = resolve(more);
  assert.deepEqual(Object.keys(written.properties ?? {}).sort(), Object.keys(read.properties).sort());
  assert.deepEqual([...(written.required ?? [])].sort(), [...read.required].sort());
});

// -------------------------------------------------------------- the editor ---

const taplo = findOnPath('taplo');
const SKIP_TAPLO = 'taplo is not installed (brew install taplo); this lint was not run';

/** `taplo lint` of a TOML text against the schema file, offline: the #:schema URL would be fetched from GitHub. */
function lint(toml: string): { code: number | null; out: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tagents-taplo-'));
  try {
    const file = path.join(dir, 'config.toml');
    fs.writeFileSync(file, toml);
    const r = spawnSync(taplo ?? 'taplo', ['lint', '--no-auto-config', '--colors', 'never', '--schema', `file://${SCHEMA_FILE}`, file], {
      encoding: 'utf8',
      env: { PATH: process.env['PATH'] ?? '', HOME: dir },
    });
    return { code: r.status, out: `${r.stdout}${r.stderr}` };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('taplo lints config.example.toml clean against the schema', { skip: taplo === null ? SKIP_TAPLO : false }, () => {
  const r = lint(fs.readFileSync(EXAMPLE_TOML, 'utf8'));
  assert.equal(r.code, 0, r.out);
});

test('taplo applies the schema: a mistake in a config is an error', { skip: taplo === null ? SKIP_TAPLO : false }, () => {
  const r = lint('[usage]\nworkdays = "yes"\n');
  assert.notEqual(r.code, 0);
  assert.match(r.out, /not of type "boolean"/);
});
