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

/** One tool per verb that answers and ends; a verb that serves until it is stopped, and a verb the spec marks `tool: false`, are left out. Sorted by name, so the order of the specs cannot move the contract. */
export function toolSpecs(clis: readonly CliContract[]): readonly ToolSpec[] {
  const tools = new Map<string, ToolSpec>();
  for (const cli of clis) {
    for (const command of cli.commands) {
      if (command.effect === 'serve' || command.tool === false) continue;
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

export type Argv = { readonly ok: true; readonly argv: readonly string[] } | { readonly ok: false; readonly message: string };

const refuse = (message: string): Argv => ({ ok: false, message });
const isStrings = (v: unknown): v is readonly string[] => Array.isArray(v) && v.every((x) => typeof x === 'string');

/**
 * The command line a call stands for: the verb's words, each option as `--name=value` (so a value that starts with a dash stays a value), then the positionals. The arguments are checked against the schema first, because nothing else does: the CLI would drop or misread what it does not know.
 * A boolean option the spec defaults (`toolDefaults`) is given as its default when the call leaves it out.
 * A positional that starts with a dash is refused: the verb would read it as a flag, and not every verb takes `--` to end the flags.
 */
export function argvFor(tool: ToolSpec, args: Readonly<Record<string, unknown>>): Argv {
  const { properties, required } = tool.inputSchema;
  for (const key of Object.keys(args)) if (!(key in properties)) return refuse(`unknown argument "${key}"`);
  for (const key of required) if (args[key] === undefined) return refuse(`missing required argument "${key}"`);
  // A NUL ends a C string: the operating system refuses to start a program with one in its arguments, and no verb can mean it.
  for (const [key, value] of Object.entries(args)) if ([value].flat().some((v) => typeof v === 'string' && v.includes('\0'))) return refuse(`argument "${key}" contains a NUL byte`);

  const flags: string[] = [];
  for (const [option, spec] of Object.entries(tool.command.options)) {
    const given = args[option];
    const value = given === undefined ? tool.command.toolDefaults?.[option] : given;
    if (value === undefined) continue;
    if (spec.type === 'boolean') {
      if (typeof value !== 'boolean') return refuse(`argument "${option}" must be a boolean`);
      if (value) flags.push(`--${option}`);
    } else if (spec.multiple === true) {
      if (!isStrings(value)) return refuse(`argument "${option}" must be an array of strings`);
      flags.push(...value.map((v) => `--${option}=${v}`));
    } else {
      if (typeof value !== 'string') return refuse(`argument "${option}" must be a string`);
      flags.push(`--${option}=${value}`);
    }
  }

  const values: string[] = [];
  let skipped: string | undefined;
  for (const p of tool.positionals) {
    const value = args[p.name];
    if (value === undefined) {
      skipped ??= p.name;
      continue;
    }
    if (skipped !== undefined) return refuse(`argument "${p.name}" needs "${skipped}" before it`);
    const given = p.words ? value : [value];
    if (!isStrings(given) || (p.words && !Array.isArray(value))) return refuse(`argument "${p.name}" must be ${p.words ? 'an array of strings' : 'a string'}`);
    const flagLike = given.find((v) => v.startsWith('-'));
    if (flagLike !== undefined) return refuse(`argument "${p.name}" starts with a dash ("${flagLike}"), which the verb would read as a flag`);
    values.push(...given);
  }
  return { ok: true, argv: [...tool.command.path, ...flags, ...values] };
}
