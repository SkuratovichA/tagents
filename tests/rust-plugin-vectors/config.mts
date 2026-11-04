// The config section of the plugin vectors: what node's `addPluginEntry` and `removePluginEntry` do to each document of the corpus, and what `tomlString` and `tomlKey` write.
//
// Each case runs in a directory of its own, so the error texts carry a path that is written `<dir>` here. `threw` marks a case in which node threw: the Rust verbs must fail as well, and write nothing.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { tomlKey, tomlString } from '../../packages/core/src/config-file.ts';
import { addPluginEntry, removePluginEntry } from '../../packages/core/src/plugin-config.ts';
import { type Document, bytesOf, documents } from './corpus.mts';

interface ConfigCase {
  /** The corpus document the file holds, or null for no file at all (and no directory above it). */
  readonly document: string | null;
  readonly verb: 'add' | 'remove';
  readonly key: string;
  readonly from?: string;
  /** What node answered, or `error` when it threw. */
  readonly outcome: 'added' | 'exists' | 'removed' | 'absent' | 'error';
  /** The error's message, with the scratch directory written `<dir>`. */
  readonly error?: string;
  /** The file's text after the call, when it was written. */
  readonly text?: string;
  readonly threw: boolean;
}

const ADD_KEYS = ['new', 'x', 'a.b'];
const REMOVE_KEYS = ['x', 'y', 'a.b', 'nothing', '__proto__'];

/** What `from` can be, which `tomlString` has to escape or refuse. */
const FROMS = [
  '/p/new',
  '/p/with "quote"',
  '/p/back\\slash',
  'C:\\Users\\x',
  "/p/it's",
  '/p/\u00e9\u{1F600}',
  '/p/\u2028line-separator',
  '',
  '/p/tab\tchar',
  '/p/new\nline',
  '/p/del\u007fchar',
  '/p/nul\u0000char',
];
const FROM_DOCUMENTS = ['empty', 'no-final-newline-plain', 'last-entry-after-add'];

const STRINGS = ['', 'abc', 'a"b', 'a\\b', 'a\tb', 'a\u007fb', 'a\u0000b', 'a\nb', 'a b', '\u00e9', '\u{1F600}', '\u2028', 'a.b', 'A_b-c', '0', '-', '_', 'a/b', "it's", '\\"', '"'];

function run(doc: Document | null, verb: 'add' | 'remove', key: string, from: string): ConfigCase {
  const dir = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'plugin-vectors-config-'));
  const file = doc === null ? path.join(dir, 'sub', 'config.toml') : path.join(dir, 'config.toml');
  if (doc !== null) fs.writeFileSync(file, bytesOf(doc));
  const base = { document: doc?.name ?? null, verb, key, ...(verb === 'add' ? { from } : {}) };
  try {
    const outcome = verb === 'add' ? addPluginEntry(file, key, from) : removePluginEntry(file, key);
    const written = outcome === 'added' || outcome === 'removed';
    return { ...base, outcome, ...(written ? { text: fs.readFileSync(file, 'utf8') } : {}), threw: false };
  } catch (e) {
    const error = (e instanceof Error ? e.message : String(e)).split(dir).join('<dir>');
    return { ...base, outcome: 'error', error, threw: true };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

export function configVectors(): unknown {
  const cases: ConfigCase[] = [];
  for (const doc of [null, ...documents]) {
    for (const key of ADD_KEYS) cases.push(run(doc, 'add', key, `/p/${key}`));
    for (const key of REMOVE_KEYS) cases.push(run(doc, 'remove', key, ''));
  }
  for (const name of FROM_DOCUMENTS) {
    const doc = documents.find((d) => d.name === name) ?? null;
    for (const from of FROMS) cases.push(run(doc, 'add', 'fresh', from));
  }
  return {
    documents: documents.map(({ name, text, hex }) => ({ name, ...(text === undefined ? {} : { text }), ...(hex === undefined ? {} : { hex }) })),
    cases,
    strings: STRINGS.map((value) => ({ value, string: tomlString(value), key: tomlKey(value) })),
  };
}
