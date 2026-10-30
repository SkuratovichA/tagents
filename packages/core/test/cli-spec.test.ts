// node --test cli-spec.test.ts
//
// The command specs are spec/cli/tagents-core.json, read by src/cli/spec.ts: what parseArgs reads and what the contract generator reads; the usage text in i18n/en.ts is still hand-written. This file keeps the three from drifting: no inline option tables, the spec and the usage agree on every verb and flag, and every verb has a summary. The data file is also read by the Rust front door, so what it may contain is pinned here and in crates/tagents-spec.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { Ajv2020 } from 'ajv/dist/2020.js';
import { en } from '../src/i18n/en.ts';
import { ru } from '../src/i18n/ru.ts';
import { EXIT } from '../src/cli/exit.ts';
import { CORE_COMMANDS, EFFECTS, SPEC_FILE, coreCliContract, loadSpec } from '../src/cli/spec.ts';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI_DIR = path.resolve(HERE, '..', 'src', 'cli');
const SCHEMA_FILE = path.resolve(HERE, '..', '..', '..', 'spec', 'cli', 'cli-spec.schema.json');

/** The text of every `parseArgs(…)` call in a source, balanced on its parentheses. */
function parseArgsCalls(src: string): string[] {
  const calls: string[] = [];
  let from = src.indexOf('parseArgs(');
  while (from !== -1) {
    let depth = 0;
    let i = from + 'parseArgs'.length;
    for (; i < src.length; i++) {
      if (src[i] === '(') depth++;
      else if (src[i] === ')' && --depth === 0) break;
    }
    calls.push(src.slice(from, i + 1));
    from = src.indexOf('parseArgs(', i);
  }
  return calls;
}

