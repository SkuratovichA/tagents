// Every verb of `tagents-knowledge` as data. `parseArgs` is handed `.options` of the same object a contract generator reads. The usage text in i18n/en.ts stays hand-written; test/cli-spec.test.ts pins the two together.
import type { CliContract, CommandSpec } from '@tagents/core';
import { createT, type KnowledgeKey } from '../i18n/index.ts';
import { EXIT } from './exit.ts';

export const INDEX = {
  path: ['index'],
  positionals: [],
  options: { dir: { type: 'string' }, db: { type: 'string' }, full: { type: 'boolean' } },
  required: [],
  summary: 'summaryIndex',
} as const satisfies CommandSpec<KnowledgeKey>;

export const SEARCH = {
  path: ['search'],
  positionals: ['<query…>'],
  options: {
    dir: { type: 'string' },
    db: { type: 'string' },
    tag: { type: 'string' },
    type: { type: 'string' },
    kind: { type: 'string' },
    limit: { type: 'string' },
    json: { type: 'boolean' },
    'usage-db': { type: 'string' },
    verbose: { type: 'boolean' },
  },
  required: [],
  summary: 'summarySearch',
} as const satisfies CommandSpec<KnowledgeKey>;

export const SHOW = {
  path: ['show'],
  positionals: ['<id[#heading]>'],
  options: {
    dir: { type: 'string' },
    db: { type: 'string' },
    'usage-db': { type: 'string' },
    verbose: { type: 'boolean' },
  },
  required: [],
  summary: 'summaryShow',
} as const satisfies CommandSpec<KnowledgeKey>;

export const LIST = {
  path: ['list'],
  positionals: [],
  options: {
    dir: { type: 'string' },
    db: { type: 'string' },
    type: { type: 'string' },
    kind: { type: 'string' },
    tag: { type: 'string' },
    json: { type: 'boolean' },
  },
  required: [],
  summary: 'summaryList',
} as const satisfies CommandSpec<KnowledgeKey>;

export const LINT = {
  path: ['lint'],
  positionals: [],
  options: { dir: { type: 'string' } },
  required: [],
  summary: 'summaryLint',
} as const satisfies CommandSpec<KnowledgeKey>;

export const TOC = {
  path: ['toc'],
  positionals: [],
  options: { dir: { type: 'string' }, check: { type: 'boolean' } },
  required: [],
  summary: 'summaryToc',
} as const satisfies CommandSpec<KnowledgeKey>;

export const USAGE = {
  path: ['usage'],
  positionals: [],
  options: {
    dir: { type: 'string' },
    db: { type: 'string' },
    'usage-db': { type: 'string' },
    since: { type: 'string' },
    top: { type: 'string' },
    type: { type: 'string' },
    all: { type: 'boolean' },
    candidates: { type: 'boolean' },
    'min-gets': { type: 'string' },
    'min-days': { type: 'string' },
    json: { type: 'boolean' },
  },
  required: [],
  summary: 'summaryUsage',
} as const satisfies CommandSpec<KnowledgeKey>;

export const MCP = {
  path: ['mcp'],
  positionals: [],
  options: {},
  required: [],
  summary: 'summaryMcp',
} as const satisfies CommandSpec<KnowledgeKey>;

export const SERVE = {
  path: ['serve'],
  positionals: [],
  options: { idle: { type: 'string' }, foreground: { type: 'boolean' }, socket: { type: 'string' } },
  required: [],
  summary: 'summaryServe',
} as const satisfies CommandSpec<KnowledgeKey>;

export const KNOWLEDGE_COMMANDS = [INDEX, SEARCH, SHOW, LIST, LINT, TOC, USAGE, MCP, SERVE] as const satisfies readonly CommandSpec<KnowledgeKey>[];

/** English whatever the machine's locale is: the contract is read by tools, not people. */
export function knowledgeCliContract(): CliContract {
  const t = createT('en');
  return {
    program: 'tagents-knowledge',
    exit: EXIT,
    commands: KNOWLEDGE_COMMANDS.map((c) => ({
      path: c.path,
      positionals: c.positionals,
      options: c.options,
      required: c.required,
      summary: t(c.summary),
    })),
  };
}
