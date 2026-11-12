// Sources plus the state of the tree in, the set of changes out. No file system is touched here: tests hand it in-memory inputs, and tree.ts is the only place that reads or writes a file.
import { buildContract } from './contract.ts';
import { createT, type Translate } from './i18n/index.ts';
import { byCodeUnit } from './order.ts';
import { isJsonObject, parseJson, stringifyJson, type JsonObject, type JsonValue } from './json.ts';
import { PLUGINS, TAGENTS, type PluginDef } from './plugins.ts';
import { renderCli, renderMcp, renderScripts } from './render.ts';
import type { Sources } from './types.ts';
import { decideVersion, digestOf, type PayloadFile, type VersionMove } from './version.ts';

export const CONTRACT_FILE = 'contract.json';
export const PLUGIN_FILE = TAGENTS.manifest;
export const MARKETPLACE_FILE = '.claude-plugin/marketplace.json';
export const SKILLS_DIR = TAGENTS.skillsDir;
/** The directory the generator owns for the plugin that is the repo root: a file in it that it did not produce is stray. */
export const REFERENCES_DIR = TAGENTS.referencesDir;

/** The files the plan looks at, by path relative to the repo root with POSIX separators: contract.json, the marketplace, and for each plugin its manifest, everything under its skills directory and its shipped files. */
export interface Disk {
  readonly files: ReadonlyMap<string, string | Uint8Array>;
}

/** What a plugin's version came to. */
export interface PluginMove {
  readonly plugin: string;
  readonly digest: string;
  readonly move: VersionMove;
  readonly versionFrom: string;
  readonly versionTo: string;
}

/** The numbers at the top are those of the first plugin (the one that is the repo root); `plugins` has every one. */
export interface Plan extends PluginMove {
  /** path to new text, only the files whose content differs from the disk, sorted by path */
  readonly writes: ReadonlyMap<string, string>;
  /** stray files under a references directory, sorted */
  readonly deletes: readonly string[];
  /** every path a check would call stale: the writes and the deletes, sorted */
  readonly stale: readonly string[];
  readonly plugins: readonly PluginMove[];
  /** `program verb words` of every verb whose spec declares no effect: advisory, never a reason for a tree to be stale */
  readonly unclassified: readonly string[];
}

const text = (content: string | Uint8Array): string =>
  typeof content === 'string' ? content : Buffer.from(content).toString('utf8');

/** The items a plugin documents: those it names, or for the plugin that names none, those no plugin names. */
function ownedBy<T>(items: readonly T[], idOf: (item: T) => string, own: readonly string[] | undefined, claimed: readonly string[]): T[] {
  return items.filter((item) => (own === undefined ? !claimed.includes(idOf(item)) : own.includes(idOf(item))));
}

/** The references of one plugin, rendered in English; the plugin that is the repo root also gets the scripts and the API reports. */
function pluginFiles(plugin: PluginDef, sources: Sources, plugins: readonly PluginDef[]): ReadonlyMap<string, string> {
  const t = createT();
  const own = {
    cli: ownedBy(sources.cli, (c) => c.program, plugin.programs, plugins.flatMap((p) => p.programs ?? [])),
    mcp: ownedBy(sources.mcp, (m) => m.name, plugin.servers, plugins.flatMap((p) => p.servers ?? [])),
  };
  const files = new Map<string, string>([
    [`${plugin.referencesDir}/cli.md`, renderCli(own.cli, t)],
    [`${plugin.referencesDir}/mcp.md`, renderMcp(own.mcp, t)],
  ]);
  if (plugin === TAGENTS) {
    files.set(`${plugin.referencesDir}/scripts.md`, renderScripts(sources.scripts, t));
    for (const report of sources.api) files.set(`${plugin.referencesDir}/${report.file}`, report.markdown);
  }
  return files;
}

/** contract.json and the references of every plugin, rendered in English. */
export function generatedFiles(sources: Sources, contract: JsonObject = buildContract(sources), plugins: readonly PluginDef[] = PLUGINS): ReadonlyMap<string, string> {
  return new Map<string, string>([[CONTRACT_FILE, stringifyJson(contract)], ...plugins.flatMap((plugin) => [...pluginFiles(plugin, sources, plugins)])]);
}

