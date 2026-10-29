// Every verb of `tagents-core` as data. The data is spec/cli/tagents-core.json at the repository root, described by spec/cli/cli-spec.schema.json, because three programs read it: this CLI (`parseArgs` is handed `.options` of the same object a contract generator reads, so the flags a verb accepts and the flags it is documented to accept cannot be two lists), the contract generator, and the Rust front door. The usage text in i18n/en.ts stays hand-written; test/cli-spec.test.ts pins the two together.
import fs from 'node:fs';
import type { ParseArgsOptionsConfig } from 'node:util';
import { z } from 'zod';
import { en } from '../i18n/en.ts';
import { coreT, createT, type CoreKey } from '../i18n/index.ts';

/**
 * What running a verb does, for whoever decides whether to let it run: a person reading a permission prompt, or a client sorting tools by their hints.
 * `read` changes nothing, `write` changes files, settings or what is on the screen, `spawn` starts a program or a window that does things of its own (a Claude turn, a Claude session in a window, a command), `destructive` removes or stops something that cannot be got back, and `serve` runs until it is stopped, so it is no request/response verb and gets no tool.
 */
export type Effect = 'read' | 'write' | 'spawn' | 'destructive' | 'serve';

/** Every `Effect`, in the order spec/cli/cli-spec.schema.json lists them: the zod enum below reads it, and packages/contract/test/effects.test.ts pins it to the schema and to the server's reader. `satisfies` refuses a word that is no `Effect`, and the assertion under it refuses an `Effect` missing from the list. */
export const EFFECTS = ['read', 'write', 'spawn', 'destructive', 'serve'] as const satisfies readonly Effect[];
type Assert<T extends true> = T;
type _EveryEffectIsListed = Assert<Effect extends (typeof EFFECTS)[number] ? true : false>;

/** One verb of a CLI as data: what parseArgs is handed, and what the contract generator reads. */
export interface CommandSpec<Key extends string = string> {
  /** the words after the program name that select the verb, e.g. ['session', 'open'] */
  readonly path: readonly string[];
  /** positionals exactly as the usage text prints them: '<ref-json-or-id>', '<text>', '[N]', '<words…>' */
  readonly positionals: readonly string[];
  /** handed to parseArgs unchanged */
  readonly options: ParseArgsOptionsConfig;
  /** option names, without the dashes, the verb refuses to run without */
  readonly required: readonly string[];
  /** i18n key of the one-line summary of what the verb does or prints */
  readonly summary: Key;
  /** What the verb does to the machine; a verb without one is treated as the least safe kind by everything that reads it. */
  readonly effect?: Effect;
  /** `false` keeps the verb out of the plugin's tools: it stays a CLI verb, in the contract and the references. */
  readonly tool?: false;
  /** Booleans a tool call carries when it leaves the option out: `{ detach: true }` runs the verb with `--detach` unless the call passes `detach: false`. The data file of `tagents-core` has no such key; the CLIs whose specs are written in code use it. */
  readonly toolDefaults?: Readonly<Record<string, boolean>>;
}

/** A CLI's whole surface with the summaries resolved to English: the shape the contract generator consumes. */
export interface CliContract {
  readonly program: string;
  readonly exit: Readonly<Record<string, number>>;
  readonly commands: readonly {
    readonly path: readonly string[];
    readonly positionals: readonly string[];
    readonly options: Readonly<Record<string, { readonly type: 'string' | 'boolean'; readonly multiple?: boolean }>>;
    readonly required: readonly string[];
    readonly summary: string;
    readonly effect?: Effect;
    /** `false` keeps the verb out of the plugin's tools: it stays a CLI verb, in the contract and the references. */
    readonly tool?: false;
    /** Booleans a tool call carries when it leaves the option out: `{ detach: true }` runs the verb with `--detach` unless the call passes `detach: false`. */
    readonly toolDefaults?: Readonly<Record<string, boolean>>;
    /** What the verb cannot run without, so a caller that lacks it refuses at once: `tmux` is a tmux server of the caller's own (`$TMUX`). */
    readonly requires?: 'tmux';
  }[];
}

/**
 * Where the data file is. `src/cli` and `dist/cli` are the same depth below the package, so one relative URL finds it from the sources, from the build, from a checkout and from the copy installed at $TAGENTS_HOME (which is a checkout).
 */
export const SPEC_FILE = new URL('../../../../spec/cli/tagents-core.json', import.meta.url);

const isCoreKey = (key: string): key is CoreKey => Object.hasOwn(en, key);

// Strict on purpose: a key the schema does not know is a typo or a newer file, and either is better found at load than ignored. `impl` (which program serves the verb) is in the file for the Rust front door and this CLI drops it, while `effect` and `tool` are the contract generator's and pass through to `coreCliContract`.
const OptionFile = z.strictObject({ type: z.enum(['string', 'boolean']), multiple: z.boolean().optional() });
const CommandFile = z.strictObject({
  path: z.array(z.string().min(1)).min(1),
  positionals: z.array(z.string().min(1)),
  options: z.record(z.string(), OptionFile),
  required: z.array(z.string().min(1)),
  summary: z.string().refine(isCoreKey, { error: 'is not a key of the English catalogue' }),
  impl: z.enum(['rust', 'node']),
  effect: z.enum(EFFECTS).optional(),
  tool: z.literal(false).optional(),
});
const SpecFile = z.strictObject({
  $schema: z.string().optional(),
  program: z.string().min(1),
  exit: z.record(z.string(), z.number().int().min(0).max(255)),
  commands: z.array(CommandFile),
});

