// Every verb of `tagents-core` as data. `parseArgs` is handed `.options` of the same object a contract generator reads, so the flags a verb accepts and the flags it is documented to accept cannot be two lists. The usage text in i18n/en.ts stays hand-written; test/cli-spec.test.ts pins the two together.
import type { ParseArgsOptionsConfig } from 'node:util';
import { coreT, createT, type CoreKey } from '../i18n/index.ts';
import { EXIT } from './exit.ts';

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
  }[];
}

export const SESSION_OPEN = {
  path: ['session', 'open'],
  positionals: [],
  options: {
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
  required: ['cwd'],
  summary: 'summarySessionOpen',
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_PROMPT = {
  path: ['session', 'prompt'],
  positionals: ['<ref-json-or-id>', '<text>'],
  options: {
    timeout: { type: 'string' },
    'warn-before': { type: 'string' },
    events: { type: 'boolean' },
  },
  required: [],
  summary: 'summarySessionPrompt',
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_LAST = {
  path: ['session', 'last'],
  positionals: ['<ref-json-or-id>'],
  options: {},
  required: [],
  summary: 'summarySessionLast',
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_LIST = {
  path: ['session', 'list'],
  positionals: [],
  options: { label: { type: 'string' }, state: { type: 'string', multiple: true } },
  required: [],
  summary: 'summarySessionList',
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_ABORT = {
  path: ['session', 'abort'],
  positionals: ['<ref-json-or-id>'],
  options: {},
  required: [],
  summary: 'summarySessionAbort',
} as const satisfies CommandSpec<CoreKey>;

export const SESSIONS_RECENT = {
  path: ['sessions', 'recent'],
  positionals: ['[N]'],
  options: {},
  required: [],
  summary: 'summarySessionsRecent',
} as const satisfies CommandSpec<CoreKey>;

export const SESSIONS_SEARCH = {
  path: ['sessions', 'search'],
  positionals: ['<words…>'],
  options: {},
  required: [],
  summary: 'summarySessionsSearch',
} as const satisfies CommandSpec<CoreKey>;

export const SESSIONS_SHOW = {
  path: ['sessions', 'show'],
  positionals: ['<id-prefix>'],
  options: {},
  required: [],
  summary: 'summarySessionsShow',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_LIST = {
  path: ['plugin', 'list'],
  positionals: [],
  options: { json: { type: 'boolean' } },
  required: [],
  summary: 'summaryPluginList',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_ADD = {
  path: ['plugin', 'add'],
  positionals: ['<package-or-path>'],
  options: { name: { type: 'string' } },
  required: [],
  summary: 'summaryPluginAdd',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_REMOVE = {
  path: ['plugin', 'remove'],
  positionals: ['<name>'],
  options: {},
  required: [],
  summary: 'summaryPluginRemove',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_NEW = {
  path: ['plugin', 'new'],
  positionals: ['<name>'],
  options: { dir: { type: 'string' } },
  required: [],
  summary: 'summaryPluginNew',
} as const satisfies CommandSpec<CoreKey>;

export const CONFIG_CONVERT = {
  path: ['config', 'convert'],
  positionals: ['[FILE]'],
  options: { write: { type: 'boolean' }, all: { type: 'boolean' } },
  required: [],
  summary: 'summaryConfigConvert',
} as const satisfies CommandSpec<CoreKey>;

export const DOCTOR = {
  path: ['doctor'],
  positionals: [],
  options: {},
  required: [],
  summary: 'summaryDoctor',
} as const satisfies CommandSpec<CoreKey>;

export const CORE_COMMANDS = [
  SESSION_OPEN,
  SESSION_PROMPT,
  SESSION_LAST,
  SESSION_LIST,
  SESSION_ABORT,
  SESSIONS_RECENT,
  SESSIONS_SEARCH,
  SESSIONS_SHOW,
  PLUGIN_LIST,
  PLUGIN_ADD,
  PLUGIN_REMOVE,
  PLUGIN_NEW,
  CONFIG_CONVERT,
  DOCTOR,
] as const satisfies readonly CommandSpec<CoreKey>[];

/** English whatever the machine's locale is: the contract is read by tools, not people. */
export function coreCliContract(): CliContract {
  const t = coreT(createT('en'));
  return {
    program: 'tagents-core',
    exit: EXIT,
    commands: CORE_COMMANDS.map((c) => ({
      path: c.path,
      positionals: c.positionals,
      options: c.options,
      required: c.required,
      summary: t(c.summary),
    })),
  };
}
