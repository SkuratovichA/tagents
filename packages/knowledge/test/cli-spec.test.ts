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
import { KNOWLEDGE_COMMANDS, knowledgeCliContract } from '../src/cli/spec.ts';

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
  assert.ok(seen >= 5, `expected to find the parseArgs calls, found ${seen}`);
});

interface UsageVerb {
  path: string;
  positionals: string[];
  flags: string[];
}

/**
 * The verbs the usage text prints. Continuation lines (indented deeper than a verb line) belong to the verb above. Unlike the core CLI, no line here carries several verbs, so every line is one verb.
 */
function usageVerbs(usage: string): UsageVerb[] {
  const lines: string[] = [];
  for (const line of usage.split('\n')) {
    if (/^ {2}\S/.test(line)) lines.push(line.trim());
    else if (/^ {3,}\S/.test(line) && lines.length) lines[lines.length - 1] += ` ${line.trim()}`;
  }
  const segments: string[] = [];
  for (const line of lines) {
    segments.push(line);
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

// Flags the verbs accept but the usage text does not print (every read verb takes --dir and --db; the text lists them only where they were first needed). Pinned, so a new undocumented flag fails here instead of slipping in.
const UNDOCUMENTED: Record<string, string[]> = {
  search: ['--db', '--dir'],
  show: ['--db'],
  list: ['--db', '--dir'],
};

test('the specs and the English usage text name the same verbs, positionals and flags', () => {
  const fromUsage = new Map(usageVerbs(en.usage).map((v) => [v.path, v]));
  const fromSpec = new Map(KNOWLEDGE_COMMANDS.map((c) => [c.path.join(' '), c]));
  assert.deepEqual([...fromSpec.keys()].sort(), [...fromUsage.keys()].sort());
  for (const [key, spec] of fromSpec) {
    const verb = fromUsage.get(key);
    assert.ok(verb, key);
    assert.deepEqual(verb.positionals, [...spec.positionals], `${key}: positionals`);
    const specFlags = Object.keys(spec.options).map((o) => `--${o}`);
    // usage -> spec: every printed flag is a real option
    for (const f of verb.flags) assert.ok(specFlags.includes(f), `${key}: usage prints ${f}, the spec lacks it`);
    // spec -> usage: every option is printed, except the pinned ones
    const missing = specFlags.filter((f) => !verb.flags.includes(f)).sort();
    assert.deepEqual(missing, UNDOCUMENTED[key] ?? [], `${key}: flags the usage does not print`);
  }
});

test('a required option is a declared option', () => {
  for (const c of KNOWLEDGE_COMMANDS) {
    for (const r of c.required) assert.ok(r in c.options, `${c.path.join(' ')}: ${r}`);
  }
});

test('knowledgeCliContract lists every verb with a non-empty English summary', () => {
  const contract = knowledgeCliContract();
  assert.equal(contract.program, 'tagents-knowledge');
  assert.equal(contract.exit['notFound'], 4);
  assert.deepEqual(
    contract.commands.map((c) => c.path.join(' ')),
    ['index', 'search', 'show', 'list', 'lint', 'mcp', 'serve'],
  );
  for (const c of contract.commands) {
    assert.ok(c.summary.trim().length > 0, c.path.join(' '));
    assert.equal(c.summary, en[KNOWLEDGE_COMMANDS.find((s) => s.path.join(' ') === c.path.join(' '))?.summary ?? 'usage']);
  }
});

test('ru holds only keys that en holds, and no summary*: the contract is English', () => {
  const enKeys = new Set(Object.keys(en));
  for (const key of Object.keys(ru)) {
    assert.ok(enKeys.has(key), `${key} is in ru but not in en`);
    assert.ok(!key.startsWith('summary'), `${key} must not be translated`);
  }
});

test('knowledgeCliContract is English whatever the machine speaks', () => {
  const before = process.env['TAGENTS_LOCALE'];
  const english = knowledgeCliContract().commands.map((c) => c.summary);
  process.env['TAGENTS_LOCALE'] = 'ru';
  try {
    assert.deepEqual(knowledgeCliContract().commands.map((c) => c.summary), english, 'the summaries follow TAGENTS_LOCALE');
  } finally {
    if (before === undefined) delete process.env['TAGENTS_LOCALE'];
    else process.env['TAGENTS_LOCALE'] = before;
  }
});
