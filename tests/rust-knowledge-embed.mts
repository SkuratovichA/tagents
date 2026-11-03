// Writes crates/tagents-core/src/knowledge/tools.json and texts.json: the two files of the node knowledge program that the Rust binary embeds, the `tools/list` of its MCP server and the two sentences `serve` prints (`badIdle` and `serveFailed`) in each language. rust.yml runs it and then `git diff --exit-code` on the directory, and packages/knowledge/test/embedded.test.ts compares the same two files with the node program, so a tool description, a tool or a text that moves fails until the files follow.
//
// Run: node tests/rust-knowledge-embed.mts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { en } from '../packages/knowledge/src/i18n/en.ts';
import { ru } from '../packages/knowledge/src/i18n/ru.ts';
import { connect, isRecord, REPO } from './rust-knowledge-vectors/util.mts';

const out = path.join(REPO, 'crates/tagents-core/src/knowledge');

/** The entries of `tools/list` as the node server writes them, in its order and with its keys in its order. */
async function toolList(): Promise<unknown[]> {
  const conn = await connect({});
  try {
    const response = await conn.request('tools/list');
    const tools = isRecord(response?.result) ? response.result['tools'] : undefined;
    if (!Array.isArray(tools)) throw new Error(`tools/list did not answer a list: ${JSON.stringify(response)}`);
    return tools;
  } finally {
    await conn.close();
  }
}

const texts = {
  en: { badIdle: en.badIdle, serveFailed: en.serveFailed },
  ru: { badIdle: ru.badIdle, serveFailed: ru.serveFailed },
};

const write = (name: string, value: unknown): void => fs.writeFileSync(path.join(out, name), `${JSON.stringify(value, null, 2)}\n`);

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  fs.mkdirSync(out, { recursive: true });
  write('tools.json', await toolList());
  write('texts.json', texts);
}
