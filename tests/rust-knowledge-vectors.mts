// Writes crates/tagents-core/tests/fixtures/knowledge-vectors.json: what the node knowledge package does for each input the Rust port of its index, search and usage store takes, which `cargo test -p tagents-core --test knowledge_doc --test knowledge_index --test knowledge_search --test knowledge_usage` checks case by case. rust.yml runs it and then `git diff --exit-code` on the file, so a node change that moves an output fails CI until the Rust copy follows.
//
// Run: node tests/rust-knowledge-vectors.mts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { corpusVectors } from './rust-knowledge-vectors/corpus.mts';
import { docVectors } from './rust-knowledge-vectors/docs.mts';
import { engineVectors } from './rust-knowledge-vectors/engine.mts';
import { processVectors } from './rust-knowledge-vectors/process.mts';
import { toolVectors } from './rust-knowledge-vectors/tools.mts';
import { cleanup } from './rust-knowledge-vectors/util.mts';
import { usageVectors } from './rust-knowledge-vectors/usage.mts';
import { yamlVectors } from './rust-knowledge-vectors/yaml.mts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'crates/tagents-core/tests/fixtures/knowledge-vectors.json');

// The output of `createT` in the node CLI depends on the locale, and the vectors are the English ones.
process.env.TAGENTS_LOCALE = 'en';

function versionOf(name: string): string {
  const manifest: unknown = JSON.parse(fs.readFileSync(path.join(root, 'packages/knowledge/node_modules', name, 'package.json'), 'utf8'));
  if (typeof manifest !== 'object' || manifest === null || !('version' in manifest) || typeof manifest.version !== 'string') throw new Error(`${name} has no version`);
  return manifest.version;
}

try {
  const engine = await engineVectors();
  const vectors = {
    generator: {
      node: process.version,
      sdk: versionOf('@modelcontextprotocol/sdk'),
      zod: versionOf('zod'),
      yaml: versionOf('yaml'),
    },
    docs: await docVectors(),
    engine,
    corpus: await corpusVectors(),
    usage: await usageVectors(),
    process: await processVectors(),
    tools: await toolVectors(),
    yaml: yamlVectors(),
  };
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${JSON.stringify(vectors, null, 2)}\n`);
} finally {
  cleanup();
}
