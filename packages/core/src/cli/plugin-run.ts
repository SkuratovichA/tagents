// Running a plugin's own CLI verb.
//
//   tagents-core telegram status
//   ^ the program   ^ a plugin   ^ one of the CliCommands it declares
//
// The plugin is named by its CONFIG KEY (the `plugins:` key in config.yaml) or
// by the name the definition gives itself, because a config key is free to
// differ from it and both spellings are what a person has in front of them.
// The core verbs are matched first, in main.ts, and always win: what `session`,
// `sessions`, `plugin`, `doctor` and `help` mean must not depend on what
// somebody happens to have installed.
//
// The parser here is deliberately small, and it knows nothing about the
// command's schema: argv becomes a plain object (`--key value`, `--key=value`,
// `--flag` → true, anything else a positional) and the command's own zod `args`
// does every bit of the deciding — types, coercion, defaults, what is required.
// The single exception is `_`: a command that declares it is handed the
// positionals, and a command that does not has them REFUSED rather than
// silently dropped, because an argument nobody reads is an argument the caller
// thinks was understood.
import type { TFunction } from 'i18next';
import { z } from 'zod';
import { configDir, configFile, loadPlugins, type LoadedPlugin } from '../host.ts';
import type { CliCommandDef } from '../plugin.ts';
import { createContext } from '../service.ts';
import { EXIT, type Io } from './exit.ts';

/** The key the positionals arrive under, when the schema asks for them. */
export const POSITIONALS = '_';

/** What argv says, before any schema has looked at it. */
export interface ParsedArgv {
  readonly flags: Readonly<Record<string, string | boolean>>;
  readonly positionals: readonly string[];
}

export type ArgvResult = { readonly ok: true; readonly value: ParsedArgv } | { readonly ok: false; readonly bad: string };

/**
 * argv → an object, with no opinion about what any of it means.
 *
 * `--key value` takes the next token unless it is another `--flag` (so
 * `--times -1` works and `--verbose --name x` does not eat the flag), and `--`
 * ends the options: everything after it is a positional, whatever it starts
 * with.
 */
export function parseArgv(argv: readonly string[]): ArgvResult {
  const flags: Record<string, string | boolean> = {};
  const positionals: string[] = [];
  let optionsOver = false;

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i] ?? '';
    if (optionsOver || !token.startsWith('--')) {
      positionals.push(token);
      continue;
    }
    if (token === '--') {
      optionsOver = true;
      continue;
    }
    const body = token.slice(2);
    const eq = body.indexOf('=');
    const key = eq === -1 ? body : body.slice(0, eq);
    if (!key) return { ok: false, bad: token };
    if (eq !== -1) {
      flags[key] = body.slice(eq + 1);
      continue;
    }
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith('--')) {
      flags[key] = next;
      i += 1;
    } else {
      flags[key] = true;
    }
  }
  return { ok: true, value: { flags, positionals } };
}

/** Does this command ask for the positionals? Only an object schema can. */
export function takesPositionals(schema: z.ZodType): boolean {
  if (!(schema instanceof z.ZodObject)) return false;
  const shape: Record<string, unknown> = schema.shape;
  return Object.hasOwn(shape, POSITIONALS);
}

/** One line per issue, `path: message`, the way a compiler lists them. */
export function issueLines(error: z.ZodError): string[] {
  return error.issues.map((issue) => {
    const where = issue.path.map(String).join('.');
    return where ? `${where}: ${issue.message}` : issue.message;
  });
}

/** `<plugin> <command> — describe`, for a caller who has to pick one. */
function listCommands(name: string, commands: readonly CliCommandDef[], io: Io, t: TFunction): number {
  if (!commands.length) {
    io.err(`${t('pluginNoCommands', { plugin: name })}\n`);
    return EXIT.usage;
  }
  io.err(`${t('pluginCommands', { plugin: name })}\n`);
  for (const c of commands) io.err(`${t('pluginCommandEntry', { name: c.name, describe: c.describe })}\n`);
  return EXIT.usage;
}

async function runCommand(
  found: LoadedPlugin,
  command: CliCommandDef,
  argv: readonly string[],
  io: Io,
  t: TFunction
): Promise<number> {
  const parsed = parseArgv(argv);
  if (!parsed.ok) {
    io.err(`${t('pluginBadFlag', { arg: parsed.bad })}\n`);
    return EXIT.usage;
  }

  const raw: Record<string, string | boolean | readonly string[]> = { ...parsed.value.flags };
  if (takesPositionals(command.args)) raw[POSITIONALS] = parsed.value.positionals;
  else if (parsed.value.positionals.length) {
    io.err(
      `${t('pluginNoPositionals', {
        plugin: found.name,
        command: command.name,
        args: parsed.value.positionals.join(' '),
      })}\n`
    );
    return EXIT.usage;
  }

  const checked = command.args.safeParse(raw);
  if (!checked.success) {
    for (const line of issueLines(checked.error)) io.err(`${line}\n`);
    return EXIT.usage;
  }

  // The plugin's own output is a person's, not a contract: stdout belongs to
  // the JSON verbs, so ctx.log appends lines to stderr.
  const ctx = createContext({
    plugin: found.def,
    log: (...parts: string[]): void => io.err(`${parts.join(' ')}\n`),
    configDir: configDir(),
  });
  try {
    return await command.run(checked.data, ctx);
  } catch (e) {
    io.err(`${e instanceof Error ? e.message : String(e)}\n`);
    return EXIT.error;
  }
}

/**
 * argv[0] was not a core verb: it may still be a plugin. Returns null when no
 * configured plugin answers to that name, so the caller can say what it always
 * said about a word it does not know.
 */
export async function runPluginCommand(name: string, argv: readonly string[], io: Io, t: TFunction): Promise<number | null> {
  const loaded = await loadPlugins(configFile());
  const found = loaded.plugins.find((p) => p.name === name || p.def.name === name);
  if (!found) {
    // A plugin that did not load is still that plugin: saying "unknown
    // command" here would send its owner looking for a typo instead of the
    // import error that is the actual news.
    const failed = loaded.errors.find((e) => e.name === name);
    if (!failed) return null;
    io.err(`${t('pluginFailed', { name: failed.name, error: failed.error })}\n`);
    return EXIT.error;
  }

  const commands = found.def.commands ?? [];
  const wanted = argv[0];
  const command = wanted === undefined ? undefined : commands.find((c) => c.name === wanted);
  if (!command) {
    if (wanted !== undefined) io.err(`${t('unknownCommand', { command: `${name} ${wanted}` })}\n`);
    return listCommands(name, commands, io, t);
  }
  return await runCommand(found, command, argv.slice(1), io, t);
}
