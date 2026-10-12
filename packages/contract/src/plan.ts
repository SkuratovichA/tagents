// Sources plus the state of the tree in, the set of changes out. No file system is touched here: tests hand it in-memory inputs, and main.ts is the only place that reads or writes a file.
import { buildContract } from './contract.ts';
import { createT, type Translate } from './i18n/index.ts';
import { byCodeUnit } from './order.ts';
import { isJsonObject, parseJson, stringifyJson, type JsonObject, type JsonValue } from './json.ts';
import { renderCli, renderMcp, renderScripts } from './render.ts';
import type { Sources } from './types.ts';
import { decideVersion, digestOf, type PayloadFile, type VersionMove } from './version.ts';

export const CONTRACT_FILE = 'contract.json';
export const PLUGIN_FILE = '.claude-plugin/plugin.json';
export const MARKETPLACE_FILE = '.claude-plugin/marketplace.json';
export const SKILLS_DIR = 'skills';
/** The directory the generator owns: a file in it that it did not produce is stray. */
export const REFERENCES_DIR = 'skills/tagents/references';

/** The files the plan looks at, by path relative to the repo root with POSIX separators: contract.json, both files of .claude-plugin and everything under skills/. */
export interface Disk {
  readonly files: ReadonlyMap<string, string | Uint8Array>;
}

export interface Plan {
  /** path to new text, only the files whose content differs from the disk, sorted by path */
  readonly writes: ReadonlyMap<string, string>;
  /** stray files under the references directory, sorted */
  readonly deletes: readonly string[];
  /** every path a check would call stale: the writes and the deletes, sorted */
  readonly stale: readonly string[];
  readonly digest: string;
  readonly move: VersionMove;
  readonly versionFrom: string;
  readonly versionTo: string;
}

const text = (content: string | Uint8Array): string =>
  typeof content === 'string' ? content : Buffer.from(content).toString('utf8');

/** The references and contract.json, rendered in English whatever the machine's locale is. */
export function generatedFiles(sources: Sources, contract: JsonObject = buildContract(sources)): ReadonlyMap<string, string> {
  const t = createT('en');
  return new Map<string, string>([
    [CONTRACT_FILE, stringifyJson(contract)],
    [`${REFERENCES_DIR}/cli.md`, renderCli(sources.cli, t)],
    [`${REFERENCES_DIR}/mcp.md`, renderMcp(sources.mcp, t)],
    [`${REFERENCES_DIR}/scripts.md`, renderScripts(sources.scripts, t)],
    ...sources.api.map((report): [string, string] => [`${REFERENCES_DIR}/${report.file}`, report.markdown]),
  ]);
}

function readPlugin(disk: Disk, t: Translate): JsonObject {
  const raw = disk.files.get(PLUGIN_FILE);
  if (raw === undefined) throw new Error(t('missingFile', { path: PLUGIN_FILE }));
  let parsed: JsonValue;
  try {
    parsed = parseJson(text(raw));
  } catch (error) {
    throw new Error(t('badJson', { path: PLUGIN_FILE, reason: error instanceof Error ? error.message : String(error) }));
  }
  if (!isJsonObject(parsed)) throw new Error(t('badJson', { path: PLUGIN_FILE, reason: t('notAnObject') }));
  return parsed;
}

function metadataOf(plugin: JsonObject, t: Translate): JsonObject {
  const metadata = plugin['metadata'];
  if (metadata === undefined) return {};
  if (!isJsonObject(metadata)) throw new Error(t('badPluginField', { field: 'metadata' }));
  return metadata;
}

function versionOf(plugin: JsonObject, t: Translate): string {
  const version = plugin['version'];
  if (typeof version !== 'string') throw new Error(t('badPluginField', { field: 'version' }));
  return version;
}

/** plugin.json without the two keys the generator owns; `metadata` goes too when the digest was all of it, so a first run and a later one hash alike. */
function withoutOwnKeys(plugin: JsonObject, t: Translate): JsonObject {
  const restMetadata = Object.fromEntries(Object.entries(metadataOf(plugin, t)).filter(([key]) => key !== 'digest'));
  const entries = Object.entries(plugin)
    .filter(([key]) => key !== 'version')
    .flatMap(([key, value]): [string, JsonValue][] => {
      if (key !== 'metadata') return [[key, value]];
      return Object.keys(restMetadata).length === 0 ? [] : [[key, restMetadata]];
    });
  return Object.fromEntries(entries);
}

/** plugin.json with the new version and digest, every other key where it was; `metadata` is appended when it is new. */
function withOwnKeys(plugin: JsonObject, version: string, digest: string, t: Translate): JsonObject {
  const metadata = { ...metadataOf(plugin, t), digest };
  const entries = Object.entries(plugin).map(([key, value]): [string, JsonValue] =>
    key === 'version' ? [key, version] : key === 'metadata' ? [key, metadata] : [key, value]
  );
  return Object.fromEntries('metadata' in plugin ? entries : [...entries, ['metadata', metadata]]);
}

/** `t` words the errors only: what is rendered into the tree is English whatever it is. */
export function planGenerate(sources: Sources, disk: Disk, t: Translate = createT('en')): Plan {
  const contract = buildContract(sources);
  const generated = generatedFiles(sources, contract);
  const plugin = readPlugin(disk, t);
  const storedDigest = metadataOf(plugin, t)['digest'];

  const payload: PayloadFile[] = [
    ...[...generated].map(([path, content]) => ({ path, content })),
    ...[...disk.files]
      .filter(([path]) => path.startsWith(`${SKILLS_DIR}/`) && !path.startsWith(`${REFERENCES_DIR}/`))
      .map(([path, content]) => ({ path, content })),
    { path: PLUGIN_FILE, content: stringifyJson(withoutOwnKeys(plugin, t)) },
  ];
  const marketplace = disk.files.get(MARKETPLACE_FILE);
  if (marketplace !== undefined) payload.push({ path: MARKETPLACE_FILE, content: marketplace });
  const digest = digestOf(payload);

  const previousContract = disk.files.get(CONTRACT_FILE);
  const version = versionOf(plugin, t);
  const decision = decideVersion(
    {
      version,
      storedDigest: typeof storedDigest === 'string' ? storedDigest : undefined,
      digest,
      contractOnDisk: previousContract === undefined ? undefined : text(previousContract),
      contract,
    },
    t
  );

  const writes = new Map<string, string>();
  for (const path of [...generated.keys()].sort(byCodeUnit)) {
    const content = generated.get(path) ?? '';
    const current = disk.files.get(path);
    if (current === undefined || text(current) !== content) writes.set(path, content);
  }
  if (decision.move !== 'same') {
    const next = stringifyJson(withOwnKeys(plugin, decision.version, digest, t));
    const current = disk.files.get(PLUGIN_FILE);
    if (current === undefined || text(current) !== next) writes.set(PLUGIN_FILE, next);
  }
  const sortedWrites = new Map([...writes].sort(([a], [b]) => byCodeUnit(a, b)));

  const deletes = [...disk.files.keys()]
    .filter((path) => path.startsWith(`${REFERENCES_DIR}/`) && !generated.has(path))
    .sort(byCodeUnit);

  return {
    writes: sortedWrites,
    deletes,
    stale: [...sortedWrites.keys(), ...deletes].sort(byCodeUnit),
    digest,
    move: decision.move,
    versionFrom: version,
    versionTo: decision.version,
  };
}
