// Writes crates/tagents-core/tests/fixtures/notify-vectors.json: what the node functions the Rust notify daemon ports give for each input, which `cargo test -p tagents-core --test notify_vectors` checks case by case. rust.yml runs it and then `git diff --exit-code` on the file, so a node change that moves an output fails CI until the Rust copy follows.
//
// Run: node tests/rust-notify-vectors.mts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { feedVectors } from './rust-notify-vectors/feed.mts';
import { optionsVectors } from './rust-notify-vectors/options.mts';
import { wordsVectors } from './rust-notify-vectors/words.mts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'crates/tagents-core/tests/fixtures/notify-vectors.json');

const vectors = {
  options: await optionsVectors(),
  feed: await feedVectors(),
  words: await wordsVectors(),
};
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(vectors, null, 2)}\n`);