test('no parseArgs call under src/cli carries an inline options literal', () => {
  let seen = 0;
  for (const file of fs.readdirSync(CLI_DIR).filter((f) => f.endsWith('.ts'))) {
    for (const call of parseArgsCalls(fs.readFileSync(path.join(CLI_DIR, file), 'utf8'))) {
      seen++;
      assert.doesNotMatch(call, /options:\s*\{/, `${file}: ${call.split('\n')[0]}`);
    }
  }
  assert.ok(seen >= 7, `expected to find the parseArgs calls, found ${seen}`);
});

interface UsageVerb {
  path: string;
  positionals: string[];
  flags: string[];
}

/**
 * The verbs the usage text prints. Continuation lines (indented deeper than a verb line) belong to the verb above. The `sessions` line carries three verbs separated by ` | `, so it is split there and each tail gets `sessions` back; every other line keeps its ` | ` (it separates `--config-dir D | --no-config-dir`). A line starting with `<` is a configured plugin's own verb: no spec.
 */
function usageVerbs(usage: string): UsageVerb[] {
  const lines: string[] = [];
  for (const line of usage.split('\n')) {
    if (/^ {2}\S/.test(line)) lines.push(line.trim());
    else if (/^ {3,}\S/.test(line) && lines.length) lines[lines.length - 1] += ` ${line.trim()}`;
  }
  const segments: string[] = [];
  for (const line of lines) {
    if (line.startsWith('<')) continue;
    if (line.startsWith('sessions ')) {
      const [first, ...rest] = line.split(' | ');
      segments.push(first ?? '', ...rest.map((r) => `sessions ${r}`));
    } else segments.push(line);
  }
  return segments.map((segment) => {
    const tokens = segment.split(/\s+/);
    const words = tokens.filter((t) => /^[a-z]+$/.test(t));
    // the path is the leading bare words; a later bare word is an option's value placeholder
    const pathWords: string[] = [];
    for (const token of tokens) {
      if (!/^[a-z]+$/.test(token)) break;
      pathWords.push(token);
    }
    assert.ok(words.length > 0, segment);
    return {
      path: pathWords.join(' '),
      positionals: tokens.filter((t) => /^[<[](?!--)/.test(t)),
      flags: [...segment.matchAll(/--[a-z-]+/g)].map((m) => m[0]),
    };
  });
}

test('the specs and the English usage text name the same verbs, positionals and flags', () => {
  const fromUsage = new Map(usageVerbs(en.usage).map((v) => [v.path, v]));
  const fromSpec = new Map(CORE_COMMANDS.map((c) => [c.path.join(' '), c]));
  assert.deepEqual([...fromSpec.keys()].sort(), [...fromUsage.keys()].sort());
  for (const [key, spec] of fromSpec) {
    const verb = fromUsage.get(key);
    assert.ok(verb, key);
    assert.deepEqual(verb.positionals, [...spec.positionals], `${key}: positionals`);
    assert.deepEqual(
      [...verb.flags].sort(),
      Object.keys(spec.options).map((o) => `--${o}`).sort(),
      `${key}: flags`,
    );
  }
});

test('a required option is a declared option', () => {
  for (const c of CORE_COMMANDS) {
    for (const r of c.required) assert.ok(r in c.options, `${c.path.join(' ')}: ${r}`);
  }
});

test('coreCliContract lists every verb with a non-empty English summary', () => {
  const contract = coreCliContract();
  assert.equal(contract.program, 'tagents-core');
  assert.equal(contract.exit['timeout'], 4);
  assert.deepEqual(
    contract.commands.map((c) => c.path.join(' ')),
    [
      'session open', 'session prompt', 'session last', 'session list', 'session abort',
      'sessions recent', 'sessions search', 'sessions show',
      'plugin list', 'plugin add', 'plugin remove', 'plugin new', 'config convert', 'doctor', 'mcp',
    ],
  );
  for (const c of contract.commands) {
    assert.ok(c.summary.trim().length > 0, c.path.join(' '));
    assert.equal(c.summary, en[CORE_COMMANDS.find((s) => s.path.join(' ') === c.path.join(' '))?.summary ?? 'usage']);
  }
});

test('ru holds only keys that en holds, and no summary*: the contract is English', () => {
  const enKeys = new Set(Object.keys(en));
  for (const key of Object.keys(ru)) {
    assert.ok(enKeys.has(key), `${key} is in ru but not in en`);
    assert.ok(!key.startsWith('summary'), `${key} must not be translated`);
  }
});

test('coreCliContract is English whatever the machine speaks', () => {
  const before = process.env['TAGENTS_LOCALE'];
  const english = coreCliContract().commands.map((c) => c.summary);
  process.env['TAGENTS_LOCALE'] = 'ru';
  try {
    assert.deepEqual(coreCliContract().commands.map((c) => c.summary), english, 'the summaries follow TAGENTS_LOCALE');
  } finally {
    if (before === undefined) delete process.env['TAGENTS_LOCALE'];
    else process.env['TAGENTS_LOCALE'] = before;
  }
});

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function readDoc(): Record<string, unknown> {
  const doc: unknown = JSON.parse(fs.readFileSync(SPEC_FILE, 'utf8'));
  assert.ok(isRecord(doc));
  return doc;
}

function commandsOf(doc: Record<string, unknown>): Record<string, unknown>[] {
  const commands = doc['commands'];
  assert.ok(Array.isArray(commands) && commands.every(isRecord));
  return commands;
}

/** A copy of the data file with `change` applied to the whole document, written where only this test looks. */
function specWith(change: (doc: Record<string, unknown>) => void): URL {
  const doc = readDoc();
  change(doc);
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'cli-spec-')), 'spec.json');
  fs.writeFileSync(file, JSON.stringify(doc));
  return pathToFileURL(file);
}

/** `specWith` for a change to the first command only. */
function specWithFirstCommand(change: (command: Record<string, unknown>) => void): URL {
  return specWith((doc) => {
    const [first] = commandsOf(doc);
    assert.ok(first);
    change(first);
  });
}

test('the exit codes the contract prints are the ones the CLI exits with', () => {
  assert.deepEqual(coreCliContract().exit, EXIT);
});

