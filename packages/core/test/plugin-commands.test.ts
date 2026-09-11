// `tagents-core <plugin> <command> [args]` — a configured plugin's own verbs,
// run as the program.
//
// Hermetic, like the rest: every case points TAGENTS_CONFIG_DIR at a temp
// directory holding a config.yaml this file wrote, so the owner's real
// ~/.config/tagents is never read and none of its plugins ever runs here. The
// plugin under test is test/fixtures/plugin/good, whose definition calls itself
// `fixture` while the key in the config is free to be anything — both spellings
// have to reach the same commands.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { parseArgv, takesPositionals } from '../src/cli/plugin-run.ts';
import { tmpDir } from '../src/testkit.ts';
import { z } from 'zod';
import { FIXTURES, runCli } from './helpers.ts';

const PLUGINS = path.join(FIXTURES, 'plugin');
const GOOD = path.join(PLUGINS, 'good');
const MISSING_ENTRY = path.join(PLUGINS, 'missing-entry');

let tmp: string;
let seq = 0;

/** A config dir whose config.yaml lists `key: from` for each pair given. */
function configDir(entries: ReadonlyArray<readonly [string, string]>): string {
  const dir = path.join(tmp, `cfg-${++seq}`);
  fs.mkdirSync(dir, { recursive: true });
  const body = ['plugins:', ...entries.map(([name, from]) => `  ${name}:\n    from: ${from}`), ''].join('\n');
  fs.writeFileSync(path.join(dir, 'config.yaml'), body);
  return dir;
}

const inDir = (dir: string): Record<string, string> => ({ TAGENTS_CONFIG_DIR: dir });

/** The fixture under its config key; `fixture` is the name it gives itself. */
const installed = (): Record<string, string> => inDir(configDir([['demo', GOOD]]));

