// Where the config is, and how to read it: config.toml, and nothing else.
//
// What comes back is UNCHECKED: callers hold the zod schema of the part they read, and this module knows none of them.
//
// The bash dashboard reads the same file in lib/tagents/config.sh (cfg_parse_toml); tests/config-toml.sh pins the bash side, and test/config-schema.test.ts keeps the schema, the keys the dashboard reads and the zod schemas of the TypeScript readers from drifting apart.
import fs from 'node:fs';
import { parse as parseToml } from 'smol-toml';

/** Is there a regular file at `file`? A directory of that name is not a config. */
export function isFile(file: string): boolean {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

// A character the dashboard's awk reader cannot take back out of a string: it knows only the escapes \" and \\, and prints a tab as the column break of its own output.
const UNWRITABLE = /[\u0000-\u001f\u007f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;

/** `value` as a TOML basic string that the dashboard reads back unchanged, or null when it cannot be written so (a control character, a lone surrogate). */
export function tomlString(value: string): string | null {
  if (UNWRITABLE.test(value)) return null;
  return `"${value.replace(/[\\"]/g, '\\$&')}"`;
}

const BARE_KEY = /^[A-Za-z0-9_-]+$/;

/** A TOML key as written: bare when it can be, the one string writer's quoted form when not, or null when it cannot be written (a control character, a lone surrogate). */
export const tomlKey = (name: string): string | null => (BARE_KEY.test(name) ? name : tomlString(name));

/** The TOML text parsed. Throws the parser's error. */
export function parseConfigText(text: string): unknown {
  return parseToml(text);
}

/** Read and parse one TOML file. Throws when it cannot be read or does not parse. */
export function parseConfigFile(file: string): unknown {
  return parseConfigText(fs.readFileSync(file, 'utf8'));
}
