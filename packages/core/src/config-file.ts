// Which file is the config, and how to read it.
//
// TOML is the format; YAML is the fallback for a config.yaml written before
// there was a TOML reader. The extension says which parser a file gets, so a
// TOML base can carry a YAML overlay (or the other way round) and each is read
// by its own parser. What comes back is UNCHECKED: callers hold the zod schema
// of the part they read, and this module knows none of them.
//
// The bash dashboard resolves the same files by the same rules in
// lib/tagents/config.sh (cfg_resolve); tests/config-toml.sh pins the bash side,
// and test/config-convert.test.ts reads one config through both readers.
import fs from 'node:fs';
import path from 'node:path';
import { parse as parseToml } from 'smol-toml';
import { parse as parseYaml } from 'yaml';

export type ConfigFormat = 'toml' | 'yaml';

export const TOML_BASENAME = 'config.toml';
export const YAML_BASENAME = 'config.yaml';

/** A name ending in `.toml`, case-sensitively, is TOML; anything else is YAML, which is what every config was before. The dashboard's `*.toml)` pattern is this rule (tests/fixtures/config-formats.tsv). */
export function configFormat(file: string): ConfigFormat {
  return file.endsWith('.toml') ? 'toml' : 'yaml';
}

/**
 * The config in `dir`: config.toml when there is one, else config.yaml, else
 * config.toml, the place a new one goes. A directory is not a config.
 */
export function resolveConfigFile(dir: string): string {
  const toml = path.join(dir, TOML_BASENAME);
  if (isFile(toml)) return toml;
  const yaml = path.join(dir, YAML_BASENAME);
  return isFile(yaml) ? yaml : toml;
}

/** Is there a regular file at `file`? A directory of that name is not a config. */
export function isFile(file: string): boolean {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

const BARE_KEY = /^[A-Za-z0-9_-]+$/;

/** A TOML key as written: bare when it can be, a quoted string (JSON's escapes are all valid in one) when not. */
export const tomlKey = (name: string): string => (BARE_KEY.test(name) ? name : JSON.stringify(name));

// A character the dashboard's awk reader cannot take back out of a string: it knows only the escapes \" and \\, and prints a tab as the column break of its own output.
const UNWRITABLE = /[\u0000-\u001f\u007f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;

/** `value` as a TOML basic string that the dashboard reads back unchanged, or null when it cannot be written so (a control character, a lone surrogate). */
export function tomlString(value: string): string | null {
  if (UNWRITABLE.test(value)) return null;
  return `"${value.replace(/[\\"]/g, '\\$&')}"`;
}

/** The text parsed by its format's parser. An empty document is an empty object. Throws the parser's error. */
export function parseConfigText(text: string, format: ConfigFormat): unknown {
  return format === 'toml' ? parseToml(text) : (parseYaml(text) ?? {});
}

// What a person is told about the files, once per file per process: the TS
// readers run in every CLI call and in long-lived services, and a line per read
// is noise nobody reads twice.
const told = new Set<string>();

function tellOnce(file: string, message: string): void {
  const key = `${file}\n${message}`;
  if (told.has(key)) return;
  told.add(key);
  process.stderr.write(`tagents: ${message}\n`);
}

/** What is wrong with the file's FORMAT, if anything: the YAML one is deprecated, a config.yaml next to a config.toml is ignored. */
export function formatNotice(file: string): string | null {
  if (configFormat(file) === 'yaml') {
    return `${file} is a YAML config, which is deprecated — run: tagents config convert`;
  }
  const sibling = path.join(path.dirname(file), YAML_BASENAME);
  if (path.basename(file) === TOML_BASENAME && isFile(sibling)) {
    return `${file}: ${YAML_BASENAME} is also there — ${TOML_BASENAME} is read and ${YAML_BASENAME} is ignored; delete ${YAML_BASENAME} once ${TOML_BASENAME} is right`;
  }
  return null;
}

/** Say on stderr, once per process, what is wrong with the file's format. */
export function noticeFormat(file: string): void {
  const notice = formatNotice(file);
  if (notice !== null) tellOnce(file, notice);
}

/** Read and parse one file by its extension, saying nothing. Throws when it cannot be read or does not parse. */
export function parseConfigFile(file: string): unknown {
  return parseConfigText(fs.readFileSync(file, 'utf8'), configFormat(file));
}

/**
 * Read and parse the config itself (not a plugin's options file, which has no
 * `tagents config convert` to point at), noticing its format once it read.
 */
export function readConfigFile(file: string): unknown {
  const doc = parseConfigFile(file);
  noticeFormat(file);
  return doc;
}
