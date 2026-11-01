// Writes crates/tagents-core/tests/fixtures/plugin-vectors.json: what the node code behind `plugin add` and `plugin remove` gives for each input, which `cargo test -p tagents-core --test plugin_vectors` checks case by case. rust.yml runs it and then `git diff --exit-code` on the file, so a node change that moves an output fails CI until the Rust copy follows.
//
// Run: node tests/rust-plugin-vectors.mts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { configVectors } from './rust-plugin-vectors/config.mts';
import { messagesVectors } from './rust-plugin-vectors/messages.mts';
import { resolveVectors } from './rust-plugin-vectors/resolve.mts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'crates/tagents-core/tests/fixtures/plugin-vectors.json');

// The locale of the machine that regenerates the file must not decide a case that names none.
delete process.env['TAGENTS_LOCALE'];

const vectors = {
  config: configVectors(),
  resolve: resolveVectors(),
  messages: messagesVectors(),
};
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(vectors, null, 2)}\n`);
