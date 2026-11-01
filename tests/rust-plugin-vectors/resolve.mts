// The resolution section of the plugin vectors: what node's `resolvePluginPackage` answers for each argument and working directory on the tree of `tree.mts`, `defaultPluginName`, and the `path.resolve` and `path.relative` the Rust twins stand for.
//
// A case is run with HOME set to `<root>/home` and with no `pnpm` on PATH, so node's last resort (`pnpm root -g`) finds nothing. `handOver` is design D5 applied: the Rust resolution answers a directory argument in full and a bare name only when a walk of `node_modules` finds it and nothing in the package or the environment can make node's answer differ (an `exports` key, a name that is not `name` or `@scope/name`, a package.json above the working directory that names the package and has `exports`); everything else is node's, and each such case says why.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { defaultPluginName, resolvePluginPackage } from '../../packages/core/src/plugin-config.ts';
import { materialise, tree } from './tree.mts';

interface Case {
  /** The argument; `<root>` stands for the root of the tree. */
  readonly spec: string;
  /** The working directory, relative to the root. */
  readonly cwd: string;
  /** Why the Rust verb hands the call to node, when it does. */
  readonly handOver?: string;
}

const CWD = 'proj/a/b';
const byPath = (spec: string, cwd = CWD): Case => ({ spec, cwd });
const byName = (spec: string, cwd = CWD, handOver?: string): Case => ({ spec, cwd, ...(handOver === undefined ? {} : { handOver }) });

const NOT_FOUND = 'the name is not found by the walk of node_modules, and node goes on to the global folders';
const EXPORTS = 'the package has an exports key';
const GRAMMAR = 'the name is not name or @scope/name';

const cases: readonly Case[] = [
  // A directory.
  byPath('../../../pkgs/plain'),
  byPath('<root>/pkgs/plain'),
  byPath('../../../pkgs/plain/'),
  byPath('../../../pkgs/../pkgs/plain'),
  byPath('<root>/pkgs//plain/./'),
  byPath('../../node_modules/linked'),
  byPath('<root>/proj/node_modules/linked'),
  byPath('.', 'pkgs/plain'),
  byPath('./', 'pkgs/plain'),
  byPath('..', 'pkgs/plain/src'),
  byPath('.'),
  byPath('..'),
  byPath('~'),
  byPath('~/'),
  byPath('~/home-pkg'),
  byPath('~//home-pkg/'),
  byPath('~x'),
  byPath('./nothing'),
  byPath('../../../pkgs/plain/package.json'),
  byPath('/'),
  byPath('/../..'),
  // Climbing past the root stays at the root, however deep the tree is laid out.
  byPath(`${'../'.repeat(60)}tmp-does-not-exist`),
  ...[
    'no-name',
    'empty-name',
    'name-number',
    'scoped-name',
    'prefixed-name',
    'api2',
    'api-1-0',
    'api-string',
    'no-tagents',
    'not-json',
    'bom-manifest',
    'manifest-array',
    'manifest-null',
    'empty-entry',
    'entry-number',
    'no-entry',
    'dangling-entry',
    'dir-entry',
    'with-exports',
    'no-manifest',
    'manifest-is-dir',
    'real-linked',
  ].map((name) => byPath(`<root>/pkgs/${name}`)),

  // A name, found from proj/a/b.
  byName('plain'),
  byName('@sc/plugin-x'),
  byName('no-name-nm'),
  byName('null-exports'),
  byName('no-tagents-nm'),
  byName('api2-nm'),
  byName('no-entry-nm'),
  byName('linked'),
  byName('shadow'),
  byName('hollow'),
  byName('dirjson'),
  byName('plain', 'proj/node_modules/plain/src'),
  byName('plain', 'proj'),
  byName('selfnoexp', 'selfnoexp/a'),
  byName('exports-with-package-json', CWD, EXPORTS),
  byName('exports-without-package-json', CWD, EXPORTS),
  byName('bad-json', CWD, 'the manifest in node_modules is not JSON, so its exports are unknown'),
  byName('selfref', 'selfref/a', 'the nearest package.json names the package and has exports, which node resolves first'),
  byName('not-installed', CWD, NOT_FOUND),
  byName('plain', 'home', NOT_FOUND),
  byName('plain/package.json', CWD, GRAMMAR),
  byName('plain/src', CWD, GRAMMAR),
  byName('_underscore', CWD, GRAMMAR),
  byName('a b', CWD, GRAMMAR),
  byName('@sc', CWD, GRAMMAR),
  byName('@sc/', CWD, GRAMMAR),
  byName('@/x', CWD, GRAMMAR),
  byName('@sc/a/b', CWD, GRAMMAR),
  byName('', CWD, 'an empty name'),
  byName('naïve', CWD, GRAMMAR),
];

