// Every verb of `tagents-core` as data. `parseArgs` is handed `.options` of the same object a contract generator reads, so the flags a verb accepts and the flags it is documented to accept cannot be two lists. The usage text in i18n/en.ts stays hand-written; test/cli-spec.test.ts pins the two together.
import type { ParseArgsOptionsConfig } from 'node:util';
import { coreT, createT, type CoreKey } from '../i18n/index.ts';
import { EXIT } from './exit.ts';

/**
 * What running a verb does, for whoever decides whether to let it run: a person reading a permission prompt, or a client sorting tools by their hints.
 * `read` changes nothing, `write` changes files, settings or what is on the screen, `spawn` starts a program or a window that does things of its own (a Claude turn, a Claude session in a window, a command), `destructive` removes or stops something that cannot be got back, and `serve` runs until it is stopped, so it is no request/response verb and gets no tool.
 */
export type Effect = 'read' | 'write' | 'spawn' | 'destructive' | 'serve';

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
  /** Booleans a tool call carries when it leaves the option out: `{ detach: true }` runs the verb with `--detach` unless the call passes `detach: false`. */
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
  effect: 'read',
  // a reference is only useful to `session prompt`, which is no tool either
  tool: false,
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
  effect: 'spawn',
  // an unattended `claude -p` turn that blocks for up to 50 minutes and may skip permissions: a model that wants one runs it in a visible window with `tagents_window`
  tool: false,
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_LAST = {
  path: ['session', 'last'],
  positionals: ['<ref-json-or-id>'],
  options: {},
  required: [],
  summary: 'summarySessionLast',
  effect: 'read',
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_LIST = {
  path: ['session', 'list'],
  positionals: [],
  options: { label: { type: 'string' }, state: { type: 'string', multiple: true } },
  required: [],
  summary: 'summarySessionList',
  effect: 'read',
} as const satisfies CommandSpec<CoreKey>;

export const SESSION_ABORT = {
  path: ['session', 'abort'],
  positionals: ['<ref-json-or-id>'],
  options: {},
  required: [],
  summary: 'summarySessionAbort',
  effect: 'destructive',
  // it kills the process a reference names, and the reference is the caller's word
  tool: false,
} as const satisfies CommandSpec<CoreKey>;

export const SESSIONS_RECENT = {
  path: ['sessions', 'recent'],
  positionals: ['[N]'],
  options: {},
  required: [],
  summary: 'summarySessionsRecent',
  effect: 'read',
  // the `tagents-knowledge` MCP server already offers `sessions_recent`
  tool: false,
} as const satisfies CommandSpec<CoreKey>;

export const SESSIONS_SEARCH = {
  path: ['sessions', 'search'],
  positionals: ['<words…>'],
  options: {},
  required: [],
  summary: 'summarySessionsSearch',
  effect: 'read',
  // the `tagents-knowledge` MCP server already offers `sessions_search`
  tool: false,
} as const satisfies CommandSpec<CoreKey>;

export const SESSIONS_SHOW = {
  path: ['sessions', 'show'],
  positionals: ['<id-prefix>'],
  options: {},
  required: [],
  summary: 'summarySessionsShow',
  effect: 'read',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_LIST = {
  path: ['plugin', 'list'],
  positionals: [],
  options: { json: { type: 'boolean' } },
  required: [],
  summary: 'summaryPluginList',
  effect: 'read',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_ADD = {
  path: ['plugin', 'add'],
  positionals: ['<package-or-path>'],
  options: { name: { type: 'string' } },
  required: [],
  summary: 'summaryPluginAdd',
  effect: 'write',
  // it registers code the host later imports, outside any permission prompt
  tool: false,
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_REMOVE = {
  path: ['plugin', 'remove'],
  positionals: ['<name>'],
  options: {},
  required: [],
  summary: 'summaryPluginRemove',
  effect: 'destructive',
} as const satisfies CommandSpec<CoreKey>;

export const PLUGIN_NEW = {
  path: ['plugin', 'new'],
  positionals: ['<name>'],
  options: { dir: { type: 'string' } },
  required: [],
  summary: 'summaryPluginNew',
  effect: 'write',
} as const satisfies CommandSpec<CoreKey>;

export const DOCTOR = {
  path: ['doctor'],
  positionals: [],
  options: {},
  required: [],
  summary: 'summaryDoctor',
  effect: 'read',
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
  DOCTOR,
] as const satisfies readonly CommandSpec<CoreKey>[];

/** English whatever the machine's locale is: the contract is read by tools, not people. */
export function coreCliContract(): CliContract {
  const t = coreT(createT('en'));
  return {
    program: 'tagents-core',
    exit: EXIT,
    commands: CORE_COMMANDS.map((c) => {
      // The optional keys are read through the spec's own type: no verb of this CLI has `toolDefaults`, so its literal type does not list the key.
      const { effect, tool, toolDefaults }: Pick<CommandSpec, 'effect' | 'tool' | 'toolDefaults'> = c;
      return {
        path: c.path,
        positionals: c.positionals,
        options: c.options,
        required: c.required,
        summary: t(c.summary),
        ...(effect === undefined ? {} : { effect }),
        ...(tool === undefined ? {} : { tool }),
        ...(toolDefaults === undefined ? {} : { toolDefaults }),
      };
    }),
  };
}
