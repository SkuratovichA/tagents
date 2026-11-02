// The `(name, dir, core)` triples the scaffold is pinned on: `test/scaffold.test.ts` pins node's bytes for each, and `tests/rust-plugin-vectors.mts` records them for the Rust renderer. A triple is a plugin name, the directory it is written to and the core package it links to, all absolute and POSIX.
export interface ScaffoldTriple {
  readonly label: string;
  readonly name: string;
  readonly dir: string;
  readonly core: string;
}

export const SCAFFOLD_TRIPLES: readonly ScaffoldTriple[] = [
  { label: 'a sibling checkout', name: 'demo', dir: '/work/demo', core: '/opt/tagents/packages/core' },
  { label: 'a plugin next to the packages', name: 'x', dir: '/repo/plugins/x', core: '/repo/packages/core' },
  { label: 'a quote and a backslash in both directories', name: 'demo', dir: '/w/a"b\\c', core: '/w/q"r\\s/packages/core' },
  { label: 'a specifier that starts with a dot gets no ./', name: 'demo', dir: '/work/demo', core: '/work/demo/.hidden/core' },
  { label: 'a specifier that starts with two dots gets no ./', name: 'demo', dir: '/work/demo', core: '/work/demo/..odd' },
  { label: 'an empty relative path', name: 'demo', dir: '/work/demo', core: '/work/demo' },
  { label: 'core below the plugin', name: 'demo', dir: '/work/demo', core: '/work/demo/packages/core' },
  { label: 'core is the root', name: 'demo', dir: '/work/demo', core: '/' },
  { label: 'the plugin is the root', name: 'demo', dir: '/', core: '/packages/core' },
  { label: 'a trailing slash on both', name: 'demo', dir: '/work/demo/', core: '/work/packages/core/' },
  { label: 'a placeholder in a directory is printed as typed', name: 'demo', dir: '/work/{{name}}/{{core}}', core: '/work/{{dir}}/packages/core' },
  { label: 'a filter in a directory is printed as typed', name: 'demo', dir: '/work/{{core|json}}', core: '/work/{{name}}/core' },
  { label: 'a space, a non-ASCII character and replacement patterns', name: 'a.b-c_d', dir: '/work/é 😀 $& $1/x y', core: '/work/packages/core' },
  { label: 'a name that is one digit', name: '0', dir: '/work/0', core: '/work/packages/core' },
];
