// `tagents-core plugin list [--json]` — what the config names, and what each plugin offers. `plugin add`, `remove` and `new` are the binary's (cli/main.ts answers them with the needs-binary line); a `plugin` word nobody serves is an unknown command.
import { parseArgs } from 'node:util';
import type { CoreT } from '../i18n/index.ts';
import { loadPlugins } from '../host.ts';
import { EXIT, json, type Io } from './exit.ts';
import { PLUGIN_LIST } from './spec.ts';

const listOr = (names: readonly string[] | undefined): string => (names?.length ? names.join(', ') : '—');

async function list(argv: string[], io: Io, t: CoreT): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: PLUGIN_LIST.options,
    strict: true,
    allowPositionals: false,
  });
  const loaded = await loadPlugins();

  if (values.json === true) {
    io.out(
      json({
        file: loaded.file,
        plugins: loaded.plugins.map((p) => ({
          name: p.def.name,
          configuredAs: p.name,
          from: p.from,
          entry: p.entry,
          apiVersion: p.def.apiVersion,
          commands: (p.def.commands ?? []).map((c) => c.name),
          services: (p.def.services ?? []).map((s) => s.name),
          mcpTools: (p.def.mcpTools ?? []).map((m) => m.name),
        })),
        errors: loaded.errors,
      })
    );
    return loaded.errors.length ? EXIT.error : EXIT.ok;
  }

  if (!loaded.plugins.length && !loaded.errors.length) {
    io.out(`${t('pluginNone', { file: loaded.file })}\n`);
    return EXIT.ok;
  }
  for (const p of loaded.plugins) {
    // The name printed is the CONFIG KEY, because that is what `plugin remove`
    // takes; the plugin's own name is in --json for anything that needs both.
    io.out(`${t('pluginEntry', { name: p.name, from: p.from })}\n`);
    io.out(
      `${t('pluginOffers', {
        commands: listOr((p.def.commands ?? []).map((c) => c.name)),
        services: listOr((p.def.services ?? []).map((s) => s.name)),
        mcpTools: listOr((p.def.mcpTools ?? []).map((m) => m.name)),
      })}\n`
    );
  }
  for (const e of loaded.errors) io.err(`${t('pluginFailed', { name: e.name, error: e.error })}\n`);
  return loaded.errors.length ? EXIT.error : EXIT.ok;
}

/** The `plugin` verb, dispatched. Throws nothing main.ts does not already catch. */
export async function plugin(argv: string[], io: Io, t: CoreT): Promise<number> {
  const [verb, ...rest] = argv;
  if (verb === 'list') return await list(rest, io, t);
  io.err(`${t('unknownCommand', { command: `plugin ${verb ?? ''}`.trim() })}\n${t('usage')}\n`);
  return EXIT.usage;
}
