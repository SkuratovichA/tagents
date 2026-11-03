// The tools section of the knowledge vectors: where the folder, the index and the usage store come from, and what the tools do when a folder changes between two calls.
//
// Each scenario runs the node MCP server in this process, under the fixed clock, over an environment the scenario writes. A path is written `<dir>` for the scratch directory, in what goes in and in what comes out, so a run in another directory writes the same bytes. `os.homedir()` and `path.resolve` read the process's own `HOME` and working directory and not the environment the server is given, so a scenario sets both for its run.
import fs from 'node:fs';
import path from 'node:path';
import { connect, relativize, scratch, writeFiles, outcomeOf, type CorpusFile } from './util.mts';

const MTIME_SEC = 1_700_000_000;

const doc = (title: string, body: string): string => `---\ntype: Note\ntitle: ${title}\n---\n${body}`;

const ALPHA: CorpusFile = { name: 'alpha.md', text: doc('Alpha', '## One\nalpha first section\n') };
const BETA: CorpusFile = { name: 'beta.md', text: doc('Beta', '## Two\nbeta second section\n') };

type Call = readonly [tool: string, args: Record<string, unknown>];

type Step =
  | { readonly call: Call }
  | { readonly write: { readonly name: string; readonly text: string; readonly mtimeSec: number } }
  | { readonly remove: string }
  /** The sorted names in a directory of the scenario: `cwd`, `config` or `db`. */
  | { readonly ls: 'cwd' | 'config' | 'db' };

interface Scenario {
  readonly name: string;
  /** Written at `<dir>/<folder>`, when the scenario has files. */
  readonly folder?: string;
  readonly files?: readonly CorpusFile[];
  /** The text of `<dir>/config/config.toml`. */
  readonly config?: string;
  /** Names of the environment: `HOME` and `TAGENTS_CONFIG_DIR` are set unless the scenario says otherwise, and a null value leaves the name out. */
  readonly env?: Readonly<Record<string, string | null>>;
  /** Files to write that are not documents: a path under `<dir>` and its text. */
  readonly extra?: Readonly<Record<string, string>>;
  readonly steps: readonly Step[];
}

const FOUR: readonly Step[] = [
  { call: ['knowledge_search', { query: 'alpha' }] },
  { call: ['knowledge_get', { id: 'alpha' }] },
  { call: ['knowledge_list', {}] },
  { call: ['knowledge_usage', {}] },
];

const LIST: readonly Step[] = [{ call: ['knowledge_list', {}] }];

/** A config with `text`, a folder `docs` beside it, and a list call: what the config says about the folder. */
function configured(name: string, text: string, folder = 'config/docs'): Scenario {
  return { name, folder, files: [ALPHA], config: text, steps: LIST };
}

