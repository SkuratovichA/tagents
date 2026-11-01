// node packages/core/src/i18n/export.ts [--check]
//
// Writes spec/cli/messages.json: the two catalogues of the CLI's human strings in one file, which the Rust binary reads (crates/tagents-spec) so that it prints the same lines as this CLI and no text is typed twice. With --check it writes nothing and exits 1 when the file is not what the catalogues give.
//
// The Rust side interpolates `{{name}}` and nothing else of i18next, so a text that uses more (nesting, a format, an unescaped variable) is refused here, where the mistake is made, and not left to print wrong in a binary nobody tests that text in.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { en } from './en.ts';
import { ru } from './ru.ts';

const FILE = fileURLToPath(new URL('../../../../spec/cli/messages.json', import.meta.url));

/** What i18next treats as a variable: the shortest text between `{{` and `}}`. */
const VARIABLE = /\{\{(.+?)\}\}/g;
const PLAIN_NAME = /^[A-Za-z0-9_]+$/;

/** Why `text` is more than literal text and `{{name}}`, or null when it is not. */
export function unsupported(text: string): string | null {
  if (text.includes('$t(')) return 'it nests another key with $t(';
  for (const [whole, inner] of text.matchAll(VARIABLE)) {
    if (!PLAIN_NAME.test(inner ?? '')) return `${whole} is not a plain {{name}}`;
  }
  return null;
}

/** The file's text. Throws, naming the key, for a value that is not a string or that `unsupported` refuses. */
export function messagesText(catalogues: Record<string, Readonly<Record<string, unknown>>> = { en, ru }): string {
  for (const [locale, table] of Object.entries(catalogues)) {
    for (const [key, text] of Object.entries(table)) {
      if (typeof text !== 'string') throw new Error(`${locale}.${key} is not a string`);
      const why = unsupported(text);
      if (why !== null) throw new Error(`${locale}.${key} cannot be exported to Rust: ${why}`);
    }
  }
  return `${JSON.stringify(catalogues, null, 2)}\n`;
}

if (import.meta.main) {
  const want = messagesText();
  const check = process.argv.includes('--check');
  const have = fs.existsSync(FILE) ? fs.readFileSync(FILE, 'utf8') : null;
  if (check) {
    if (have === want) process.stdout.write('spec/cli/messages.json is fresh\n');
    else {
      process.stderr.write('spec/cli/messages.json is stale: run pnpm messages:gen\n');
      process.exitCode = 1;
    }
  } else {
    if (have !== want) fs.writeFileSync(FILE, want);
    process.stdout.write(have === want ? 'spec/cli/messages.json is fresh\n' : 'wrote spec/cli/messages.json\n');
  }
}
