// The YAML section of the knowledge vectors: what the `yaml` package the node index reads frontmatter with makes of each source, as a tree the Rust converter of saphyr's output is compared with.
//
// `yaml-cases.json` holds the sources; the extra cases here are the ones a reader of the converter would ask about next.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { REPO } from './util.mts';

const requireFromKnowledge = createRequire(path.join(REPO, 'packages/knowledge/package.json'));
const yaml: { parse(text: string): unknown } = requireFromKnowledge('yaml');

const FROM_FILE: unknown = JSON.parse(fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), 'yaml-cases.json'), 'utf8'));
if (!Array.isArray(FROM_FILE) || !FROM_FILE.every((c): c is string => typeof c === 'string')) throw new Error('yaml-cases.json is a list of strings');

const EXTRA: string[] = [
  '5: a\ntrue: b\nnull: c\n1.5: d',
  '__proto__: 1\nconstructor: 2',
  'a: 1\n---\nb: 2',
  '---\na: 1\n...',
  '---\na: 1\n...\n---\nb: 2\n...',
  '# only a comment',
  '---',
  '---\n...',
  '%YAML 1.2\n---\na: yes',
  '%YAML 1.1\n---\na: yes\nb: 0o17',
  'a: !!float 1\nb: !!bool true\nc: !!null ""\nd: !!str\ne: !!seq [1]\nf: !!map {g: 1}',
  'a: !!int abc',
  'a: !!bool maybe',
  'a: !!binary aGk=\nb: !!set {x}\nc: !!timestamp 2026-10-31',
  'a: 0.1e2\nb: 1E5\nc: -0\nd: 0e0\ne: -.5\nf: +.inf\ng: 12345678901234567890\nh: -9007199254740993\ni: 1e-400',
  'a: 0xFFFFFFFFFFFFFFFFFF\nb: 0o7777777777777777777777\nc: -0x10\nd: 0x',
  'a: 00\nb: 08\nc: 0.\nd: .\ne: -\nf: +\ng: 1.5e\nh: 1e+',
  'key with spaces: v\n"quoted key": v2\n\'\': v3\n? plain\n: v4',
  '"a": 1\n\'a\': 2',
  'a: 1\n? a\n: 2',
  'a: &x\n  - 1\nb: *x\nc: &y {k: *x}\nd: *y',
  'a: *undefined',
  'a: &x 1\na2: &x 2\nb: *x',
  'a: &r [*r]',
  'a: &a [1, 2]\nb: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a]\nc: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b]\nd: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c]\ne: &e [*d, *d, *d, *d, *d, *d, *d, *d, *d]\nf: [*e, *e, *e, *e, *e, *e, *e, *e, *e]',
  '<<: {a: 1}\nb: 2',
  'a: &m {x: 1}\nb: &n {y: 2}\nc:\n  <<: [*m, *n]\n  z: 3',
  'a: &m {x: 1}\nc:\n  <<: *m\n  x: 2',
  'a: {b: 1\nc: 2}',
  'a: [1, 2,]\nb: {x: 1,}\nc: [,]',
  'a: [1, [2, [3, [4]]]]',
  'a:\n- 1\n- 2\nb:\n- 3',
  'a:\n  - x\n  -\n  - y',
  '- a\n-\n- b: 1\n  c: 2',
  '? a\n? b',
  'a: |\n  one\n  two\nb: >\n  one\n  two\n\n  three\nc: |-\n  x\nd: >+\n  y\n\ne: z',
  'a: |2\n    indented\nb: |1\n x',
  'a: >\n\n  leading blank\n  text',
  'a: "line one\n  line two"\nb: \'x\n\n  y\'',
  'a: "\\t\\0\\a\\b\\e\\f\\v\\r\\N\\_\\L\\P\\ \\/\\\\\\"\\x41\\u0042\\U00000043"',
  'a: "\\ud83d\\ude00"',
  'a: "\\U0001F600"',
  'a: "\\q"',
  "a: 'it''s'\nb: ''''\nc: ''",
  'a: x # not a comment\'s end\nb: "y # kept"\nc: z#kept',
  'a: #c\n  b',
  'a:\tb',
  'title:\tRunbook',
  'a:\tb\nc:\td',
  'a:\t\tb',
  'a:\n  b:\t1\n  c:\t[x,\ty]',
  '"a":\t1\n\'b\':\t2',
  'a: {b:\t1, c:\t2}',
  'a: [b:\t1]',
  '{a:\t1}',
  'a:\t-x',
  'a:\t- x',
  'a:\tb:\tc',
  'a:\t# c\nb:\t1',
  'a: |\n  x:\ty\n  z',
  'a: "x:\ty"\nb: \'x:\ty\'',
  'a: x\ty\nb: [x\ty]',
  '?\ta\n:\tb',
  'a:\n\tb: 1',
  'ключ:\tзначение\n😀:\tb\nе\u0301:\t"q:\tr"\nd:\tж',
  'a: b\t\nc: d',
  'a:  b  \n',
  '\ufeffa: b',
  'a: b\u2028c: d',
  'a: b\u0085c: d',
  'a: \u00a0b\u00a0',
  'a:\u00a0b',
  'a: b\nc:\n  - d\n  -\u00a0e',
  'a: 😀\nb: "😀"\n😀: c',
  'a: "e\u0301"\nb: é',
  'a: x\u0000y',
  'a: "x\u0000y"',
  'a: \u007f',
  'a: \u0080',
  'a: \u0007',
  'a: ',
  'a:',
  'a',
  ':',
  ': a',
  '- ',
  '-',
  '[',
  ']',
  '{',
  '}',
  '[]',
  '{}',
  '[a, b]',
  '{a: 1}',
  '"a"',
  "'a'",
  '123',
  'true',
  'null',
  '~',
  '|\n  text',
  '>\n  text',
  '&a b',
  '*a',
  '!!str x',
  '!x',
  '@a: b',
  '`a: b',
  'a: @b',
  'a: `b',
  'a: %b',
  'a: !b',
  'a: &b',
  'a: *b',
  'a: |b',
  'a: >b',
  'a: ?b',
  'a: ? b',
  'a: - b',
  'a: -b',
  'a: [b',
  'a: b]',
  'a: {b',
  'a: b}',
  'a: "b" c',
  'a: \'b\' c',
  'a: "b"c',
  'a: b: c: d',
  'a: b\n c: d',
  'a:\n  b: 1\n c: 2',
  'a:\n b: 1\n  c: 2',
  'a:\n  - b\n - c',
  'a: 1\n  b: 2',
  'a:\n  b:\n    c:\n      d:\n        e:\n          f: deep',
  `${'['.repeat(40)}${']'.repeat(40)}`,
  'tags: [a, "b", \'c\', 1, true, null, [x], {y: z}]\nstatus: draft',
  'type: Runbook\ntitle: 7\ndescription: false\ntags: yes',
  'id: 5\ntype: 6',
  'type:\n  - a',
  'type: ""\nkind: x',
  'kind: runbook\nupdated: 2026-10-31',
  'type: X\nstale_after: 2026-11-01T00:00:00Z\ngenerated:\n  by: me\n  at: 2026-10-31T10:00:00+02:00',
  'type: X\nsources:\n  - resource: a\n    kind: file\n  - not a mapping\n  - 5',
];

