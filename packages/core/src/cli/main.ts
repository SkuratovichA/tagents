#!/usr/bin/env node
// tagents-core — the node face of this package, which is what is left of it once the Rust binary serves the verbs.
//
// What stays here: `plugin list [--json]`, and the host of plugins. A verb this file does not know is offered to the configured plugins before it is refused: `tagents-core telegram status` runs the `status` CliCommand of the plugin named `telegram` (cli/plugin-run.ts). The core verbs are matched FIRST and always win — what `plugin` and `help` mean must not depend on what somebody has installed.
//
// What went: `session`, `sessions`, `doctor`, `plugin add|remove|new`, `mcp`, `notify run` and the knowledge server verbs are the binary's (`impl: "rust"` in spec/cli/tagents-core.json). Called here they print one line that says so and exit 69.
//
// Exit codes: 0 ok · 1 error · 2 usage · 3 refused · 4 timeout · 69 no binary.
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createT, coreT } from '../i18n/index.ts';
import { EXIT, stdio, type Io } from './exit.ts';
import { plugin } from './plugin.ts';
import { runPluginCommand } from './plugin-run.ts';
import { servedByBinary } from './spec.ts';

export async function main(argv: string[], io: Io = stdio()): Promise<number> {
  const t = coreT(createT());
  const [verb, ...rest] = argv;
  try {
    // A verb the binary serves is not run here: this CLI says so and exits 69, the code `tagents-knowledge join` gives for the same reason. The list is the `impl` column of the spec file, so it cannot drift from the binary's.
    const retired = verb === undefined ? null : servedByBinary(verb, rest);
    if (retired !== null) {
      io.err(`${t('needsBinary', { verb: retired })}\n`);
      return EXIT.noBinary;
    }
    if (verb === 'plugin') return await plugin(rest, io, t);
    if (verb === undefined || verb === 'help' || verb === '--help' || verb === '-h') {
      io.out(`${t('usage')}\n`);
      return verb === undefined ? EXIT.usage : EXIT.ok;
    }
    // Every core verb is already answered above, so a word that got this far is
    // free to be a plugin's — and only then does the config get read at all.
    const fromPlugin = await runPluginCommand(verb, rest, io, t);
    if (fromPlugin !== null) return fromPlugin;
    io.err(`${t('unknownCommand', { command: verb })}\n${t('usage')}\n`);
    return EXIT.usage;
  } catch (e) {
    // parseArgs throws for an unknown flag: that is a usage error, not a crash.
    const err = e as NodeJS.ErrnoException;
    const usage = typeof err.code === 'string' && err.code.startsWith('ERR_PARSE_ARGS');
    io.err(`${err.message}\n`);
    return usage ? EXIT.usage : EXIT.error;
  }
}

// Run only as a program, never on import: a test imports main() directly.
// realpath first — installed as a bin, argv[1] is a symlink into .bin while
// import.meta.url is already the file it points at.
const invokedAs = process.argv[1] ? pathToFileURL(fs.realpathSync(process.argv[1])).href : '';
if (invokedAs === import.meta.url) {
  process.exitCode = await main(process.argv.slice(2));
}