test('every verb says which program serves it, and a verb word is served by one program', () => {
  const byWord = new Map<string, Set<unknown>>();
  for (const command of commandsOf(readDoc())) {
    const { path: words, impl } = command;
    assert.ok(Array.isArray(words) && (impl === 'rust' || impl === 'node'), JSON.stringify(command));
    const word = String(words[0]);
    byWord.set(word, (byWord.get(word) ?? new Set()).add(impl));
  }
  for (const [word, impls] of byWord) assert.equal(impls.size, 1, `${word}: the group is split between ${[...impls].join(' and ')}`);
});

test('the loader keeps impl out of what parseArgs and the contract see, and refuses a key it does not know', () => {
  const before = loadSpec(SPEC_FILE).commands;
  const [first] = commandsOf(readDoc());
  assert.ok(first);
  const otherProgram = first['impl'] === 'rust' ? 'node' : 'rust';
  const withOtherImpl = loadSpec(specWithFirstCommand((command) => { command['impl'] = otherProgram; }));
  assert.deepEqual(withOtherImpl.commands, before);
  assert.ok(before.every((command) => !('impl' in command)));
  assert.throws(
    () => loadSpec(specWithFirstCommand((command) => { command['surprise'] = 'x'; })),
    /does not match spec\/cli\/cli-spec.schema.json/,
  );
  assert.throws(
    () => loadSpec(specWithFirstCommand((command) => { command['summary'] = 'noSuchKey'; })),
    /not a key of the English catalogue/,
  );
});

test('effect and tool reach the contract: every verb of the data file says what it does, and the ones kept out of the tools say so', () => {
  const contract = coreCliContract().commands;
  const verbs = commandsOf(readDoc());
  assert.equal(contract.length, verbs.length);
  for (const verb of verbs) {
    const words = Array.isArray(verb['path']) ? verb['path'].join(' ') : '';
    const entry = contract.find((c) => c.path.join(' ') === words);
    assert.ok(entry, words);
    assert.equal(typeof verb['effect'], 'string', `${words}: the data file gives no effect`);
    assert.equal(entry.effect, verb['effect'], words);
    assert.equal(entry.tool, verb['tool'], words);
    assert.equal(Object.hasOwn(entry, 'tool'), Object.hasOwn(verb, 'tool'), `${words}: tool is written exactly when the data file writes it`);
  }
  assert.ok(contract.some((c) => c.tool === false), 'no verb is kept out of the tools');
});

test('an effect and a tool written in a copy of the data file are what the loader returns', () => {
  const first = loadSpec(specWithFirstCommand((command) => { command['effect'] = 'serve'; command['tool'] = false; })).commands[0];
  assert.ok(first);
  assert.equal(first.effect, 'serve');
  assert.equal(first.tool, false);
  const bare = loadSpec(specWithFirstCommand((command) => { delete command['effect']; delete command['tool']; })).commands[0];
  assert.ok(bare);
  assert.equal(Object.hasOwn(bare, 'effect'), false);
  assert.equal(Object.hasOwn(bare, 'tool'), false);
});

// The values crates/tagents-spec refuses for these two keys (an_effect_nobody_declared_is_refused_like_the_schema_does, a_tool_that_is_not_false_is_refused_like_the_schema_does): the loader and the schema each refuse every one.
const BAD_EFFECTS: readonly unknown[] = ['writes', 'Read', '', 1, true, [], null];
const BAD_TOOLS: readonly unknown[] = [true, 'false', 0, [], null];

test('an effect is one of the five words, and anything else is refused by the loader and by the schema', () => {
  for (const effect of EFFECTS) {
    const change = (doc: Record<string, unknown>) => { for (const c of commandsOf(doc)) c['effect'] = effect; };
    assert.equal(loadSpec(specWith(change)).commands[0]?.effect, effect);
    const doc = readDoc();
    change(doc);
    assert.ok(schemaValidator()(doc), effect);
  }
  for (const bad of BAD_EFFECTS) {
    const change = (doc: Record<string, unknown>) => { for (const c of commandsOf(doc)) c['effect'] = bad; };
    assert.throws(() => loadSpec(specWith(change)), /does not match spec\/cli\/cli-spec.schema.json/, JSON.stringify(bad));
    const doc = readDoc();
    change(doc);
    assert.equal(schemaValidator()(doc), false, JSON.stringify(bad));
  }
});

