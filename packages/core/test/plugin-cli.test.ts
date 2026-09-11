// `tagents-core plugin list | add | remove | new`.
//
// Every case runs against a config dir under $TMPDIR, pointed at with
// TAGENTS_CONFIG_DIR: the owner's real ~/.config/tagents must never be read,
// and — this being the one suite that WRITES config files — never written.
//
// The load-bearing assertion is not "the entry is there". It is that
// everything else in the file came back byte for byte: the config is somebody's
// hand-written document with comments in it, and an installer that reflows it
// is an installer nobody runs twice.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { readPluginList } from '../src/host.ts';
import { addPluginEntry, defaultPluginName, removePluginEntry, resolvePluginPackage } from '../src/plugin-config.ts';
import { tmpDir } from '../src/testkit.ts';
import { FIXTURES, NODE, PKG, parseSingleJson, runCli } from './helpers.ts';

const PLUGINS = path.join(FIXTURES, 'plugin');
const GOOD = path.join(PLUGINS, 'good');

let tmp: string;
let seq = 0;

/** A fresh config dir per case, with `body` as its config.yaml when given. */
function configDir(body?: string): string {
  const dir = path.join(tmp, `cfg-${++seq}`);
  fs.mkdirSync(dir, { recursive: true });
  if (body !== undefined) fs.writeFileSync(path.join(dir, 'config.yaml'), body);
  return dir;
}

const configText = (dir: string): string => fs.readFileSync(path.join(dir, 'config.yaml'), 'utf8');

const inDir = (dir: string): Record<string, string> => ({ TAGENTS_CONFIG_DIR: dir });

before(() => {
  tmp = tmpDir('plugin-cli-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// ------------------------------------------------------------------- list ---

test('plugin list says so in words when nothing is configured', () => {
  const dir = configDir();
  const r = runCli(['plugin', 'list'], inDir(dir));
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^no plugins configured in .*config\.yaml\n$/);
});

test('plugin list --json is one JSON document, and the JSON is unchanged', () => {
  const dir = configDir();
  const r = runCli(['plugin', 'list', '--json'], inDir(dir));
  assert.equal(r.code, 0);
  const listed = parseSingleJson(r.stdout) as { plugins: unknown[]; errors: unknown[]; file: string };
  assert.deepEqual(listed.plugins, []);
  assert.deepEqual(listed.errors, []);
  assert.equal(listed.file, path.join(dir, 'config.yaml'));
});

test('plugin list prints the config key and what the plugin offers', () => {
  const dir = configDir();
  assert.equal(runCli(['plugin', 'add', GOOD], inDir(dir)).code, 0);
  const r = runCli(['plugin', 'list'], inDir(dir));
  assert.equal(r.code, 0);
  assert.equal(r.stdout, `fixture-plugin → ${GOOD}\n  commands: echo · services: ticker · mcp tools: sessions_recent\n`);
});

// -------------------------------------------------------------------- add ---

test('plugin add writes the entry the host then reads back', () => {
  const dir = configDir();
  const r = runCli(['plugin', 'add', GOOD], inDir(dir));
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^added fixture-plugin → /);
  assert.deepEqual(readPluginList(path.join(dir, 'config.yaml')), [{ name: 'fixture-plugin', from: GOOD }]);
});

test('a relative path is stored absolute — the host resolves from: against the CONFIG', () => {
  const dir = configDir();
  const rel = path.relative(PLUGINS, GOOD);
  const r = runCli(['plugin', 'add', `./${rel}`], inDir(dir), PLUGINS);
  assert.equal(r.code, 0);
  assert.deepEqual(readPluginList(path.join(dir, 'config.yaml')), [{ name: 'fixture-plugin', from: GOOD }]);
});

test('--name chooses the key, and a second add of the same key is refused', () => {
  const dir = configDir();
  assert.equal(runCli(['plugin', 'add', GOOD, '--name', 'demo'], inDir(dir)).code, 0);
  assert.deepEqual(readPluginList(path.join(dir, 'config.yaml')), [{ name: 'demo', from: GOOD }]);

  const again = runCli(['plugin', 'add', GOOD, '--name', 'demo'], inDir(dir));
  assert.equal(again.code, 3, 'already present is a refusal, not an error');
  assert.match(again.stderr, /demo is already listed in /);
  assert.deepEqual(readPluginList(path.join(dir, 'config.yaml')), [{ name: 'demo', from: GOOD }], 'nothing changed');
});

test('a package with no tagents manifest is refused, and a manifest pointing nowhere too', () => {
  const dir = configDir();
  const noManifest = runCli(['plugin', 'add', path.join(PLUGINS, 'no-entry')], inDir(dir));
  assert.equal(noManifest.code, 3);
  assert.match(noManifest.stderr, /has no "tagents"/);

  const noEntry = runCli(['plugin', 'add', path.join(PLUGINS, 'missing-entry')], inDir(dir));
  assert.equal(noEntry.code, 3);
  assert.match(noEntry.stderr, /which does not exist/);

  assert.ok(!fs.existsSync(path.join(dir, 'config.yaml')), 'a refusal writes no config file at all');
});

test('a package that is nowhere is an error, and no argument is a usage error', () => {
  const dir = configDir();
  const missing = runCli(['plugin', 'add', './nowhere-at-all'], inDir(dir));
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /no package at /);
  assert.equal(runCli(['plugin', 'add'], inDir(dir)).code, 2);
});

