// `tagents plugin new <name>` — the smallest package that is already a plugin.
//
// What "minimal" has to mean here: it TYPECHECKS AND RUNS as written. A
// scaffold whose first act is to fail `tsc` teaches the author that the
// contract is fiddly, when the whole point of definePlugin is that it is one
// object. So the files below are the reference plugin's shape with everything
// optional taken out — one verb, one test, a tsconfig that mirrors core's (the
// same strictness the host is written under) and a README that says what to do
// next.
//
// @tagents/core is depended on as `link:<relative path>`, the way the first
// real plugin depends on it: a scaffold made from a checkout points at that
// checkout and installs with no registry at all. Publishing one means swapping
// that for a version range, which the README says.
import path from 'node:path';

export interface ScaffoldFile {
  /** Relative to the package directory, with forward slashes. */
  readonly path: string;
  readonly body: string;
}

/** The core package this CLI is running out of — src/cli/… or dist/cli/…. */
export function corePackageDir(here = import.meta.dirname): string {
  return path.resolve(here, '..', '..');
}

const json = (value: unknown): string => `${JSON.stringify(value, null, 2)}\n`;

/** A relative specifier, always with a leading `./` or `../`. */
function relativeSpecifier(from: string, to: string): string {
  const rel = path.relative(from, to).split(path.sep).join('/');
  if (!rel) return '.';
  return rel.startsWith('.') ? rel : `./${rel}`;
}

const packageJson = (name: string, coreSpec: string): string =>
  json({
    name: `tagents-plugin-${name}`,
    version: '0.1.0',
    description: `A tagents plugin: ${name}`,
    type: 'module',
    private: true,
    exports: { '.': './src/plugin.ts' },
    tagents: { apiVersion: 1, entry: './src/plugin.ts' },
    engines: { node: '>=22.18' },
    scripts: {
      typecheck: 'tsc --noEmit',
      test: 'node --test "test/**/*.test.ts"',
    },
    dependencies: { '@tagents/core': coreSpec, zod: '^4.6' },
    devDependencies: { '@types/node': '^22', typescript: '5.9.3' },
  });

const tsconfigJson = (): string =>
  json({
    compilerOptions: {
      target: 'es2023',
      module: 'nodenext',
      moduleResolution: 'nodenext',
      lib: ['es2023'],
      types: ['node'],
      strict: true,
      erasableSyntaxOnly: true,
      noUncheckedIndexedAccess: true,
      exactOptionalPropertyTypes: true,
      noImplicitOverride: true,
      noFallthroughCasesInSwitch: true,
      verbatimModuleSyntax: true,
      isolatedModules: true,
      allowImportingTsExtensions: true,
      noEmit: true,
      skipLibCheck: true,
    },
    include: ['src', 'test'],
  });

const pluginTs = (name: string): string => `// ${name} — a tagents plugin.
//
// A plugin is DATA the host walks: a name, an api version, and the verbs,
// services and MCP tools it offers. Nothing here may run at import time — the
// host imports this file just to list what is in it.
import { definePlugin, type CliCommand, type PluginContext } from '@tagents/core';
import { z } from 'zod';

const HelloArgs = z.object({ who: z.string().default('world') });

const hello: CliCommand<typeof HelloArgs> = {
  name: 'hello',
  describe: 'the example verb — replace it with the one this plugin is for',
  args: HelloArgs,
  run: async (a, ctx: PluginContext): Promise<number> => {
    // ctx carries everything a plugin may touch: a session driver (a plugin
    // never spawns \`claude\` itself), a translator, a log sink, the tagents
    // config dir. Exit code 0 is success; see tagents-core for the rest.
    ctx.log(\`hello, \${a.who}\`);
    return 0;
  },
};

export default definePlugin({
  name: '${name}',
  apiVersion: 1,
  commands: [hello],
});
`;

const testTs = (name: string): string => `// The verb, exercised the way the host would run it: a real PluginContext
// from @tagents/core, and the exit code it answers with.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createContext } from '@tagents/core';
import plugin from '../src/plugin.ts';

test('${name} offers hello, and hello greets', async () => {
  assert.equal(plugin.apiVersion, 1);
  const hello = (plugin.commands ?? []).find((c) => c.name === 'hello');
  assert.ok(hello, 'the hello verb is in the catalogue');

  const said: string[] = [];
  const ctx = createContext({ plugin, log: (...parts: string[]) => said.push(parts.join(' ')) });
  const code = await hello.run(hello.args.parse({}), ctx);

  assert.equal(code, 0);
  assert.deepEqual(said, ['hello, world']);
});
`;

const readmeMd = (name: string, dir: string): string => `# tagents-plugin-${name}

A [tagents](https://github.com/) plugin: one package, one \`definePlugin({ … })\`
object, and a \`"tagents"\` manifest in its package.json that says where that
object lives.

\`\`\`sh
pnpm install
pnpm typecheck
pnpm test
\`\`\`

## Installing it

\`\`\`sh
tagents plugin add ${dir}       # writes it into ~/.config/tagents/config.yaml
tagents plugin list             # what it offers, as the host sees it
\`\`\`

\`plugin add\` reads the manifest only — it never imports this code. The host
imports \`src/plugin.ts\` when it loads the plugin, so nothing in it may run at
import time.

## What to change

* \`src/plugin.ts\` — \`commands\` are CLI verbs, \`services\` are things that keep
  running (each with \`drain()\` and \`stop()\`), \`mcpTools\` are MCP tools, and
  \`locales\` are extra i18next resources under your own namespace.
* \`package.json\` — \`@tagents/core\` is linked to the checkout this scaffold came
  from. Swap it for a version range before publishing.
`;

/** Every file `plugin new` writes, in the order it writes them. */
export function scaffoldFiles(name: string, dir: string, coreDir = corePackageDir()): ScaffoldFile[] {
  return [
    { path: 'package.json', body: packageJson(name, `link:${relativeSpecifier(dir, coreDir)}`) },
    { path: 'tsconfig.json', body: tsconfigJson() },
    { path: 'src/plugin.ts', body: pluginTs(name) },
    { path: 'test/plugin.test.ts', body: testTs(name) },
    { path: 'README.md', body: readmeMd(name, dir) },
  ];
}
