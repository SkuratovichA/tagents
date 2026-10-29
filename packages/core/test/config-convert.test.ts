// `tagents config convert`: a YAML config turned into the TOML twin that tagents reads the same way.
//
// "The same way" is checked by the thing that matters, not by eye: both files are handed to the real `tagents --config` under /bin/bash (macOS's 3.2 when that is what the machine has) and the dumps are compared. The converter does the same itself before it prints a byte, so a conversion that would change what tagents reads is refused instead of offered.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { parse as parseToml } from 'smol-toml';
import { parse as parseYaml } from 'yaml';
import { convertYamlConfig, sameConfig, typeMismatch } from '../src/config-convert.ts';
import { tomlString } from '../src/config-file.ts';
import { tmpDir } from '../src/testkit.ts';
import { HERE, runCli } from './helpers.ts';

const REPO = path.resolve(HERE, '..', '..', '..');
const TAGENTS = path.join(REPO, 'tagents');
const EXAMPLE = path.join(REPO, 'tests', 'fixtures', 'config.example.yaml');

let tmp: string;
let n = 0;
before(() => {
  tmp = tmpDir('config-convert-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const plain = (value: unknown): unknown => JSON.parse(JSON.stringify(value));

/** A fresh directory holding the given files. */
const dirWith = (files: Record<string, string>): string => {
  const dir = path.join(tmp, `case-${n++}`);
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), body);
  return dir;
};

/** What tagents itself reads out of `file`: its own `--config` dump, on a scratch tmux server and no host overlay. */
function dump(file: string): { code: number | null; stdout: string; stderr: string } {
  const scratch = fs.mkdtempSync(path.join(tmp, 'dump-'));
  const r = spawnSync('/bin/bash', [TAGENTS, '--config'], {
    encoding: 'utf8',
    env: {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      HOME: scratch,
      TMUX_TMPDIR: scratch,
      TA_STATE_DIR: scratch,
      TA_HOST: 'no-such-host-for-the-dump',
      TA_CONFIG: file,
    },
  });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

const convert = (yamlText: string): ReturnType<typeof convertYamlConfig> => {
  const dir = dirWith({ 'config.yaml': yamlText });
  return convertYamlConfig(path.join(dir, 'config.yaml'), { tagents: TAGENTS });
};

// ------------------------------------------------------------ equivalence ---

test('the YAML example converts to a TOML file that tagents reads byte for byte the same', () => {
  const result = convertYamlConfig(EXAMPLE, { tagents: TAGENTS });
  assert.ok(result.ok, result.ok ? '' : result.problem);

  const toml = path.join(dirWith({ 'config.toml': result.toml }), 'config.toml');
  const fromYaml = dump(EXAMPLE);
  const fromToml = dump(toml);
  assert.equal(fromYaml.code, 0, fromYaml.stderr);
  assert.equal(fromToml.code, 0, fromToml.stderr);
  assert.ok(fromYaml.stdout.length > 0, 'the example has something in it');
  assert.equal(fromToml.stdout, fromYaml.stdout);
  assert.equal(fromToml.stderr, '');
});

test('the converted file means the same to a TOML library as the YAML does to a YAML one', () => {
  const result = convertYamlConfig(EXAMPLE, { tagents: TAGENTS });
  assert.ok(result.ok);
  // a YAML key with nothing after it is null there and an empty table here: the same "a name and nothing else"
  const emptyAsTable = (value: unknown): unknown => JSON.parse(JSON.stringify(value), (_key, v: unknown) => (v === null ? {} : v));
  assert.deepEqual(plain(parseToml(result.toml)), emptyAsTable(parseYaml(fs.readFileSync(EXAMPLE, 'utf8'))));
});

test('the output opens with the schema line, and says what it left behind', () => {
  const result = convert('usage:\n  workdays: true\n');
  assert.ok(result.ok);
  const [first, second] = result.toml.split('\n');
  assert.equal(first, '#:schema https://raw.githubusercontent.com/SkuratovichA/tagents/main/schemas/config.schema.json');
  assert.match(second ?? '', /^# Converted from config\.yaml by tagents config convert\. Comments are not carried over\.$/);
});

// ------------------------------------------------------------------ types ---

test('numbers and booleans keep their type, quoted ones stay strings, and an empty value is an empty table', () => {
  const result = convert(
    [
      'usage:',
      '  monthly_limit_usd: 850',
      '  ratio: 0.5',
      '  workdays: true',
      '  watch: "work"',
      '  quoted_number: "5"',
      'claude:',
      '  profiles:',
      '    work:',
      '',
    ].join('\n')
  );
  assert.ok(result.ok, result.ok ? '' : result.problem);
  const doc = plain(parseToml(result.toml)) as Record<string, Record<string, unknown>>;
  assert.deepEqual(doc['usage'], {
    monthly_limit_usd: 850,
    ratio: 0.5,
    workdays: true,
    watch: 'work',
    quoted_number: '5',
  });
  assert.deepEqual(plain(doc['claude']), { profiles: { work: {} } });
});

test('a list of strings becomes an array, a list of mappings becomes an array of tables', () => {
  const result = convert(
    [
      'claude:',
      '  args:',
      '    - --dangerously-skip-permissions',
      '    - --model',
      '    - "opus 4"',
      '  rules:',
      '    - dir: ~/git/a',
      '      profile: a',
      '    - session: b',
      '      profile: b',
      '',
    ].join('\n')
  );
  assert.ok(result.ok, result.ok ? '' : result.problem);
  assert.deepEqual(plain(parseToml(result.toml)), {
    claude: {
      args: ['--dangerously-skip-permissions', '--model', 'opus 4'],
      rules: [
        { dir: '~/git/a', profile: 'a' },
        { session: 'b', profile: 'b' },
      ],
    },
  });
});

test('a string with a quote or a backslash in it comes back as it was', () => {
  const result = convert('keys:\n  closed: "ctrl-\\"y\\""\n  other: \'back\\slash\'\n');
  assert.ok(result.ok, result.ok ? '' : result.problem);
  assert.deepEqual(plain(parseToml(result.toml)), { keys: { closed: 'ctrl-"y"', other: 'back\\slash' } });
});

test('a key that is not a bare TOML key is quoted, and tagents reads it as the YAML had it', () => {
  const result = convert('claude:\n  profiles:\n    my.work:\n      config_dir: ~/x\n');
  assert.ok(result.ok, result.ok ? '' : result.problem);
  assert.match(result.toml, /^\[claude\.profiles\."my\.work"\]$/m);
  assert.deepEqual(plain(parseToml(result.toml)), { claude: { profiles: { 'my.work': { config_dir: '~/x' } } } });
});

test('profiles keep their order whatever is in them, an empty one included', () => {
  const yaml = 'claude:\n  profiles:\n    work:\n    home:\n      config_dir: ~/h\n    spare:\n';
  const result = convert(yaml);
  assert.ok(result.ok, result.ok ? '' : result.problem);
  const toml = path.join(dirWith({ 'config.toml': result.toml }), 'config.toml');
  assert.equal(dump(toml).stdout, dump(path.join(dirWith({ 'config.yaml': yaml }), 'config.yaml')).stdout);
});

test('an empty file converts to a file with nothing in it', () => {
  const result = convert('');
  assert.ok(result.ok, result.ok ? '' : result.problem);
  assert.deepEqual(plain(parseToml(result.toml)), {});
});

// -------------------------------------------------------------- strings ---

test('a string tomlString writes is read back by tagents unchanged', () => {
  const values = ['plain', 'Привет, мир', 'back\\slash', 'say "hi"', 'a # not a comment', 'a = b', '[x]', '  padded  ', "it's", 'a\\"b'];
  for (const value of values) {
    const written = tomlString(value);
    assert.notEqual(written, null, value);
    const file = path.join(dirWith({ 'config.toml': `k = ${written}\n` }), 'config.toml');
    const r = dump(file);
    assert.equal(r.stderr, '', value);
    assert.equal(r.stdout, `k\t${value}\n`, value);
  }
});

test('a string the dashboard could not read back is not written', () => {
  for (const value of ['a\tb', 'a\u007fb', 'a\u0001b', 'a\nb', 'a\ud800b']) assert.equal(tomlString(value), null, JSON.stringify(value));
  assert.equal(tomlString('\ud83d\ude00'), '"\ud83d\ude00"', 'a surrogate pair is a character, not a lone surrogate');
});

// ---------------------------------------------------------------- ordering ---

test('a plain key that comes after a table in the YAML moves above it, and the reading is still the same', () => {
  const yaml = 'claude:\n  profiles:\n    work:\n      config_dir: ~/w\n  args: --x\nusage:\n  workdays: true\n';
  const result = convert(yaml);
  assert.ok(result.ok, result.ok ? '' : result.problem);
  assert.ok(result.toml.indexOf('args = "--x"') < result.toml.indexOf('[claude.profiles.work]'));
  const toml = path.join(dirWith({ 'config.toml': result.toml }), 'config.toml');
  const lines = (text: string): string[] => text.split('\n').sort();
  assert.deepEqual(lines(dump(toml).stdout), lines(dump(path.join(dirWith({ 'config.yaml': yaml }), 'config.yaml')).stdout));
});

test('two dumps that differ in the order of the profiles are not the same reading', () => {
  const a = 'claude.profiles.work.config_dir\t~/w\nclaude.profiles.home.config_dir\t~/h\n';
  const b = 'claude.profiles.home.config_dir\t~/h\nclaude.profiles.work.config_dir\t~/w\n';
  assert.equal(sameConfig(a, a), true);
  assert.equal(sameConfig(a, b), false);
  const leafLast = 'claude.profiles.work\t\nclaude.args\tx\n';
  const leafFirst = 'claude.args\tx\nclaude.profiles.work\t\n';
  assert.equal(sameConfig(leafLast, leafFirst), true, 'a plain key and a table may swap places');
  assert.equal(sameConfig(a, `${a}claude.args\tx\n`), false, 'a line more is a different reading');
});

// ---------------------------------------------------------------- refusals ---

test('a YAML construct with no TOML twin is refused, naming the line', () => {
  const cases: Array<[string, RegExp]> = [
    ['base: &b\n  a: 1\nother: *b\n', /config\.yaml:3: .*alias/i],
    ['usage:\n  workdays: !!str true\n', /config\.yaml:2: .*tag/i],
    ['notes:\n  text: |\n    two\n    lines\n', /config\.yaml:2: .*line break/i],
    ['claude:\n  args:\n    - a\n    - b: 1\n', /config\.yaml:3: .*mix/i],
    ['- a\n- b\n', /config\.yaml:1: .*mapping/i],
  ];
  for (const [yaml, expected] of cases) {
    const result = convert(yaml);
    assert.equal(result.ok, false, yaml);
    assert.match(result.ok ? '' : result.problem, expected, yaml);
  }
});

test('a number, boolean or null with no TOML twin is refused with its line, never turned into a string', () => {
  const refused: Array<[string, RegExp]> = [
    ['0644', /number/], ['.5', /number/], ['5.', /number/], ['1e3', /number/], ['0x10', /number/], ['0o7', /number/], ['+1', /number/], ['.inf', /number/],
    ['True', /boolean/], ['TRUE', /boolean/], ['~', /null/], ['null', /null/],
  ];
  for (const [raw, why] of refused) {
    const result = convert(`usage:\n  value: ${raw}\n`);
    assert.equal(result.ok, false, raw);
    const problem = result.ok ? '' : result.problem;
    assert.match(problem, /config\.yaml:2: /, raw);
    assert.match(problem, why, raw);
    assert.match(problem, /quote it|write/, raw);
  }
  const inList = convert('claude:\n  args:\n    - a\n    - 0x10\n');
  assert.match(inList.ok ? '' : inList.problem, /config\.yaml:4: /);
});

test('a scalar that TOML writes the same way keeps its type', () => {
  const accepted = ['850', '-3', '0', '1.5', 'true', 'false', '"0644"', "'850'", 'plain text'];
  for (const raw of accepted) {
    const yaml = `usage:\n  value: ${raw}\n`;
    const result = convert(yaml);
    assert.ok(result.ok, `${raw}: ${result.ok ? '' : result.problem}`);
    const back = plain(parseToml(result.toml));
    assert.deepEqual(back, plain(parseYaml(yaml)), raw);
  }
});

test('the type check refuses a pair the dumps cannot tell apart', () => {
  const dump = 'usage.value\t850\n';
  assert.equal(sameConfig(dump, dump), true, 'tagents prints both as 850');
  assert.match(typeMismatch('usage:\n  value: 850\n', 'usage = { value = "850" }\n') ?? '', /usage\.value is number 850 in the YAML and "850" in the TOML/);
  assert.match(typeMismatch('usage:\n  value: true\n', 'usage = { value = "true" }\n') ?? '', /boolean true/);
  assert.match(typeMismatch('usage:\n  value: x\n', 'usage = {}\n') ?? '', /not there/);
  assert.equal(typeMismatch('usage:\n  value: 850\n  list: [1, a]\n  empty:\n', 'empty = {}\n[usage]\nvalue = 850\nlist = [1, "a"]\n'), null);
});

test('a tab or another control character inside a YAML string is refused, naming the line', () => {
  for (const yaml of ['usage:\n  note: "a\\tb"\n', 'usage:\n  note: "a\\u0001b"\n']) {
    const result = convert(yaml);
    assert.equal(result.ok, false, yaml);
    assert.match(result.ok ? '' : result.problem, /config\.yaml:2: .*control character/, yaml);
  }
});

test('YAML that does not parse is refused with the parser’s own message', () => {
  const result = convert('claude:\n  args: [unclosed\n');
  assert.equal(result.ok, false);
  assert.match(result.ok ? '' : result.problem, /config\.yaml/);
});

test('a tagents that never finishes is a refusal that names the timeout, not a hang', () => {
  const dir = dirWith({ 'config.yaml': 'usage:\n  workdays: true\n', 'stuck.sh': 'exec sleep 5\n' });
  const started = Date.now();
  const result = convertYamlConfig(path.join(dir, 'config.yaml'), { tagents: path.join(dir, 'stuck.sh'), timeoutMs: 200 });
  assert.ok(Date.now() - started < 2000, 'the refusal arrives within about a second');
  assert.equal(result.ok, false);
  assert.match(result.ok ? '' : result.problem, /did not finish within 0\.2 seconds/);
});

test('a YAML file tagents itself cannot read is refused before anything is converted', () => {
  // The bash reader takes a block-style subset. A flow mapping with a nested flow list is outside it, so the dump of this file is not what the YAML says.
  const result = convert('keys: { closed: [a, b] }\n');
  assert.equal(result.ok, false);
});

// --------------------------------------------------------------------- CLI ---

const inDir = (dir: string): Record<string, string> => ({ TAGENTS_CONFIG_DIR: dir, TA_HOST: 'no-such-host-for-the-dump' });

test('config convert prints the TOML and changes nothing', () => {
  const dir = dirWith({ 'config.yaml': 'usage:\n  workdays: true\n' });
  const r = runCli(['config', 'convert'], inDir(dir));
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^#:schema /);
  assert.deepEqual(plain(parseToml(r.stdout)), { usage: { workdays: true } });
  assert.match(r.stderr, /comments are not carried over/i);
  assert.deepEqual(fs.readdirSync(dir), ['config.yaml']);
  assert.equal(fs.readFileSync(path.join(dir, 'config.yaml'), 'utf8'), 'usage:\n  workdays: true\n');
});

test('config convert FILE converts that file, wherever it is', () => {
  const dir = dirWith({ 'other.yaml': 'notes:\n  send: paste\n' });
  const r = runCli(['config', 'convert', path.join(dir, 'other.yaml')], { TAGENTS_CONFIG_DIR: path.join(dir, 'nowhere') });
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(plain(parseToml(r.stdout)), { notes: { send: 'paste' } });
});

test('--write creates the .toml beside the YAML and leaves the YAML alone', () => {
  const yaml = 'usage:\n  workdays: true   # keep\n';
  const dir = dirWith({ 'config.yaml': yaml });
  const r = runCli(['config', 'convert', '--write'], inDir(dir));
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /wrote .*config\.toml/);
  assert.match(r.stdout, /config\.yaml is still there/);
  assert.deepEqual(plain(parseToml(fs.readFileSync(path.join(dir, 'config.toml'), 'utf8'))), { usage: { workdays: true } });
  assert.equal(fs.readFileSync(path.join(dir, 'config.yaml'), 'utf8'), yaml);
});

test('--write never overwrites a config.toml that is already there', () => {
  const dir = dirWith({ 'config.yaml': 'usage:\n  workdays: true\n', 'config.toml': '# mine\n' });
  const r = runCli(['config', 'convert', '--write'], inDir(dir));
  assert.equal(r.code, 3);
  assert.match(r.stderr, /config\.toml already exists/);
  assert.equal(fs.readFileSync(path.join(dir, 'config.toml'), 'utf8'), '# mine\n');
});

test('--write that loses a race for the second target removes the first and leaves the other file alone', () => {
  const dir = dirWith({ 'config.yaml': 'usage:\n  workdays: true\n', 'config.studio.yaml': 'notes:\n  send: paste\n' });
  // A dangling symlink is not "there" to the up-front check, but `wx` refuses it with EEXIST.
  const theirs = path.join(dir, 'config.studio.toml');
  fs.symlinkSync(path.join(dir, 'nowhere'), theirs);
  const r = runCli(['config', 'convert', '--all', '--write'], inDir(dir));
  assert.equal(r.code, 1);
  assert.match(r.stderr, /could not write .*config\.studio\.toml/);
  assert.ok(!fs.existsSync(path.join(dir, 'config.toml')), 'the first target is rolled back');
  assert.ok(fs.lstatSync(theirs).isSymbolicLink(), 'the file that was already there stays');
});

test('--write gives the TOML the permission bits of the YAML it came from', () => {
  const dir = dirWith({ 'config.yaml': 'usage:\n  workdays: true\n' });
  fs.chmodSync(path.join(dir, 'config.yaml'), 0o600);
  const r = runCli(['config', 'convert', '--write'], inDir(dir));
  assert.equal(r.code, 0, r.stderr);
  assert.equal(fs.statSync(path.join(dir, 'config.toml')).mode & 0o777, 0o600);
});

test('--all converts the per-host overlays too, and --write is all or nothing', () => {
  const dir = dirWith({
    'config.yaml': 'usage:\n  workdays: true\n',
    'config.studio.yaml': 'claude:\n  profiles:\n    studio:\n      config_dir: ~/s\n',
    'config.laptop.yaml': 'notes:\n  send: paste\n',
    'config.laptop.toml': '# mine\n',
  });
  const refused = runCli(['config', 'convert', '--all', '--write'], inDir(dir));
  assert.equal(refused.code, 3);
  assert.match(refused.stderr, /config\.laptop\.toml already exists/);
  assert.ok(!fs.existsSync(path.join(dir, 'config.toml')), 'one refusal stops every write');
  assert.ok(!fs.existsSync(path.join(dir, 'config.studio.toml')));

  fs.rmSync(path.join(dir, 'config.laptop.toml'));
  const r = runCli(['config', 'convert', '--all', '--write'], inDir(dir));
  assert.equal(r.code, 0, r.stderr);
  for (const name of ['config.toml', 'config.studio.toml', 'config.laptop.toml']) {
    assert.ok(fs.existsSync(path.join(dir, name)), name);
  }
  assert.deepEqual(
    plain(parseToml(fs.readFileSync(path.join(dir, 'config.studio.toml'), 'utf8'))),
    { claude: { profiles: { studio: { config_dir: '~/s' } } } }
  );
});

test('--all without --write prints each file under a line that names it', () => {
  const dir = dirWith({ 'config.yaml': 'usage:\n  workdays: true\n', 'config.studio.yaml': 'notes:\n  send: paste\n' });
  const r = runCli(['config', 'convert', '--all'], inDir(dir));
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^# ==== .*config\.toml ====$/m);
  assert.match(r.stdout, /^# ==== .*config\.studio\.toml ====$/m);
  assert.deepEqual(fs.readdirSync(dir).sort(), ['config.studio.yaml', 'config.yaml']);
});

test('a conversion that cannot be done writes nothing and says why', () => {
  const dir = dirWith({ 'config.yaml': 'base: &b\n  a: 1\nother: *b\n' });
  const r = runCli(['config', 'convert', '--write'], inDir(dir));
  assert.equal(r.code, 3);
  assert.match(r.stderr, /config\.yaml:3: .*alias/i);
  assert.deepEqual(fs.readdirSync(dir), ['config.yaml']);
});

test('no config.yaml to convert is an error that names where it looked', () => {
  const dir = dirWith({});
  const r = runCli(['config', 'convert'], inDir(dir));
  assert.equal(r.code, 1);
  assert.match(r.stderr, new RegExp(`no config\\.yaml in ${dir.replace(/[/\\.]/g, '\\$&')}`));
});

test('an unknown option is a usage error', () => {
  assert.equal(runCli(['config', 'convert', '--nope'], inDir(dirWith({}))).code, 2);
  assert.equal(runCli(['config', 'frobnicate'], inDir(dirWith({}))).code, 2);
});
