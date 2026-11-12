// Writes the corpus or the package tree of the plugin vectors to a directory, for the shell suite that compares the two programs on them.
//
// Run: node tests/rust-plugin-parity/materialise.mts corpus <dir>   one file `<name>.toml` for each document
//      node tests/rust-plugin-parity/materialise.mts tree <dir>     the packages of tree.mts
import fs from 'node:fs';
import path from 'node:path';
import { bytesOf, documents } from './corpus.mts';
import { materialise } from './tree.mts';

const [what, dir] = process.argv.slice(2);
if ((what !== 'corpus' && what !== 'tree') || dir === undefined) {
  process.stderr.write('usage: materialise.mts corpus|tree <dir>\n');
  process.exit(2);
}
fs.mkdirSync(dir, { recursive: true });
if (what === 'tree') materialise(dir);
else for (const doc of documents) fs.writeFileSync(path.join(dir, `${doc.name}.toml`), bytesOf(doc));
