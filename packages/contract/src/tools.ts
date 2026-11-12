// The tool surface, derived: structured CLI specs in, MCP tools out. This file knows no verb of the product. A verb added to a spec is a tool the next time the contract is generated, and the same function answers when the server starts, so the list the contract records and the list a client sees cannot be two lists.
import type { CliContract, Effect } from '@tagents/core';

type Command = CliContract['commands'][number];

export interface ToolAnnotations {
  readonly readOnlyHint?: boolean;
  readonly destructiveHint?: boolean;
  readonly openWorldHint?: boolean;
}

export type PropertySchema =
  | { readonly type: 'string' }
  | { readonly type: 'boolean'; readonly default?: boolean }
  | { readonly type: 'array'; readonly items: { readonly type: 'string' }; readonly minItems?: 1 };

export interface InputSchema {
  readonly type: 'object';
  readonly properties: Readonly<Record<string, PropertySchema>>;
  readonly required: readonly string[];
  readonly additionalProperties: false;
}

export interface ToolSpec {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: InputSchema;
  readonly annotations: ToolAnnotations;
  /** the executable the verb belongs to, looked up on PATH when the tool is called */
  readonly program: string;
  /** the exit codes of that program by name, to say in words how a call ended */
  readonly exit: Readonly<Record<string, number>>;
  readonly command: Command;
  /** the verb's positionals in order, as the tool's arguments */
  readonly positionals: readonly Positional[];
}

export interface Positional {
  readonly name: string;
  readonly required: boolean;
  /** `<words…>`: any number of strings */
  readonly words: boolean;
}

/**
 * The hints an MCP client asks permission by. A verb without an effect gets `readOnlyHint: false` and nothing else, which the protocol reads as "may be destructive, may reach outside": the cautious answer for a verb nobody classified.
 */
const ANNOTATIONS: Readonly<Record<Exclude<Effect, 'serve'>, ToolAnnotations>> = {
  read: { readOnlyHint: true, openWorldHint: false },
  write: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  spawn: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
  destructive: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
};
const UNCLASSIFIED: ToolAnnotations = { readOnlyHint: false };

/** `<query…>` is required words, `[dir]` an optional value; the name is the text inside, in lower case with every run of other characters an underscore. */
export function parsePositional(text: string): Positional {
  const required = text.startsWith('<') && text.endsWith('>');
  if (!required && !(text.startsWith('[') && text.endsWith(']'))) throw new Error(`cannot read the positional ${text}: it is neither <required> nor [optional]`);
  const inner = text.slice(1, -1);
  const words = inner.endsWith('…');
  const name = (words ? inner.slice(0, -1) : inner).toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
  if (name === '') throw new Error(`cannot read the positional ${text}: it has no name`);
  return { name, required, words };
}

const word = (w: string): string => w.replace(/^-+/, '').replace(/[^A-Za-z0-9]+/g, '_');

/** `tagents-core` is `core`, so a tool is `core_session_list`; the script `tagents` keeps its name, so its `--new` is `tagents_new`. */
export const toolName = (program: string, path: readonly string[]): string =>
  [program.replace(/^tagents-/, ''), ...path.map(word)].join('_');

const sentence = (summary: string): string => {
  const capital = `${summary.charAt(0).toUpperCase()}${summary.slice(1)}`;
  return /[.!?]$/.test(capital) ? capital : `${capital}.`;
};

function inputSchemaOf(name: string, command: Command, positionals: readonly Positional[]): InputSchema {
  const properties: Record<string, PropertySchema> = {};
  for (const p of positionals) {
    properties[p.name] = p.words ? { type: 'array', items: { type: 'string' }, ...(p.required ? { minItems: 1 as const } : {}) } : { type: 'string' };
  }
  for (const [option, spec] of Object.entries(command.options)) {
    if (option in properties) throw new Error(`${name}: the option --${option} and a positional share the name ${option}`);
    const fallback = command.toolDefaults?.[option];
    properties[option] =
      spec.type === 'boolean' ? { type: 'boolean', ...(fallback === undefined ? {} : { default: fallback }) } : spec.multiple === true ? { type: 'array', items: { type: 'string' } } : { type: 'string' };
  }
  const required = [...positionals.filter((p) => p.required).map((p) => p.name), ...command.required];
  return { type: 'object', properties, required, additionalProperties: false };
}

/** A default can only be given to a boolean option the verb has: a spec that says anything else says something the argv cannot carry. */
function checkDefaults(name: string, command: Command): void {
  for (const option of Object.keys(command.toolDefaults ?? {})) {
    const spec = command.options[option];
    if (spec === undefined) throw new Error(`${name}: toolDefaults names --${option}, which the verb does not have`);
    if (spec.type !== 'boolean') throw new Error(`${name}: toolDefaults gives --${option} a boolean, and the option takes a string`);
  }
}

/** Whether a verb is offered as a tool: not one that serves until it is stopped, and not one the spec marks `tool: false`. The references say the same of each verb, from this function. */
export const isTool = (command: Command): command is Command & { readonly effect?: Exclude<Effect, 'serve'> } =>
  command.effect !== 'serve' && command.tool !== false;

/** One tool per verb that `isTool` says yes to. Sorted by name, so the order of the specs cannot move the contract. */
export function toolSpecs(clis: readonly CliContract[]): readonly ToolSpec[] {
  const tools = new Map<string, ToolSpec>();
  for (const cli of clis) {
    for (const command of cli.commands) {
      if (!isTool(command)) continue;
      const name = toolName(cli.program, command.path);
      if (tools.has(name)) throw new Error(`two verbs would both be the tool ${name}`);
      checkDefaults(name, command);
      const positionals = command.positionals.map(parsePositional);
      tools.set(name, {
        name,
        description: sentence(command.summary),
        inputSchema: inputSchemaOf(name, command, positionals),
        annotations: command.effect === undefined ? UNCLASSIFIED : ANNOTATIONS[command.effect],
        program: cli.program,
        exit: cli.exit,
        command,
        positionals,
      });
    }
  }
  return [...tools.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}