test('an installed package name is resolved from the cwd, and stored as the name', () => {
  const home = path.join(tmp, 'consumer');
  const pkg = path.join(home, 'node_modules', 'demo-plugin');
  fs.mkdirSync(pkg, { recursive: true });
  fs.writeFileSync(path.join(home, 'package.json'), '{"name":"consumer","version":"0.0.0"}\n');
  fs.writeFileSync(path.join(pkg, 'plugin.js'), 'export default {};\n');
  fs.writeFileSync(
    path.join(pkg, 'package.json'),
    '{"name":"demo-plugin","version":"1.0.0","tagents":{"apiVersion":1,"entry":"./plugin.js"}}\n'
  );

  const resolved = resolvePluginPackage('demo-plugin', home);
  assert.ok(resolved.ok);
  assert.equal(resolved.pkg.from, 'demo-plugin', 'a package name stays a package name');
  assert.equal(resolved.pkg.entry, path.join(pkg, 'plugin.js'));

  const dir = configDir();
  const r = runCli(['plugin', 'add', 'demo-plugin'], inDir(dir), home);
  assert.equal(r.code, 0);
  assert.deepEqual(readPluginList(path.join(dir, 'config.yaml')), [{ name: 'demo-plugin', from: 'demo-plugin' }]);
});

test('the default key is the package name without its scope or plugin- prefix', () => {
  assert.equal(defaultPluginName('@tagents/plugin-telegram'), 'telegram');
  assert.equal(defaultPluginName('tagents-plugin-notes'), 'notes');
  assert.equal(defaultPluginName('fixture-plugin'), 'fixture-plugin');
});

// ------------------------------------------------- the rest of the file ------

const HAND_WRITTEN = `# tagents — which Claude account an agent is started on.
claude:
  args: --dangerously-skip-permissions   # a string, or a list of arguments
  profiles:
    personal:
      config_dir: ~/.claude-personal     # aligned by hand, and it stays aligned
    work:

usage:
  monthly_limit_usd: 850

# a trailing note nobody may touch
`;

test('adding an entry changes the plugins map and nothing else, byte for byte', () => {
  const dir = configDir(HAND_WRITTEN);
  assert.equal(runCli(['plugin', 'add', GOOD, '--name', 'demo'], inDir(dir)).code, 0);

  const after_ = configText(dir);
  assert.equal(after_, `${HAND_WRITTEN}plugins:\n  demo:\n    from: ${GOOD}\n`);
  assert.ok(after_.startsWith(HAND_WRITTEN), 'every byte that was there is still there, in order');
});

