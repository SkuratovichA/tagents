// node --test cli-spec.test.ts
//
// The command specs in src/cli/spec.ts are what parseArgs reads and what the contract generator reads; the usage text in i18n/en.ts is still hand-written. This file keeps the three from drifting: no inline option tables, the spec and the usage agree on every verb and flag, and every verb has a summary.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { en } from '../src/i18n/en.ts';
import { ru } from '../src/i18n/ru.ts';
import { CORE_COMMANDS, coreCliContract } from '../src/cli/spec.ts';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI_DIR = path.resolve(HERE, '..', 'src', 'cli');

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
      'plugin list', 'plugin add', 'plugin remove', 'plugin new', 'doctor',
    ],
  );
  for (const c of contract.commands) {
    assert.ok(c.summary.trim().length > 0, c.path.join(' '));
    assert.equal(c.summary, en[CORE_COMMANDS.find((s) => s.path.join(' ') === c.path.join(' '))?.summary ?? 'usage']);
  }
});

test('en and ru hold the same keys', () => {
  assert.deepEqual(Object.keys(ru).sort(), Object.keys(en).sort());
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