const SCENARIOS: readonly Scenario[] = [
  { name: 'no folder is named', steps: FOUR },
  { name: 'the folder is not there', env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/nowhere' }, steps: FOUR },
  { name: 'the folder is a file', env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/a-file' }, extra: { 'a-file': 'x' }, steps: FOUR },
  { name: 'a blank variable names nothing', env: { TAGENTS_KNOWLEDGE_DIR: ' \t' }, steps: LIST },
  { name: 'a byte order mark is blank', env: { TAGENTS_KNOWLEDGE_DIR: '﻿' }, steps: LIST },
  configured('the config names a folder beside it', '[knowledge]\ndir = "docs"\n'),
  configured('the config names a folder under the home', '[knowledge]\ndir = "~/notes"\n', 'notes'),
  configured('the config names the home', '[knowledge]\ndir = "~"\n', '.'),
  configured('the config names an absolute folder', '[knowledge]\ndir = "<dir>/abs"\n', 'abs'),
  configured('the config says more than the folder', '[other]\nx = 1\n[knowledge]\nmode = "x"\ndir = "docs"\n[plugins.p]\nfrom = "x"\n'),
  configured('the config names the folder with a dotted key', 'knowledge.dir = "docs"\n'),
  configured('an empty folder name is none', '[knowledge]\ndir = ""\n'),
  configured('a folder name that is not a string is none', '[knowledge]\ndir = 5\n'),
  configured('a folder name that is a list is none', '[knowledge]\ndir = ["docs"]\n'),
  configured('a knowledge that is not a table is none', 'knowledge = "docs"\n'),
  configured('a knowledge that is a list is none', 'knowledge = []\n'),
  configured('a knowledge without a folder is none', '[knowledge]\nother = "docs"\n'),
  configured('a config that is not TOML is none', '[knowledge\ndir = "docs"\n'),
  configured('an integer beyond the safe range makes the whole config none', 'big = 9007199254740993\n[knowledge]\ndir = "docs"\n'),
  configured('a safe integer is fine', 'big = 9007199254740991\n[knowledge]\ndir = "docs"\n'),
  configured('a duplicate key is none', '[knowledge]\ndir = "docs"\ndir = "docs"\n'),
  configured('a config that starts with a byte order mark', '\uFEFF[knowledge]\ndir = "docs"\n'),
  {
    name: 'the variable wins over the config',
    folder: 'env-docs',
    files: [BETA],
    config: '[knowledge]\ndir = "docs"\n',
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/env-docs' },
    steps: LIST,
  },
  {
    name: 'a variable with a tilde',
    folder: 'under-home',
    files: [BETA],
    env: { TAGENTS_KNOWLEDGE_DIR: '~/under-home' },
    steps: LIST,
  },
  {
    name: 'a variable that is relative to the working directory',
    folder: 'cwd/rel-docs',
    files: [BETA],
    env: { TAGENTS_KNOWLEDGE_DIR: 'rel-docs' },
    steps: [...LIST, { ls: 'cwd' }],
  },
  {
    name: 'a document edited between two calls is read at the second',
    folder: 'docs',
    files: [ALPHA, BETA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs' },
    steps: [
      { call: ['knowledge_search', { query: 'alpha' }] },
      { call: ['knowledge_get', { id: 'alpha', heading: 'One' }] },
      { write: { name: 'alpha.md', text: doc('Alpha', '## One\nalpha edited section\n\n## Added\nalpha new heading\n'), mtimeSec: MTIME_SEC + 10 } },
      { call: ['knowledge_search', { query: 'alpha' }] },
      { call: ['knowledge_get', { id: 'alpha' }] },
      { call: ['knowledge_get', { id: 'alpha', heading: 'Added' }] },
      { write: { name: 'gamma.md', text: doc('Gamma', '## Three\nalpha gamma shared word\n'), mtimeSec: MTIME_SEC + 20 } },
      { call: ['knowledge_list', {}] },
      { call: ['knowledge_search', { query: 'gamma' }] },
      { remove: 'beta.md' },
      { call: ['knowledge_list', {}] },
      { call: ['knowledge_get', { id: 'beta' }] },
      { write: { name: 'beta.md', text: doc('Beta again', '## Two\nbeta is back\n'), mtimeSec: MTIME_SEC + 30 } },
      { call: ['knowledge_get', { id: 'beta' }] },
      { call: ['knowledge_usage', {}] },
    ],
  },
  {
    name: 'a path that starts with file: is a path',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs', TAGENTS_KNOWLEDGE_DB: 'file:rel.db' },
    steps: [{ call: ['knowledge_search', { query: 'alpha' }] }, { ls: 'cwd' }],
  },
  {
    name: 'the index and the store with a tilde and a relative path',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs', TAGENTS_KNOWLEDGE_DB: '~/idx/index.sqlite', TAGENTS_KNOWLEDGE_USAGE_DB: 'rel/usage.sqlite' },
    steps: [{ call: ['knowledge_search', { query: 'alpha' }] }, { call: ['knowledge_usage', {}] }, { ls: 'cwd' }],
  },
  {
    name: 'the index is in the config directory unless named',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs' },
    steps: [{ call: ['knowledge_search', { query: 'alpha' }] }, { ls: 'config' }],
  },
  {
    name: 'the store is beside the index in use',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs', TAGENTS_KNOWLEDGE_DB: '<dir>/db/index.sqlite' },
    steps: [{ call: ['knowledge_get', { id: 'alpha' }] }, { ls: 'db' }, { ls: 'config' }],
  },
  {
    name: 'the config directory comes from XDG_CONFIG_HOME',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_CONFIG_DIR: null, XDG_CONFIG_HOME: '<dir>/xdg', TAGENTS_KNOWLEDGE_DIR: '<dir>/docs' },
    steps: [{ call: ['knowledge_get', { id: 'alpha' }] }],
  },
  {
    name: 'the config is read from the config directory of the variable',
    folder: 'xdg/tagents/docs',
    files: [ALPHA],
    env: { TAGENTS_CONFIG_DIR: null, XDG_CONFIG_HOME: '<dir>/xdg' },
    extra: { 'xdg/tagents/config.toml': '[knowledge]\ndir = "docs"\n' },
    steps: LIST,
  },
  {
    name: 'the index cannot be opened',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs', TAGENTS_KNOWLEDGE_DB: '<dir>/a-file/index.sqlite' },
    extra: { 'a-file': 'x' },
    steps: FOUR,
  },
  {
    name: 'the usage store is not a database',
    folder: 'docs',
    files: [ALPHA],
    env: { TAGENTS_KNOWLEDGE_DIR: '<dir>/docs', TAGENTS_KNOWLEDGE_USAGE_DB: '<dir>/usage.sqlite' },
    extra: { 'usage.sqlite': 'this is not a database file, it is longer than a header would be' },
    steps: [{ call: ['knowledge_get', { id: 'alpha' }] }, { call: ['knowledge_usage', {}] }, { call: ['knowledge_list', {}] }],
  },
];

function resolved(scenario: Scenario, dir: string): { env: Record<string, string>; cwd: string } {
  const sub = (text: string): string => text.split('<dir>').join(dir);
  const env: Record<string, string> = { HOME: dir, TAGENTS_CONFIG_DIR: path.join(dir, 'config') };
  for (const [name, value] of Object.entries(scenario.env ?? {})) {
    if (value === null) delete env[name];
    else env[name] = sub(value);
  }
  return { env, cwd: path.join(dir, 'cwd') };
}

function names(dir: string): string[] {
  return fs.existsSync(dir) ? fs.readdirSync(dir).sort() : [];
}

async function run(scenario: Scenario): Promise<unknown> {
  const dir = scratch('tools');
  const sub = (text: string): string => text.split('<dir>').join(dir);
  const { env, cwd } = resolved(scenario, dir);
  fs.mkdirSync(cwd, { recursive: true });
  fs.mkdirSync(path.join(dir, 'config'), { recursive: true });
  const folder = scenario.folder === undefined ? null : path.join(dir, scenario.folder);
  if (folder !== null && scenario.files !== undefined) writeFiles(folder, scenario.files, MTIME_SEC);
  if (scenario.config !== undefined) fs.writeFileSync(path.join(dir, 'config', 'config.toml'), sub(scenario.config));
  for (const [name, text] of Object.entries(scenario.extra ?? {})) {
    fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
    fs.writeFileSync(path.join(dir, name), text);
  }
  const listed = { cwd, config: path.join(dir, 'config'), db: path.join(dir, 'db') };
  const before = { cwd: process.cwd(), home: process.env['HOME'] };
  process.chdir(cwd);
  process.env['HOME'] = dir;
  try {
    const conn = await connect(env);
    try {
      const out: unknown[] = [];
      for (const step of scenario.steps) {
        if ('call' in step) {
          const [tool, args] = step.call;
          const response = await conn.request('tools/call', { name: tool, arguments: args });
          if (response === null) throw new Error(`no response to ${tool}`);
          const outcome = outcomeOf(response);
          out.push({ call: { tool, args }, isError: outcome.isError, text: relativize(outcome.text, dir) });
        } else if ('write' in step) {
          if (folder === null) throw new Error('a write needs a folder');
          writeFiles(folder, [{ name: step.write.name, text: step.write.text }], step.write.mtimeSec);
          out.push(step);
        } else if ('remove' in step) {
          if (folder === null) throw new Error('a remove needs a folder');
          fs.rmSync(path.join(folder, step.remove));
          out.push(step);
        } else {
          out.push({ ls: step.ls, entries: names(listed[step.ls]) });
        }
      }
      return {
        name: scenario.name,
        ...(scenario.folder === undefined ? {} : { folder: scenario.folder }),
        ...(scenario.files === undefined ? {} : { files: scenario.files.map((f) => ({ name: f.name, text: f.text, mtimeSec: MTIME_SEC })) }),
        ...(scenario.config === undefined ? {} : { config: scenario.config }),
        env: Object.fromEntries(Object.entries(scenario.env ?? {})),
        ...(scenario.extra === undefined ? {} : { extra: scenario.extra }),
        steps: out,
      };
    } finally {
      await conn.close();
    }
  } finally {
    process.chdir(before.cwd);
    if (before.home === undefined) delete process.env['HOME'];
    else process.env['HOME'] = before.home;
  }
}

export async function toolVectors(): Promise<unknown> {
  const scenarios: unknown[] = [];
  for (const scenario of SCENARIOS) scenarios.push(await run(scenario));
  return { scenarios };
}
