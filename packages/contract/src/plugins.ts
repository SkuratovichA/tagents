// The plugins of this repository and what each one owns. The generator is the same for all of them: per plugin a manifest, the files generated for it, the files it ships as they are, a digest and a version.
import { isJsonObject, type JsonObject, type JsonValue } from './json.ts';

/** The program and the MCP server the okb plugin is made of, by the names the contract gives them. */
export const OKB_PROGRAM = 'tagents-knowledge';
export const KNOWLEDGE_SERVER_NAME = 'tagents-knowledge';

export interface PluginDef {
  readonly name: string;
  /** the plugin's directory relative to the repo root with a trailing slash, empty for the plugin that is the repo root */
  readonly root: string;
  /** the manifest the digest and the version are kept in */
  readonly manifest: string;
  /** every file under it is shipped, the references directory aside, which the generator owns */
  readonly skillsDir: string;
  readonly referencesDir: string;
  /** files outside the generated ones and skills/ that the manifest starts or points at */
  readonly shipped: readonly string[];
  /** the CLI programs and the MCP servers it documents; `undefined` is everything no other plugin documents */
  readonly programs: readonly string[] | undefined;
  readonly servers: readonly string[] | undefined;
  /** the part of contract.json whose structure moves the version */
  readonly slice: (contract: JsonObject) => JsonValue;
}

const pick = (value: JsonValue | undefined, keys: readonly string[]): JsonObject =>
  isJsonObject(value) ? Object.fromEntries(Object.entries(value).filter(([key]) => keys.includes(key))) : {};

export const OKB: PluginDef = {
  name: 'okb',
  root: 'plugins/okb/',
  manifest: 'plugins/okb/.claude-plugin/plugin.json',
  skillsDir: 'plugins/okb/skills',
  referencesDir: 'plugins/okb/skills/okb/references',
  shipped: ['plugins/okb/bin/okb-mcp'],
  programs: [OKB_PROGRAM],
  servers: [KNOWLEDGE_SERVER_NAME],
  slice: (contract) => ({ cli: pick(contract['cli'], [OKB_PROGRAM]), mcp: pick(contract['mcp'], [KNOWLEDGE_SERVER_NAME]) }),
};

export const TAGENTS: PluginDef = {
  name: 'tagents',
  root: '',
  manifest: '.claude-plugin/plugin.json',
  skillsDir: 'skills',
  referencesDir: 'skills/tagents/references',
  shipped: [],
  programs: undefined,
  servers: undefined,
  slice: (contract) => contract,
};

/** The plugin that is the repo root comes first: its numbers are the ones the plan reports at the top. */
export const PLUGINS: readonly PluginDef[] = [TAGENTS, OKB];