type ContractCommand = CliContract['commands'][number];
type LoadedCommand = Omit<CommandSpec<CoreKey>, 'options'> & { readonly options: ContractCommand['options'] };

/** `multiple` is left out rather than undefined, which is what exactOptionalPropertyTypes and the generated contract both want. */
function optionsOf(options: z.output<typeof CommandFile>['options']): ContractCommand['options'] {
  return Object.fromEntries(
    Object.entries(options).map(([name, o]) => [name, o.multiple === undefined ? { type: o.type } : { type: o.type, multiple: o.multiple }]),
  );
}

/** Dispatch is by path, so a second verb with a path already given would be shadowed and never run. The schema cannot state uniqueness, so this is checked after it matched; crates/tagents-spec refuses it too. */
function refuseSharedPath(commands: readonly { readonly path: readonly string[] }[], file: URL): void {
  const seen = new Set<string>();
  for (const { path } of commands) {
    const key = JSON.stringify(path);
    if (seen.has(key)) throw new Error(`tagents-core: ${file.pathname} has two verbs with the path "${path.join(' ')}" (dispatch is by path, so the second would never run)`);
    seen.add(key);
  }
}

export function loadSpec(file: URL = SPEC_FILE): { program: string; exit: Readonly<Record<string, number>>; commands: readonly LoadedCommand[] } {
  // Plain English, not t(): the catalogue is what failed to line up, and a checkout missing its spec has nothing to translate with.
  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    throw new Error(`tagents-core: cannot read its CLI spec ${file.pathname}: ${e instanceof Error ? e.message : String(e)}`, { cause: e });
  }
  const parsed = SpecFile.safeParse(JSON.parse(text));
  if (!parsed.success) throw new Error(`tagents-core: ${file.pathname} does not match spec/cli/cli-spec.schema.json: ${z.prettifyError(parsed.error)}`);
  const { program, exit, commands } = parsed.data;
  refuseSharedPath(commands, file);
  return {
    program,
    exit,
    commands: commands.map((c) => ({
      path: c.path,
      positionals: c.positionals,
      options: optionsOf(c.options),
      required: c.required,
      summary: c.summary,
      ...(c.effect === undefined ? {} : { effect: c.effect }),
      ...(c.tool === undefined ? {} : { tool: c.tool }),
    })),
  };
}

const SPEC = loadSpec();

/**
 * `parseArgs` types `values` from the literal option table it is handed, and a JSON import has no literals. So the verbs main.ts and plugin.ts parse keep their tables here as types, and `parsed` refuses to load when the data file says something else: adding a flag means editing the data file and this table, and forgetting either fails the first run, not a user.
 */
const PARSED = {
  'session open': {
    cwd: { type: 'string' },
    label: { type: 'string' },
    model: { type: 'string' },
    effort: { type: 'string' },
    resume: { type: 'string' },
    'system-prompt-file': { type: 'string' },
    'mcp-config': { type: 'string' },
    'config-dir': { type: 'string' },
    'no-config-dir': { type: 'boolean' },
    'skip-permissions': { type: 'boolean' },
  },
  'session prompt': {
    timeout: { type: 'string' },
    'warn-before': { type: 'string' },
    events: { type: 'boolean' },
  },
  'session list': { label: { type: 'string' }, state: { type: 'string', multiple: true } },
  'plugin list': { json: { type: 'boolean' } },
  'plugin add': { name: { type: 'string' } },
  'plugin remove': {},
  'plugin new': { dir: { type: 'string' } },
} as const satisfies Record<string, ParseArgsOptionsConfig>;

function sameOptions(a: ParseArgsOptionsConfig, b: ParseArgsOptionsConfig): boolean {
  const names = Object.keys(a);
  return (
    names.length === Object.keys(b).length &&
    names.every((name) => {
      const x = a[name];
      const y = b[name];
      return x !== undefined && y !== undefined && x.type === y.type && (x.multiple ?? false) === (y.multiple ?? false);
    })
  );
}

function parsed<K extends keyof typeof PARSED>(verb: K): Omit<LoadedCommand, 'options'> & { readonly options: (typeof PARSED)[K] } {
  const command = SPEC.commands.find((c) => c.path.join(' ') === verb);
  if (command === undefined) throw new Error(`tagents-core: ${SPEC_FILE.pathname} has no verb "${verb}", and src/cli/spec.ts parses it`);
  if (!sameOptions(command.options, PARSED[verb])) {
    throw new Error(`tagents-core: the options of "${verb}" in ${SPEC_FILE.pathname} differ from the table src/cli/spec.ts types for parseArgs`);
  }
  return { ...command, options: PARSED[verb] };
}

export const SESSION_OPEN = parsed('session open');
export const SESSION_PROMPT = parsed('session prompt');
export const SESSION_LIST = parsed('session list');
export const PLUGIN_LIST = parsed('plugin list');
export const PLUGIN_ADD = parsed('plugin add');
export const PLUGIN_REMOVE = parsed('plugin remove');
export const PLUGIN_NEW = parsed('plugin new');

export const CORE_COMMANDS: readonly LoadedCommand[] = SPEC.commands;

/** English whatever the machine's locale is: the contract is read by tools, not people. */
export function coreCliContract(): CliContract {
  const t = coreT(createT('en'));
  return {
    program: SPEC.program,
    exit: SPEC.exit,
    commands: CORE_COMMANDS.map((c) => ({
      path: c.path,
      positionals: c.positionals,
      options: c.options,
      required: c.required,
      summary: t(c.summary),
      ...(c.effect === undefined ? {} : { effect: c.effect }),
      ...(c.tool === undefined ? {} : { tool: c.tool }),
    })),
  };
}
