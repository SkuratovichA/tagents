// The tree of packages the resolution vectors and the parity suite resolve `plugin add` arguments against: one package for each condition that makes node's answer differ.
//
// Entries are relative to the root of the tree. `materialise.mts <dir>` writes it for the shell suite, and the Rust test of the vectors builds the same tree from the data in `plugin-vectors.json`.
import fs from 'node:fs';
import path from 'node:path';

export interface TreeEntry {
  readonly path: string;
  readonly kind: 'dir' | 'file' | 'symlink';
  /** The file's text. */
  readonly text?: string;
  /** What a symbolic link says. */
  readonly target?: string;
}

const manifest = (extra: Record<string, unknown> = {}, entry: unknown = './src/plugin.ts'): string =>
  JSON.stringify({ tagents: { apiVersion: 1, entry }, ...extra }, null, 2);

const dir = (p: string): TreeEntry => ({ path: p, kind: 'dir' });
const file = (p: string, text: string): TreeEntry => ({ path: p, kind: 'file', text });
const link = (p: string, target: string): TreeEntry => ({ path: p, kind: 'symlink', target });

/** A directory that is a plugin: a manifest and the entry it names. */
const plugin = (at: string, extra: Record<string, unknown> = {}): TreeEntry[] => [file(`${at}/package.json`, manifest(extra)), file(`${at}/src/plugin.ts`, 'export default {};\n')];

export const tree: readonly TreeEntry[] = [
  dir('home'),
  ...plugin('home/home-pkg', { name: 'home-pkg' }),

  // By directory.
  ...plugin('pkgs/plain', { name: 'plain-pkg' }),
  ...plugin('pkgs/no-name'),
  ...plugin('pkgs/empty-name', { name: '' }),
  ...plugin('pkgs/name-number', { name: 5 }),
  ...plugin('pkgs/scoped-name', { name: '@tagents/plugin-telegram' }),
  ...plugin('pkgs/prefixed-name', { name: 'tagents-plugin-wiki' }),
  file('pkgs/api2/package.json', JSON.stringify({ name: 'api2', tagents: { apiVersion: 2, entry: './src/plugin.ts' } })),
  file('pkgs/api-1-0/package.json', '{"name":"api-1-0","tagents":{"apiVersion":1.0,"entry":"./src/plugin.ts"}}'),
  file('pkgs/api-1-0/src/plugin.ts', ''),
  file('pkgs/api-string/package.json', '{"name":"api-string","tagents":{"apiVersion":"1","entry":"./src/plugin.ts"}}'),
  file('pkgs/no-tagents/package.json', '{"name":"no-tagents"}'),
  file('pkgs/not-json/package.json', 'this is not JSON\n'),
  file('pkgs/bom-manifest/package.json', `﻿${manifest({ name: 'bom-manifest' })}`),
  file('pkgs/manifest-array/package.json', '[]'),
  file('pkgs/manifest-null/package.json', 'null'),
  file('pkgs/empty-entry/package.json', manifest({ name: 'empty-entry' }, '')),
  file('pkgs/entry-number/package.json', manifest({ name: 'entry-number' }, 5)),
  file('pkgs/no-entry/package.json', manifest({ name: 'no-entry' }, './src/missing.ts')),
  file('pkgs/dangling-entry/package.json', manifest({ name: 'dangling-entry' }, './src/gone.ts')),
  link('pkgs/dangling-entry/src/gone.ts', 'nowhere.ts'),
  file('pkgs/dir-entry/package.json', manifest({ name: 'dir-entry' }, './src')),
  file('pkgs/dir-entry/src/plugin.ts', ''),
  file('pkgs/with-exports/package.json', manifest({ name: 'with-exports', exports: { '.': './src/plugin.ts' } })),
  file('pkgs/with-exports/src/plugin.ts', ''),
  dir('pkgs/no-manifest'),
  dir('pkgs/manifest-is-dir/package.json'),
  ...plugin('pkgs/real-linked', { name: 'real-linked' }),

  // By name, from proj/a/b.
  file('proj/package.json', '{"name":"proj","version":"1.0.0"}'),
  dir('proj/a/b'),
  ...plugin('proj/node_modules/plain', { name: 'plain-in-nm' }),
  ...plugin('proj/node_modules/@sc/plugin-x', { name: '@sc/plugin-x' }),
  ...plugin('proj/node_modules/no-name-nm'),
  ...plugin('proj/node_modules/null-exports', { name: 'null-exports', exports: null }),
  ...plugin('proj/node_modules/exports-with-package-json', { name: 'exports-with-package-json', exports: { '.': './src/plugin.ts', './package.json': './package.json' } }),
  ...plugin('proj/node_modules/exports-without-package-json', { name: 'exports-without-package-json', exports: { '.': './src/plugin.ts' } }),
  file('proj/node_modules/bad-json/package.json', 'not json'),
  file('proj/node_modules/no-tagents-nm/package.json', '{"name":"no-tagents-nm"}'),
  file('proj/node_modules/api2-nm/package.json', '{"name":"api2-nm","tagents":{"apiVersion":2,"entry":"./src/plugin.ts"}}'),
  file('proj/node_modules/no-entry-nm/package.json', manifest({ name: 'no-entry-nm' }, './src/missing.ts')),
  link('proj/node_modules/linked', '../../pkgs/real-linked'),
  ...plugin('proj/a/node_modules/shadow', { name: 'shadow-near' }),
  ...plugin('proj/node_modules/shadow', { name: 'shadow-far' }),
  dir('proj/a/node_modules/hollow'),
  ...plugin('proj/node_modules/hollow', { name: 'hollow-far' }),
  dir('proj/a/node_modules/dirjson/package.json'),
  ...plugin('proj/node_modules/dirjson', { name: 'dirjson-far' }),
  ...plugin('proj/node_modules/_underscore', { name: '_underscore' }),

  // A package.json above the working directory that names the package.
  file('selfref/package.json', manifest({ name: 'selfref', exports: { './package.json': './package.json' } })),
  file('selfref/src/plugin.ts', ''),
  ...plugin('selfref/node_modules/selfref', { name: 'selfref-in-nm' }),
  dir('selfref/a'),
  file('selfnoexp/package.json', '{"name":"selfnoexp"}'),
  ...plugin('selfnoexp/node_modules/selfnoexp', { name: 'selfnoexp-in-nm' }),
  dir('selfnoexp/a'),
];

/** Write `entries` below `root`, creating the directories above each. */
export function materialise(root: string, entries: readonly TreeEntry[] = tree): void {
  for (const entry of entries) {
    const target = path.join(root, entry.path);
    if (entry.kind === 'dir') {
      fs.mkdirSync(target, { recursive: true });
      continue;
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    if (entry.kind === 'symlink') fs.symlinkSync(entry.target ?? '', target);
    else fs.writeFileSync(target, entry.text ?? '');
  }
}