test('a second entry lands inside the existing map, at the map’s own indent', () => {
  const dir = configDir(`plugins:\n    first:\n        from: /one\n\n# after the map\nusage:\n  x: 1\n`);
  assert.equal(runCli(['plugin', 'add', GOOD, '--name', 'second'], inDir(dir)).code, 0);
  assert.equal(
    configText(dir),
    `plugins:\n    first:\n        from: /one\n    second:\n        from: ${GOOD}\n\n# after the map\nusage:\n  x: 1\n`
  );
  assert.deepEqual(
    readPluginList(path.join(dir, 'config.yaml')).map((p) => p.name),
    ['first', 'second']
  );
});

test('an empty plugins: map, in either spelling, becomes a block with the entry in it', () => {
  for (const body of ['plugins:\nusage:\n  x: 1\n', 'plugins: {}\nusage:\n  x: 1\n']) {
    const dir = configDir(body);
    assert.equal(runCli(['plugin', 'add', GOOD, '--name', 'demo'], inDir(dir)).code, 0);
    assert.equal(configText(dir), `plugins:\n  demo:\n    from: ${GOOD}\nusage:\n  x: 1\n`);
  }
});

test('a config that does not parse is refused, not rewritten', () => {
  const broken = 'claude:\n  args: [unclosed\n';
  const dir = configDir(broken);
  const r = runCli(['plugin', 'add', GOOD], inDir(dir));
  assert.equal(r.code, 1);
  assert.equal(configText(dir), broken, 'a file we cannot read is a file we must not write');
});

// ----------------------------------------------------------------- remove ---

test('remove takes the entry out and leaves the file as it found it', () => {
  const dir = configDir(HAND_WRITTEN);
  assert.equal(runCli(['plugin', 'add', GOOD, '--name', 'demo'], inDir(dir)).code, 0);

  const r = runCli(['plugin', 'remove', 'demo'], inDir(dir));
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^removed demo from /);
  assert.equal(configText(dir), HAND_WRITTEN, 'the last entry takes the plugins: line with it');
});

test('removing one of several leaves the others, and their comments, alone', () => {
  const dir = configDir(`plugins:\n  a:\n    from: /one\n  b:\n    from: /two\n\n# after the map\n`);
  assert.equal(runCli(['plugin', 'remove', 'a'], inDir(dir)).code, 0);
  assert.equal(configText(dir), `plugins:\n  b:\n    from: /two\n\n# after the map\n`);
});

test('removing something that is not listed is refused, and says where it looked', () => {
  const dir = configDir(HAND_WRITTEN);
  const r = runCli(['plugin', 'remove', 'nope'], inDir(dir));
  assert.equal(r.code, 3);
  assert.match(r.stderr, /nope is not listed in /);
  assert.equal(configText(dir), HAND_WRITTEN);

  const empty = configDir();
  assert.equal(runCli(['plugin', 'remove', 'nope'], inDir(empty)).code, 3);
  assert.equal(runCli(['plugin', 'remove'], inDir(empty)).code, 2);
});

test('the two edits are also a library, for anything that is not this CLI', () => {
  const file = path.join(configDir('accounts:\n  personal: ~/.claude\n'), 'config.yaml');
  assert.equal(addPluginEntry(file, 'x', '/pkg/x'), 'added');
  assert.equal(addPluginEntry(file, 'x', '/pkg/x'), 'exists');
  assert.equal(removePluginEntry(file, 'x'), 'removed');
  assert.equal(removePluginEntry(file, 'x'), 'absent');
  assert.equal(fs.readFileSync(file, 'utf8'), 'accounts:\n  personal: ~/.claude\n');
});

// -------------------------------------------------------------------- new ---

