// Writes crates/tagents-core/tests/fixtures/session-vectors.json: what the node code behind `tagents-core session` gives for each input, which `cargo test -p tagents-core --test session_vectors` checks case by case. rust.yml runs it and then `git diff --exit-code` on the file, so a node change that moves an output fails CI until the Rust copy follows.
//
// The file holds no string that a JSON parser would have to read as a lone surrogate: a case that needs one carries the six characters of its escape, and the answers node gave are the texts `JSON.stringify` wrote. The signal names of `os.constants.signals` are not here, because their numbers are those of the machine that writes the file; the Rust table is pinned against `libc` where it is written.
//
// Run: node tests/rust-session-vectors.mts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { argsVectors, envVectors } from './rust-session-vectors/child.mts';
import { decodeVectors } from './rust-session-vectors/decode.mts';
import { outcomeVectors } from './rust-session-vectors/outcome.mts';
import { printVectors } from './rust-session-vectors/print.mts';
import { referenceVectors } from './rust-session-vectors/reference.mts';
import { streamVectors } from './rust-session-vectors/stream.mts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'crates/tagents-core/tests/fixtures/session-vectors.json');

// The locale of the machine that regenerates the file must not decide a case that names none.
delete process.env['TAGENTS_LOCALE'];

const vectors = {
  print: printVectors(),
  decode: decodeVectors(),
  reference: referenceVectors(),
  args: argsVectors(),
  env: envVectors(),
  stream: streamVectors(),
  outcome: outcomeVectors(),
};

/** Whether any string of the tree, key or value, holds half of a surrogate pair: `serde_json` refuses to read the file then. */
function malformed(value: unknown): boolean {
  if (typeof value === 'string') return !value.isWellFormed();
  if (Array.isArray(value)) return value.some(malformed);
  if (value !== null && typeof value === 'object') return Object.entries(value).some(([k, v]) => !k.isWellFormed() || malformed(v));
  return false;
}
if (malformed(vectors)) throw new Error('a vector holds a lone surrogate; write it as an escape inside a text');

fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(vectors, null, 2)}\n`);
