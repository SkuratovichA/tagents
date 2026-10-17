// What the plugin ships, as one digest, and the version move the digest implies.
//
// A pinned plugin version only reaches an installed copy when it changes, so the bump follows from the content: minor when the structure of the contract moved (a verb, a flag, a tool, a schema, an API report), patch when only wording or the skill text did.
import { isDeepStrictEqual } from 'node:util';
import { sha256 } from './hash.ts';
import { byCodeUnit } from './order.ts';
import { isJsonArray, isJsonObject, parseJson, type JsonValue } from './json.ts';
import type { Translate } from './i18n/index.ts';

export interface PayloadFile {
  /** relative to the repo root, POSIX separators */
  readonly path: string;
  readonly content: string | Uint8Array;
}

/** `sha256:<hex>` over the (path, content hash) pairs, sorted by code unit so no locale takes part. */
export function digestOf(files: readonly PayloadFile[]): string {
  const pairs = files
    .map((f) => [f.path, sha256(f.content)] as const)
    .sort(([a], [b]) => byCodeUnit(a, b));
  return `sha256:${sha256(JSON.stringify(pairs))}`;
}

const PROSE = new Set(['summary', 'description']);

/** The contract with every `summary` and `description` string removed at any depth: what is left is what a caller can break on. */
export function structureOf(value: JsonValue): JsonValue {
  if (isJsonArray(value)) return value.map(structureOf);
  if (!isJsonObject(value)) return value;
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key, v]) => !(PROSE.has(key) && typeof v === 'string'))
      .map(([key, v]) => [key, structureOf(v)])
  );
}

/** True when the contract on disk (its text, or undefined when there is none) differs structurally from the new one. */
export function structureChanged(onDisk: string | undefined, next: JsonValue): boolean {
  if (onDisk === undefined) return true;
  let previous: JsonValue;
  try {
    previous = parseJson(onDisk);
  } catch {
    return true;
  }
  return !isDeepStrictEqual(structureOf(previous), structureOf(next));
}

export function bumpVersion(version: string, kind: 'minor' | 'patch', t: Translate): string {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (match === null) throw new Error(t('badVersion', { version }));
  const [major, minor, patch] = [Number(match[1]), Number(match[2]), Number(match[3])];
  return kind === 'minor' ? `${major}.${minor + 1}.0` : `${major}.${minor}.${patch + 1}`;
}

export type VersionMove = 'first' | 'same' | 'patch' | 'minor';

export interface VersionInput {
  readonly version: string;
  /** `metadata.digest` of plugin.json, when it has one */
  readonly storedDigest: string | undefined;
  readonly digest: string;
  /** the text of contract.json on disk, when the file exists */
  readonly contractOnDisk: string | undefined;
  readonly contract: JsonValue;
}

export interface VersionDecision {
  readonly move: VersionMove;
  readonly version: string;
}

export function decideVersion(input: VersionInput, t: Translate): VersionDecision {
  if (input.storedDigest === undefined) return { move: 'first', version: input.version };
  if (input.storedDigest === input.digest) return { move: 'same', version: input.version };
  const move = structureChanged(input.contractOnDisk, input.contract) ? 'minor' : 'patch';
  return { move, version: bumpVersion(input.version, move, t) };
}
