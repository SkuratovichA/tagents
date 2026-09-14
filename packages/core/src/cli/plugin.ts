// `tagents-core plugin …` — installing plugins the way a Storybook addon is
// installed: one command that resolves the package, checks it really is one,
// and writes the line the host reads.
//
//   plugin list [--json]              what the config names, and what each offers
//   plugin add <package-or-path> [--name N]
//   plugin remove <name>
//   plugin new <name> [--dir D]       a package that is already a plugin
//
// `add` NEVER IMPORTS THE PACKAGE. It reads package.json and stats the entry
// file, and that is the whole check — importing a stranger's code to decide
// whether to install it is the wrong way round. The host imports it later,
// once the owner has chosen it (host.ts).
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import type { CoreT } from '../i18n/index.ts';
import { configFile, loadPlugins } from '../host.ts';
import {
  addPluginEntry,
  defaultPluginName,
  removePluginEntry,
  resolvePluginPackage,
} from '../plugin-config.ts';
import { EXIT, json, type Io } from './exit.ts';
import { scaffoldFiles } from './scaffold.ts';

/** A config key and a directory name, so it is typeable and greppable. */
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

const listOr = (names: readonly string[] | undefined): string => (names?.length ? names.join(', ') : '—');

async function list(argv: string[], io: Io, t: CoreT): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: { json: { type: 'boolean' } },
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

function add(argv: string[], io: Io, t: CoreT, cwd: string): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { name: { type: 'string' } },
    strict: true,
    allowPositionals: true,
  });
  const spec = positionals[0];
  if (spec === undefined) {
    io.err(`${t('missingOption', { option: '<package-or-path>' })}\n`);
    return EXIT.usage;
  }

  const resolved = resolvePluginPackage(spec, cwd);
  if (!resolved.ok) {
    if (resolved.problem === 'not-found') {
      io.err(`${t('pluginUnresolved', { spec: resolved.detail })}\n`);
      return EXIT.error;
    }
    // Something IS there and it is not a plugin: a refusal, not a failure.
    if (resolved.problem === 'no-entry') io.err(`${t('pluginNoEntry', { file: resolved.detail })}\n`);
    else io.err(`${t('pluginBadManifest', { file: resolved.detail })}\n`);
    return EXIT.refused;
  }

  const name = values.name ?? defaultPluginName(resolved.pkg.packageName);
  if (!NAME.test(name)) {
    io.err(`${t('pluginBadName', { name })}\n`);
    return EXIT.usage;
  }

  const file = configFile();
  if (addPluginEntry(file, name, resolved.pkg.from) === 'exists') {
    io.err(`${t('pluginExists', { name, file })}\n`);
    return EXIT.refused;
  }
  io.out(`${t('pluginAdded', { name, from: resolved.pkg.from, file })}\n`);
  return EXIT.ok;
}

function remove(argv: string[], io: Io, t: CoreT): number {
  const { positionals } = parseArgs({ args: argv, options: {}, strict: true, allowPositionals: true });
  const name = positionals[0];
  if (name === undefined) {
    io.err(`${t('missingOption', { option: '<name>' })}\n`);
    return EXIT.usage;
  }
  const file = configFile();
  if (removePluginEntry(file, name) === 'absent') {
    io.err(`${t('pluginNotListed', { name, file })}\n`);
    return EXIT.refused;
  }
  io.out(`${t('pluginRemoved', { name, file })}\n`);
  return EXIT.ok;
}

function create(argv: string[], io: Io, t: CoreT, cwd: string): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { dir: { type: 'string' } },
    strict: true,
    allowPositionals: true,
  });
  const name = positionals[0];
  if (name === undefined) {
    io.err(`${t('missingOption', { option: '<name>' })}\n`);
    return EXIT.usage;
  }
  if (!NAME.test(name)) {
    io.err(`${t('pluginBadName', { name })}\n`);
    return EXIT.usage;
  }

  const dir = path.resolve(cwd, values.dir ?? name);
  // An existing directory is only in the way when there is something in it:
  // `plugin new x --dir .` inside an empty repo somebody just cloned is the
  // case that has to work.
  if (fs.existsSync(dir) && fs.readdirSync(dir).length > 0) {
    io.err(`${t('pluginTargetExists', { dir })}\n`);
    return EXIT.refused;
  }

  for (const file of scaffoldFiles(name, dir)) {
    const target = path.join(dir, file.path);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, file.body);
  }
  io.out(`${t('pluginScaffolded', { dir })}\n`);
  return EXIT.ok;
}

/** The `plugin` verb, dispatched. Throws nothing main.ts does not already catch. */
export async function plugin(argv: string[], io: Io, t: CoreT, cwd: string = process.cwd()): Promise<number> {
  const [verb, ...rest] = argv;
  if (verb === 'list') return await list(rest, io, t);
  if (verb === 'add') return add(rest, io, t, cwd);
  if (verb === 'remove') return remove(rest, io, t);
  if (verb === 'new') return create(rest, io, t, cwd);
  io.err(`${t('unknownCommand', { command: `plugin ${verb ?? ''}`.trim() })}\n${t('usage')}\n`);
  return EXIT.usage;
}