type Tree =
  | { t: 'null' }
  | { t: 'bool'; v: boolean }
  | { t: 'num'; v: string }
  | { t: 'str'; v: string }
  | { t: 'seq'; v: Tree[] }
  | { t: 'map'; v: [string, Tree][] };

/** The tree of a value `yaml` produced: numbers as the text `String(n)` gives, map entries ordered by their keys' UTF-16 units. */
function tree(value: unknown): Tree {
  if (value === null || value === undefined) return { t: 'null' };
  if (typeof value === 'boolean') return { t: 'bool', v: value };
  if (typeof value === 'number') return { t: 'num', v: String(value) };
  if (typeof value === 'string') return { t: 'str', v: value };
  if (Array.isArray(value)) return { t: 'seq', v: value.map(tree) };
  if (typeof value === 'object') {
    const entries: [string, Tree][] = Object.keys(value)
      .sort()
      .map((key) => [key, tree(Reflect.get(value, key))]);
    return { t: 'map', v: entries };
  }
  throw new Error(`a value of type ${typeof value} has no tree`);
}

export interface YamlVector {
  readonly text: string;
  readonly ok?: Tree;
  readonly error?: string;
}

function vectorOf(text: string): YamlVector {
  try {
    return { text, ok: tree(yaml.parse(text)) };
  } catch (e) {
    return { text, error: (e instanceof Error ? e.message : String(e)).split('\n')[0] ?? '' };
  }
}

/** A string a JavaScript program holds can contain half of a surrogate pair; Rust and JSON text cannot, so no case has one. */
function assertWellFormed(text: string): void {
  if (!text.isWellFormed()) throw new Error(`a YAML case with a lone surrogate: ${JSON.stringify(text)}`);
}

export function yamlVectors(): YamlVector[] {
  // `yaml` writes a warning for an unresolved tag or a key written twice with a merge; the cases stay in the vectors and the generator's output stays clean.
  const emit = process.emitWarning;
  process.emitWarning = () => undefined;
  const warn = console.warn;
  console.warn = () => undefined;
  try {
    const sources = [...FROM_FILE, ...EXTRA];
    sources.forEach(assertWellFormed);
    const vectors = sources.map(vectorOf);
    for (const v of vectors) if (v.ok !== undefined && !JSON.stringify(v.ok).includes('\\ud')) continue; else if (v.ok !== undefined) throw new Error(`a result with a lone surrogate for ${JSON.stringify(v.text)}`);
    return vectors;
  } finally {
    process.emitWarning = emit;
    console.warn = warn;
  }
}