before(() => {
  tmp = tmpDir('plugin-commands-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// -------------------------------------------------------------- running it ---

test('a plugin command runs, under the config key and under the plugin’s own name', () => {
  const env = installed();
  const byKey = runCli(['demo', 'greet', '--name', 'Sasha', '--times', '2'], env);
  assert.equal(byKey.code, 0);
  assert.equal(byKey.stdout, '', 'stdout belongs to the JSON verbs; a plugin logs to stderr');
  assert.equal(byKey.stderr, 'hello Sasha\nhello Sasha\n');

  const byName = runCli(['fixture', 'greet', '--name', 'Sasha'], env);
  assert.equal(byName.code, 0);
  assert.equal(byName.stderr, 'hello Sasha\n', 'the default of --times is the schema’s, not the CLI’s');
});

test('--key=value, and a flag with no value, are the same parser', () => {
  const env = installed();
  assert.equal(runCli(['demo', 'greet', '--name=Sasha', '--times=3'], env).stderr, 'hello Sasha\n'.repeat(3));
  assert.equal(runCli(['demo', 'echo', '--text', 'out loud'], env).stderr, 'out loud\n');
});

test('the exit code is the number the command returned', () => {
  const env = installed();
  assert.equal(runCli(['demo', 'exits', '--code', '0'], env).code, 0);
  assert.equal(runCli(['demo', 'exits', '--code', '7'], env).code, 7);
});

test('a command that throws is one line on stderr and exit 1', () => {
  const r = runCli(['demo', 'boom'], installed());
  assert.equal(r.code, 1);
  assert.equal(r.stdout, '');
  assert.equal(r.stderr, 'the fixture exploded\n');
});

// ------------------------------------------------------------- the schema ---

test('a schema the arguments do not satisfy is a usage error listing the issues', () => {
  const missing = runCli(['demo', 'greet'], installed());
  assert.equal(missing.code, 2);
  assert.equal(missing.stdout, '');
  assert.match(missing.stderr, /^name: /m);

  const notANumber = runCli(['demo', 'greet', '--name', 'Sasha', '--times', 'often'], installed());
  assert.equal(notANumber.code, 2);
  assert.match(notANumber.stderr, /^times: /m);
  assert.equal(notANumber.stderr.trimEnd().split('\n').length, 1, 'one line per issue');
});

test('positionals reach a command that declares `_`, and are refused by one that does not', () => {
  const env = installed();
  const joined = runCli(['demo', 'join', 'a', 'b', 'c'], env);
  assert.equal(joined.code, 0);
  assert.equal(joined.stderr, 'a+b+c\n');

  const stray = runCli(['demo', 'echo', '--text', 'hi', 'and', 'more'], env);
  assert.equal(stray.code, 2);
  assert.match(stray.stderr, /demo echo takes no positional arguments: and more/);
});

// --------------------------------------------------------------- listings ---

test('no command, and an unknown one, list what the plugin offers and exit 2', () => {
  const env = installed();
  const bare = runCli(['demo'], env);
  assert.equal(bare.code, 2);
  assert.equal(bare.stdout, '');
  assert.match(bare.stderr, /^commands of demo:\n/);
  assert.match(bare.stderr, /^ {2}greet — greet somebody a number of times$/m);
  assert.ok(!bare.stderr.includes('unknown command'), 'asking for the list is not an error about a word');

  const unknown = runCli(['demo', 'nope'], env);
  assert.equal(unknown.code, 2);
  assert.match(unknown.stderr, /unknown command: demo nope/);
  assert.match(unknown.stderr, /^ {2}echo — print what it was given$/m);
});

// -------------------------------------------------------- what stays core ---

test('a word no configured plugin answers to is the unknown command it always was', () => {
  const r = runCli(['telegram', 'status'], installed());
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown command: telegram/);
  assert.match(r.stderr, /usage: tagents-core/);
});

test('a core verb wins over a plugin that took its name', () => {
  const env = inDir(configDir([['doctor', GOOD]]));
  const r = runCli(['doctor'], env);
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^node v/, 'doctor is doctor, whatever is installed');
  assert.equal(r.stderr, '');
});

test('the usage names the plugin line and the reserved words', () => {
  const r = runCli(['help'], installed());
  assert.equal(r.code, 0);
  assert.match(r.stdout, /^ {2}<plugin> <command> \[args]/m);
  assert.match(r.stdout, /^reserved: session · sessions · plugin · doctor · help/m);
});

// ------------------------------------------------------------ the broken ---

test('a plugin that cannot be loaded says why, and exits 1', () => {
  const r = runCli(['broken', 'anything'], inDir(configDir([['broken', MISSING_ENTRY]])));
  assert.equal(r.code, 1);
  assert.equal(r.stdout, '');
  assert.match(r.stderr, /^broken: /);
  assert.ok(!r.stderr.includes('unknown command'), 'an import error is the news, not a typo');
});

test('one broken plugin does not take the working ones with it', () => {
  const env = inDir(
    configDir([
      ['broken', MISSING_ENTRY],
      ['demo', GOOD],
    ])
  );
  const r = runCli(['demo', 'echo', '--text', 'still here'], env);
  assert.equal(r.code, 0);
  assert.equal(r.stderr, 'still here\n');
});

// ------------------------------------------------------------- the parser ---

test('the parser: --key value, --key=value, --flag, -- ends the options', () => {
  const parsed = parseArgv(['--name', 'Sasha', '--times=2', '--loud', '--code', '-1', 'one', '--', '--two']);
  assert.ok(parsed.ok);
  assert.deepEqual(parsed.value.flags, { name: 'Sasha', times: '2', loud: true, code: '-1' });
  assert.deepEqual(parsed.value.positionals, ['one', '--two']);

  const trailing = parseArgv(['--verbose']);
  assert.ok(trailing.ok);
  assert.deepEqual(trailing.value.flags, { verbose: true });

  const nameless = parseArgv(['--=x']);
  assert.equal(nameless.ok, false);
});

test('only a schema that declares `_` is handed the positionals', () => {
  assert.equal(takesPositionals(z.object({ _: z.array(z.string()) })), true);
  assert.equal(takesPositionals(z.object({ text: z.string() })), false);
  assert.equal(takesPositionals(z.string()), false);
});