test('tool is false or absent, and anything else is refused by the loader and by the schema', () => {
  const change = (doc: Record<string, unknown>) => { for (const c of commandsOf(doc)) c['tool'] = false; };
  assert.equal(loadSpec(specWith(change)).commands[0]?.tool, false);
  const accepted = readDoc();
  change(accepted);
  assert.ok(schemaValidator()(accepted));
  for (const bad of BAD_TOOLS) {
    const set = (doc: Record<string, unknown>) => { for (const c of commandsOf(doc)) c['tool'] = bad; };
    assert.throws(() => loadSpec(specWith(set)), /does not match spec\/cli\/cli-spec.schema.json/, JSON.stringify(bad));
    const doc = readDoc();
    set(doc);
    assert.equal(schemaValidator()(doc), false, JSON.stringify(bad));
  }
});

function schemaValidator() {
  const schema: unknown = JSON.parse(fs.readFileSync(SCHEMA_FILE, 'utf8'));
  assert.ok(isRecord(schema));
  return new Ajv2020({ strict: true, allErrors: true }).compile(schema);
}

test('the data file matches its schema', () => {
  const validate = schemaValidator();
  assert.ok(validate(readDoc()), JSON.stringify(validate.errors));
});

test('the schema refuses an unknown key, an empty path and an empty positional', () => {
  const validate = schemaValidator();
  const doc = readDoc();
  const [first] = commandsOf(doc);
  assert.ok(first);
  first['surprise'] = 'x';
  first['path'] = [];
  first['positionals'] = [''];
  assert.equal(validate(doc), false);
  const keywords = new Set((validate.errors ?? []).map((e) => `${e.instancePath}:${e.keyword}`));
  assert.ok(keywords.has('/commands/0:additionalProperties'), [...keywords].join(' '));
  assert.ok(keywords.has('/commands/0/path:minItems'), [...keywords].join(' '));
  assert.ok(keywords.has('/commands/0/positionals/0:minLength'), [...keywords].join(' '));
});

// The same seven mistakes crates/tagents-spec tests one by one: both loaders refuse each, and the schema states all but the last.
const REFUSALS: readonly [name: string, mutate: (doc: Record<string, unknown>) => void, schemaStatesIt: boolean][] = [
  ['an empty program', (doc) => { doc['program'] = ''; }, true],
  ['an empty summary', (doc) => { for (const c of commandsOf(doc)) c['summary'] = ''; }, true],
  ['an empty path', (doc) => { for (const c of commandsOf(doc)) c['path'] = []; }, true],
  ['an empty word in a path', (doc) => { for (const c of commandsOf(doc)) c['path'] = ['']; }, true],
  ['an empty positional', (doc) => { for (const c of commandsOf(doc)) c['positionals'] = ['']; }, true],
  ['an empty required name', (doc) => { for (const c of commandsOf(doc)) c['required'] = ['']; }, true],
  [
    'two verbs with one path',
    (doc) => {
      const commands = commandsOf(doc);
      const [first] = commands;
      assert.ok(first);
      commands.push({ ...first });
    },
    false,
  ],
];

for (const [name, mutate, schemaStatesIt] of REFUSALS) {
  test(`${name} is refused by the loader${schemaStatesIt ? ' and by the schema' : ', and the schema accepts it'}`, () => {
    assert.throws(() => loadSpec(specWith(mutate)));
    const doc = readDoc();
    mutate(doc);
    // The schema cannot state that no two verbs share a path (JSON Schema has no uniqueness over a property of array items), so only the loaders refuse that one.
    assert.equal(schemaValidator()(doc), !schemaStatesIt);
  });
}

test('two verbs with one path are refused: dispatch is by path and the second would never run', () => {
  const file = specWith((doc) => {
    const commands = commandsOf(doc);
    const [first] = commands;
    assert.ok(first);
    commands.push({ ...first });
  });
  assert.throws(() => loadSpec(file), /^Error: tagents-core: \S+ has two verbs with the path "\S.*" \(dispatch is by path, so the second would never run\)$/);
});