/** Run node's resolution for each case; `<root>` in a path of the answer is the tree's root. */
export function resolveVectors(): unknown {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'plugin-vectors-tree-')));
  const emptyBin = path.join(root, '.no-bin');
  fs.mkdirSync(emptyBin);
  const saved = { HOME: process.env['HOME'], PATH: process.env['PATH'] };
  try {
    materialise(root);
    process.env['HOME'] = path.join(root, 'home');
    process.env['PATH'] = emptyBin;
    const norm = (text: string): string => text.split(root).join('<root>');
    const results = cases.map((c) => {
      const spec = c.spec.split('<root>').join(root);
      const cwd = path.join(root, c.cwd);
      const answer = resolvePluginPackage(spec, cwd);
      const result = answer.ok
        ? { ok: true, dir: norm(answer.pkg.dir), from: norm(answer.pkg.from), packageName: answer.pkg.packageName, entry: norm(answer.pkg.entry) }
        : { ok: false, problem: answer.problem, detail: norm(answer.detail) };
      return { spec: c.spec, cwd: c.cwd, result, handOver: c.handOver !== undefined, ...(c.handOver === undefined ? {} : { reason: c.handOver }) };
    });
    return {
      tree,
      cases: results,
      names: NAMES.map((name) => ({ name, key: defaultPluginName(name) })),
      resolve: RESOLVES.map(([base, rel]) => ({ base, path: rel, resolved: path.resolve(base, rel) })),
      relative: RELATIVES.map(([from, to]) => ({ from, to, relative: path.relative(from, to) })),
    };
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
}

const NAMES = [
  '@tagents/plugin-telegram',
  'tagents-plugin-x',
  'plugin-x',
  'x',
  'plugin-',
  'tagents-plugin-',
  '@a/b/c',
  '@s/tagents-plugin-plugin-y',
  'plugin-plugin-z',
  'tagents-plugin-tagents-plugin-w',
  '',
  '/x',
  'a/',
  'é',
  'my.plugin',
  '@scope/plugin-',
];

const RESOLVES: ReadonlyArray<readonly [string, string]> = [
  ['/w/x', 'a'],
  ['/w/x', './a/'],
  ['/w/x', '../a'],
  ['/w/x', '../../..'],
  ['/w/x', '../../../a'],
  ['/w/x', '/a/./b/../c//'],
  ['/w/x', ''],
  ['/w/x/', '.'],
  ['/', 'a'],
  ['/', '..'],
  ['/w', 'a b/é'],
  ['/w', '...'],
  ['/w', '.../a'],
  ['/w//x', 'a//b'],
  ['/w', '~'],
  ['/w', '~/x'],
];

const RELATIVES: ReadonlyArray<readonly [string, string]> = [
  ['/a/b', '/a/b'],
  ['/a/b', '/a/b/c/d'],
  ['/a/b/c', '/a/b'],
  ['/a/b/c', '/a/d'],
  ['/a/b', '/x/y'],
  ['/', '/a'],
  ['/a', '/'],
  ['/', '/'],
  ['/a/bc', '/a/b'],
  ['/a/b', '/a/bc'],
  ['/a/b/', '/a//b/./c'],
  ['/a/b', '/a/.hidden/x'],
  ['/a/b/c/d', '/a/x'],
  ['/a b/é', '/a b/é/\u{1F600}'],
];
