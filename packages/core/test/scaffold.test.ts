// node --test scaffold.test.ts
//
// `plugin new` writes the files `scaffoldFiles` builds, and the Rust binary writes the same bytes from the same template (spec/cli/scaffold/plugin.txt). This pins the bytes node writes for each triple of fixtures/scaffold/triples.ts, so that a change of the template or of the renderer fails here until the new bytes are chosen on purpose; tests/rust-plugin-vectors.mts records the same files for the Rust renderer.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { test } from 'node:test';
import { scaffoldFiles } from '../src/cli/scaffold.ts';
import { SCAFFOLD_TRIPLES } from './fixtures/scaffold/triples.ts';

const FILES = ['package.json', 'tsconfig.json', 'src/plugin.ts', 'test/plugin.test.ts', 'README.md'];

/** The first 16 hex digits of the SHA-256 of each file of each triple, in the order of `FILES`. */
const DIGESTS: Record<string, readonly string[]> = {
  "a sibling checkout": ['6329641443b1b908', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '6b761d995ce5b04c'],
  "a plugin next to the packages": ['47b3624b7e24617e', 'fca91f2014207dd3', 'bba78be9009a9d02', '8ed2fd24fde9e294', 'd9add2e9b363ad6d'],
  "a quote and a backslash in both directories": ['854129212670dbfe', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', 'a36000c59c8dd0f7'],
  "a specifier that starts with a dot gets no ./": ['c6e654b9a63b91b2', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '6b761d995ce5b04c'],
  "a specifier that starts with two dots gets no ./": ['c1230b943b80afe5', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '6b761d995ce5b04c'],
  "an empty relative path": ['da0c82d5d2b22424', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '6b761d995ce5b04c'],
  "core below the plugin": ['479b8e064c438c93', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '6b761d995ce5b04c'],
  "core is the root": ['f617b5474863da9d', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '6b761d995ce5b04c'],
  "the plugin is the root": ['479b8e064c438c93', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', 'f501fb3171953beb'],
  "a trailing slash on both": ['7698f91ff58e5e3e', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '9d580618ab4d9a52'],
  "a placeholder in a directory is printed as typed": ['403b3e5f34203f1a', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '3ed6049e6d321b20'],
  "a filter in a directory is printed as typed": ['0252a6c484c4b347', 'fca91f2014207dd3', '94b08badef8d9f30', 'bae47f25d81995d5', '3840883b1740d390'],
  "a space, a non-ASCII character and replacement patterns": ['5abd4a412ad6cac5', 'fca91f2014207dd3', '9a365a946f9bcd1c', 'bfae6e8bef622892', '1116521be8be056d'],
  "a name that is one digit": ['5f3ed30697439251', 'fca91f2014207dd3', '587b88dd39180031', 'fa7fdeb2eb842f38', 'ac2efb8d1e637f8e'],
};

const digest = (body: string): string => createHash('sha256').update(body).digest('hex').slice(0, 16);

test('the scaffold is five files, in this order', () => {
  for (const { name, dir, core } of SCAFFOLD_TRIPLES) {
    assert.deepEqual(scaffoldFiles(name, dir, core).map((file) => file.path), FILES);
  }
});

for (const { label, name, dir, core } of SCAFFOLD_TRIPLES) {
  test(`the bytes are pinned: ${label}`, () => {
    const got = scaffoldFiles(name, dir, core).map((file) => digest(file.body));
    assert.deepEqual(got, DIGESTS[label], `${label}: ${JSON.stringify(got)}`);
  });
}

test('package.json is JSON that names the plugin and links core by the relative specifier', () => {
  const link = (name: string, dir: string, core: string): unknown => {
    const body = scaffoldFiles(name, dir, core)[0]?.body ?? '';
    assert.ok(body.endsWith('}\n'));
    return JSON.parse(body);
  };
  const plain = link('demo', '/work/demo', '/work/packages/core') as { name: string; dependencies: Record<string, string> };
  assert.equal(plain.name, 'tagents-plugin-demo');
  assert.equal(plain.dependencies['@tagents/core'], 'link:../packages/core');
  // A quote and a backslash are escaped, not lost.
  const odd = link('demo', '/w/a"b\\c', '/w/q"r\\s/packages/core') as { dependencies: Record<string, string> };
  assert.equal(odd.dependencies['@tagents/core'], 'link:../q"r\\s/packages/core');
  // A specifier that starts with a dot is written as it is: relativeSpecifier adds ./ only to a path that does not start with one.
  assert.equal((link('demo', '/work/demo', '/work/demo/.hidden/core') as typeof plain).dependencies['@tagents/core'], 'link:.hidden/core');
  assert.equal((link('demo', '/work/demo', '/work/demo') as typeof plain).dependencies['@tagents/core'], 'link:.');
  assert.equal((link('demo', '/work/demo', '/work/demo/packages/core') as typeof plain).dependencies['@tagents/core'], 'link:./packages/core');
});

test('the README names the directory as typed, and a value is never read for a placeholder', () => {
  const readme = (dir: string): string => scaffoldFiles('demo', dir, '/work/packages/core')[4]?.body ?? '';
  assert.ok(readme('/work/{{name}}/$&').includes('tagents plugin add /work/{{name}}/$&       # writes it into'));
  assert.ok(readme('/work/demo').startsWith('# tagents-plugin-demo\n'));
});

test('the template starts with a file, and holds only the placeholders the renderer knows', () => {
  const text = fs.readFileSync(new URL('../../../spec/cli/scaffold/plugin.txt', import.meta.url), 'utf8');
  assert.ok(text.startsWith('@@ package.json\n'));
  assert.ok(text.endsWith('\n'));
  assert.deepEqual([...new Set(text.match(/\{\{[^}]*\}\}/g))].sort(), ['{{core|json}}', '{{dir}}', '{{name}}']);
});