function readManifest(plugin: PluginDef, disk: Disk, t: Translate): JsonObject {
  const raw = disk.files.get(plugin.manifest);
  if (raw === undefined) throw new Error(t('missingFile', { path: plugin.manifest }));
  let parsed: JsonValue;
  try {
    parsed = parseJson(text(raw));
  } catch (error) {
    throw new Error(t('badJson', { path: plugin.manifest, reason: error instanceof Error ? error.message : String(error) }));
  }
  if (!isJsonObject(parsed)) throw new Error(t('badJson', { path: plugin.manifest, reason: t('notAnObject') }));
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

/** The text of the slice of a contract on disk, when it parses; the slice is what moves a plugin's version. */
function sliceOfText(plugin: PluginDef, onDisk: string | undefined): string | undefined {
  if (onDisk === undefined) return undefined;
  try {
    const parsed = parseJson(onDisk);
    return isJsonObject(parsed) ? stringifyJson(plugin.slice(parsed)) : onDisk;
  } catch {
    return onDisk;
  }
}

/** `t` words the errors only; everything rendered into the tree is English. */
export function planGenerate(sources: Sources, disk: Disk, t: Translate = createT(), plugins: readonly PluginDef[] = PLUGINS): Plan {
  const contract = buildContract(sources);
  const generated = generatedFiles(sources, contract, plugins);
  const previousContract = disk.files.get(CONTRACT_FILE);
  const writes = new Map<string, string>();
  for (const path of [...generated.keys()].sort(byCodeUnit)) {
    const content = generated.get(path) ?? '';
    const current = disk.files.get(path);
    if (current === undefined || text(current) !== content) writes.set(path, content);
  }

  const moves = plugins.map((plugin): PluginMove => {
    const manifest = readManifest(plugin, disk, t);
    const storedDigest = metadataOf(manifest, t)['digest'];
    const owned = (path: string): boolean => path.startsWith(`${plugin.skillsDir}/`);
    const payload: PayloadFile[] = [
      ...[...generated].filter(([path]) => path.startsWith(`${plugin.referencesDir}/`) || (plugin === TAGENTS && path === CONTRACT_FILE)).map(([path, content]) => ({ path, content })),
      ...[...disk.files].filter(([path]) => owned(path) && !path.startsWith(`${plugin.referencesDir}/`)).map(([path, content]) => ({ path, content })),
      ...plugin.shipped.flatMap((path) => {
        const content = disk.files.get(path);
        return content === undefined ? [] : [{ path, content }];
      }),
      { path: plugin.manifest, content: stringifyJson(withoutOwnKeys(manifest, t)) },
    ];
    const marketplace = disk.files.get(MARKETPLACE_FILE);
    if (plugin === TAGENTS && marketplace !== undefined) payload.push({ path: MARKETPLACE_FILE, content: marketplace });
    const digest = digestOf(payload);
    const version = versionOf(manifest, t);
    const decision = decideVersion(
      {
        version,
        storedDigest: typeof storedDigest === 'string' ? storedDigest : undefined,
        digest,
        contractOnDisk: sliceOfText(plugin, previousContract === undefined ? undefined : text(previousContract)),
        contract: plugin.slice(contract),
      },
      t
    );
    if (decision.move !== 'same') {
      const next = stringifyJson(withOwnKeys(manifest, decision.version, digest, t));
      const current = disk.files.get(plugin.manifest);
      if (current === undefined || text(current) !== next) writes.set(plugin.manifest, next);
    }
    return { plugin: plugin.name, digest, move: decision.move, versionFrom: version, versionTo: decision.version };
  });
  const sortedWrites = new Map([...writes].sort(([a], [b]) => byCodeUnit(a, b)));

  const deletes = [...disk.files.keys()]
    .filter((path) => plugins.some((plugin) => path.startsWith(`${plugin.referencesDir}/`)) && !generated.has(path))
    .sort(byCodeUnit);

  const [first] = moves;
  if (first === undefined) throw new Error('no plugin to generate');
  return {
    ...first,
    writes: sortedWrites,
    deletes,
    stale: [...sortedWrites.keys(), ...deletes].sort(byCodeUnit),
    plugins: moves,
    unclassified: sources.cli.flatMap((cli) =>
      cli.commands.filter((command) => command.effect === undefined).map((command) => [cli.program, ...command.path].join(' '))
    ),
  };
}