test('plugin new scaffolds a package that plugin add then accepts', () => {
  const dir = path.join(tmp, 'scaffold-roundtrip');
  const r = runCli(['plugin', 'new', 'demo', '--dir', dir], inDir(configDir()));
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^wrote .*scaffold-roundtrip — install it with: tagents plugin add /);

  for (const rel of ['package.json', 'tsconfig.json', 'src/plugin.ts', 'test/plugin.test.ts', 'README.md']) {
    assert.ok(fs.existsSync(path.join(dir, rel)), `the scaffold wrote ${rel}`);
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')) as {
    name: string;
    tagents: { apiVersion: number; entry: string };
    dependencies: Record<string, string>;
  };
  assert.equal(manifest.name, 'tagents-plugin-demo');
  assert.deepEqual(manifest.tagents, { apiVersion: 1, entry: './src/plugin.ts' });
  assert.equal(manifest.dependencies['@tagents/core'], `link:${path.relative(dir, PKG)}`);

  const cfg = configDir();
  assert.equal(runCli(['plugin', 'add', dir], inDir(cfg)).code, 0, 'its own manifest passes the check add makes');
  assert.deepEqual(readPluginList(path.join(cfg, 'config.yaml')), [{ name: 'demo', from: dir }]);
});

test('plugin new refuses a directory with something in it, and a name it cannot use', () => {
  const taken = path.join(tmp, 'taken');
  fs.mkdirSync(taken, { recursive: true });
  fs.writeFileSync(path.join(taken, 'README.md'), 'mine\n');
  const r = runCli(['plugin', 'new', 'demo', '--dir', taken], inDir(configDir()));
  assert.equal(r.code, 3);
  assert.match(r.stderr, /exists and is not empty/);
  assert.equal(fs.readFileSync(path.join(taken, 'README.md'), 'utf8'), 'mine\n');

  assert.equal(runCli(['plugin', 'new', '../escape'], inDir(configDir())).code, 2);
  assert.equal(runCli(['plugin', 'new'], inDir(configDir())).code, 2);
});

/**
 * The promise `plugin new` makes is that the package typechecks AS WRITTEN, so
 * the check is tsc on the scaffold itself — core linked out of this workspace,
 * which is exactly what the generated `link:` dependency points at. It needs
 * core's dist/ (that is what @tagents/core's "types" resolves to), so before a
 * build there is nothing here to check.
 */
const TSC = path.join(PKG, 'node_modules', 'typescript', 'bin', 'tsc');
const buildable = fs.existsSync(path.join(PKG, 'dist', 'index.d.ts')) && fs.existsSync(TSC);

test('the scaffold typechecks as written', { skip: buildable ? false : 'needs a built core' }, () => {
  const dir = path.join(tmp, 'scaffold-tsc');
  assert.equal(runCli(['plugin', 'new', 'demo', '--dir', dir], inDir(configDir())).code, 0);

  const modules = path.join(dir, 'node_modules');
  fs.mkdirSync(path.join(modules, '@tagents'), { recursive: true });
  fs.mkdirSync(path.join(modules, '@types'), { recursive: true });
  fs.symlinkSync(PKG, path.join(modules, '@tagents', 'core'), 'dir');
  fs.symlinkSync(path.join(PKG, 'node_modules', 'zod'), path.join(modules, 'zod'), 'dir');
  fs.symlinkSync(path.join(PKG, 'node_modules', '@types', 'node'), path.join(modules, '@types', 'node'), 'dir');

  const r = spawnSync(NODE, [TSC, '--noEmit', '-p', dir], { encoding: 'utf8' });
  assert.equal(r.status, 0, `tsc on the scaffold:\n${r.stdout}${r.stderr}`);
});

// ------------------------------------------------------------------ usage ---

test('an unknown plugin verb is a usage error that prints the usage', () => {
  const r = runCli(['plugin', 'install', 'x'], inDir(configDir()));
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown command: plugin install/);
  assert.match(r.stderr, /plugin add <package-or-path>/);
});
