// The corpus section of the knowledge vectors: folders of documents and the calls of the real tools over them.
//
// Each call goes through the node MCP server by an in-memory client under the fixed clock, so what is kept is what the tool says (the text, whether it failed) and what it left in the usage store. A path is written `<dir>`, the folder the documents are in.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseDoc } from '../../packages/knowledge/src/doc.ts';
import { openDb, reindex, silenceSqliteWarning } from '../../packages/knowledge/src/db.ts';
import { ftsQuery, search } from '../../packages/knowledge/src/search.ts';
import { NOW, clock, connect, fixtureFiles, lcg, outcomeOf, plain, relativize, scratch, writeFiles, type CorpusFile, type Connection } from './util.mts';

const MTIME_SEC = 1_700_000_000;

// ---- the synthetic corpus ---------------------------------------------------------------------

const doc = (front: string, body: string): string => `---\n${front}\n---\n${body}`;

const LONG = Array.from({ length: 60 }, (_, i) => `word${i}`).join(' ');

const SEARCH_FILES: CorpusFile[] = [
  { name: 'aaa-tie-one.md', text: doc('type: Note\ntitle: Tie one', '## Tied\nthe quick brown fox jumps over the lazy dog\n') },
  { name: 'aaa-tie-two.md', text: doc('type: Note\ntitle: Tie two', '## Tied\nthe quick brown fox jumps over the lazy dog\n') },
  { name: 'bbb-tie.md', text: doc('type: Runbook\ntitle: Tie three\ntags: [a]', '## Tied\nthe quick brown fox jumps over the lazy dog\n\n## Tied\nthe same heading again with a fox\n') },
  { name: 'deploy-guide.md', text: doc('type: Runbook\ntitle: Deploy guide\ndescription: How to ship\ntags: [ops, a]', 'Preamble about deploy.\n\n## Deploy steps\nrun deploy.sh then verify the deploy\n\n## Rollback\nrollback is the reverse of a deploy\n') },
  { name: 'old-deploy.md', text: doc('type: Runbook\ntitle: Old deploy\nstatus: deprecated\ndescription: Superseded', '## Deploy\ndeploy deploy deploy deploy deploy everything with the deploy script\n') },
  { name: 'deploy-draft.md', text: doc('type: Note\ntitle: Deploy draft\nstatus: draft\ntags: [ops]', '## Notes\ndeploy draft notes\n') },
  { name: 'cafe-notes.md', text: doc('type: Note\ntitle: Cafe notes\ntags: [café]', '## Café\nA naïve résumé about cafe culture, CAFÉ and Cafe.\n\n## Other\nnothing about it\n') },
  { name: 'ru-dokument.md', text: doc('type: Заметка\ntitle: Документ\ntags: [диски]', '## Диски\nДиски и тома: ёлка, Йод, еда, ЕЩЁ.\n\n## Сеть\nсетевые настройки\n') },
  { name: 'ids-doc.md', text: doc('type: Note\ntitle: Identifiers', '## Commands\nrun tmux-agent-state.sh then foo_bar and a.b.c; also AND OR NOT near\n') },
  { name: 'zeta-long.md', text: doc('type: Note\ntitle: Zeta long', `## Long\n${LONG} needle ${LONG}\n`) },
  { name: 'stale-doc.md', text: doc('type: Note\ntitle: Stale\nstale_after: 2026-10-31T12:00:00Z\ngenerated: {by: tool, at: 2026-10-30T23:30:00-02:00}', '## Staleness\nthis one has reached its limit\n') },
  { name: 'fresh-doc.md', text: doc('type: Note\ntitle: Fresh\nstale_after: 2026-10-31T12:00:01Z\ngenerated: {by: tool, at: 2026-10-31T00:00:00Z}', '## Staleness\nthis one has a second to go\n') },
  { name: 'legacy-doc.md', text: doc('kind: runbook\nupdated: 2026-09-10\ngenerated_from: https://example.org/src', '## Legacy\nan old document with a legacy kind\n') },
  { name: 'heading-weight.md', text: doc('type: Note\ntitle: Heading weight', '## Heron\na bird\n') },
  { name: 'body-weight.md', text: doc('type: Note\ntitle: Body weight', '## Other\nheron heron heron\n') },
  { name: 'quote-doc.md', text: doc('type: Note\ntitle: Quotes\ntags: [\'q"uote\', c d]', '## Quotes\nsay "hello" and \'bye\'\n') },
  { name: 'empty-body.md', text: doc('type: Note\ntitle: Empty', '') },
  { name: 'many-sections.md', text: doc('type: Note\ntitle: Many', 'intro text\n\n## Section one\nfirst section\n\n## Section two\nsecond section\n\n## Section three\nthird section\n\n## SECTION FOUR\nfourth section\n') },
  { name: 'locked-doc.md', text: doc('type: Note\ntitle: Locked', '## Locked\nthis file is made unreadable after it was indexed\n') },
];

const SEARCH_QUERIES = [
  'fox', 'quick fox', 'lazy dog', 'fox dog cat', 'deploy', 'deploy*', 'deplo*', 'DEPLOY', 'Deploy steps', 'rollback',
  'cafe', 'café', 'CAFE', 'naive', 'naïve', 'resume', 'résumé', 'cafe*', 'caf*',
  'диски', 'Диски', 'ДИСКИ', 'диск*', 'елка', 'ёлка', 'йод', 'иод', 'еще', 'ещё', 'ёлка йод', 'Дис*',
  'tmux-agent-state.sh', 'agent state', 'foo_bar', 'a.b.c', 'NOT', 'AND OR', 'OR', 'near', 'needle', 'needle*', 'heron', 'heron*',
  '"hello"', 'hello', 'bye', '"', '""', '*', '**', '-', '- x', 'x -y', '(fox)', 'fox OR dog', 'fox AND dog', 'fox NOT dog', 'NEAR(fox dog)',
  'heading:fox', 'body:fox', 'doc_id:aaa', '^fox', 'fox*dog', '*fox', 'fo*x', 'fox*', 'fox** ', '  fox  ', '\tfox\n', 'fox\u00A0dog', 'fox\u3000dog', 'fox\u2028dog',
  'section', 'sections', 'Section*', 'FOUR', '1', '0', ' ', 'a', 'é', 'x'.repeat(300), 'tied', 'Tied', 'tie one', 'unknownword', 'foxfoxfox',
  'quick* brown* lazy*', 'the', 'the the the', 'staleness', 'legacy', 'limit', 'second', 'word30 needle word31', 'word0', 'word59*', '{}', '[x]', ':', ',', 'x:y', "it's", 'it"s', '\u0000', 'fox\u0000dog', '\uFEFFdeploy', 'D́eploy', 'deṕloy',
];

interface Filter {
  readonly query: string;
  readonly args: Record<string, unknown>;
}

const SEARCH_FILTERS: Filter[] = [
  { query: 'deploy', args: { tag: 'ops' } },
  { query: 'deploy', args: { tag: 'a' } },
  { query: 'deploy', args: { tag: 'OPS' } },
  { query: 'deploy', args: { tag: '' } },
  { query: 'fox', args: { tag: 'a' } },
  { query: 'cafe', args: { tag: 'café' } },
  { query: 'диски', args: { tag: 'диски' } },
  { query: 'hello', args: { tag: 'q"uote' } },
  { query: 'hello', args: { tag: 'c d' } },
  { query: 'deploy', args: { type: 'runbook' } },
  { query: 'deploy', args: { type: 'RUNBOOK' } },
  { query: 'deploy', args: { type: 'Runbook' } },
  { query: 'deploy', args: { type: 'note' } },
  { query: 'deploy', args: { type: '' } },
  { query: 'deploy', args: { type: 'nothing' } },
  { query: 'диски', args: { type: 'заметка' } },
  { query: 'диски', args: { type: 'ЗАМЕТКА' } },
  { query: 'deploy', args: { kind: 'runbook' } },
  { query: 'deploy', args: { kind: 'RUNBOOK' } },
  { query: 'deploy', args: { type: 'note', kind: 'runbook' } },
  { query: 'deploy', args: { type: '', kind: 'runbook' } },
  { query: 'deploy', args: { type: 'runbook', tag: 'ops' } },
  { query: 'legacy', args: { type: 'runbook' } },
  { query: 'legacy', args: { type: 'Runbook', limit: 1 } },
  { query: 'deploy', args: { limit: 1 } },
  { query: 'deploy', args: { limit: 2 } },
  { query: 'deploy', args: { limit: 3 } },
  { query: 'fox', args: { limit: 1 } },
  { query: 'fox', args: { limit: 2 } },
  { query: 'fox', args: { limit: 50 } },
  { query: 'section', args: { limit: 2 } },
  { query: 'word*', args: { limit: 50 } },
];

const LIST_ARGS: Array<Record<string, unknown>> = [
  {}, { type: 'runbook' }, { type: 'RUNBOOK' }, { type: 'Note' }, { type: '' }, { type: 'заметка' }, { type: 'nothing' }, { kind: 'runbook' }, { type: 'note', kind: 'runbook' }, { type: '', kind: 'runbook' },
  { tag: 'ops' }, { tag: 'a' }, { tag: 'c d' }, { tag: 'q"uote' }, { tag: 'OPS' }, { tag: '' }, { tag: 'ops', type: 'runbook' }, { tag: 'nothing' },
];

const USAGE_ARGS: Array<Record<string, unknown>> = [
  {}, { since: '30d' }, { since: '1d' }, { since: '7d' }, { since: '400d' }, { since: '100000d' }, { top: 1 }, { top: 3 }, { top: 100 }, { type: 'runbook' }, { type: 'Note' }, { type: '' }, { all: true }, { all: true, type: 'note' },
  { candidates: true }, { candidates: true, min_gets: 1, min_days: 1 }, { candidates: true, min_gets: 2, min_days: 1 }, { candidates: true, min_gets: 1, min_days: 2 }, { candidates: true, all: true, min_gets: 1, min_days: 1 }, { since: '1d', top: 2, type: 'runbook' },
];

// ---- running a corpus --------------------------------------------------------------------------

interface CallRecord {
  readonly client: string;
  readonly tool: string;
  readonly args: Record<string, unknown>;
  readonly isError: boolean;
  readonly text?: string;
  /** The text is the whole text of this file of the corpus. */
  readonly whole?: string;
  readonly events: ReadonlyArray<{ docId: string; heading: string; kind: string; caller: string | null }>;
}

type Item = CallRecord | { readonly chmod: string; readonly mode: number };

interface Run {
  readonly dir: string;
  readonly folder: string;
  readonly env: NodeJS.ProcessEnv;
  readonly usageFile: string;
  readonly files: readonly CorpusFile[];
  seen: number;
}

function setUp(label: string, files: readonly CorpusFile[]): Run {
  const dir = scratch(`corpus-${label}`);
  const folder = path.join(dir, 'folder');
  writeFiles(folder, files, MTIME_SEC);
  const usageFile = path.join(dir, 'usage.sqlite');
  const env: NodeJS.ProcessEnv = {
    HOME: dir,
    TAGENTS_CONFIG_DIR: path.join(dir, 'config'),
    TAGENTS_KNOWLEDGE_DIR: folder,
    TAGENTS_KNOWLEDGE_DB: path.join(dir, 'index.sqlite'),
    TAGENTS_KNOWLEDGE_USAGE_DB: usageFile,
  };
  return { dir, folder, env, usageFile, files, seen: 0 };
}

function newEvents(run: Run): CallRecord['events'] {
  if (!fs.existsSync(run.usageFile)) return [];
  silenceSqliteWarning();
  const db = new DatabaseSync(run.usageFile, { readOnly: true });
  try {
    const rows = db.prepare('select ts, doc_id, heading, kind, caller from usage_events order by rowid').all();
    const fresh = rows.slice(run.seen);
    run.seen = rows.length;
    return fresh.map((r) => {
      if (Number(r['ts']) !== NOW) throw new Error(`an event is not at the fixed clock: ${String(r['ts'])}`);
      return { docId: String(r['doc_id']), heading: String(r['heading']), kind: String(r['kind']), caller: r['caller'] === null ? null : String(r['caller']) };
    });
  } finally {
    db.close();
  }
}

async function call(run: Run, conn: Connection, client: string, tool: string, args: Record<string, unknown>): Promise<CallRecord> {
  const response = await conn.request('tools/call', { name: tool, arguments: args });
  if (response === null) throw new Error(`no response to ${tool}`);
  const outcome = outcomeOf(response);
  const text = relativize(outcome.text, run.folder);
  const whole = tool === 'knowledge_get' && args['heading'] === undefined ? run.files.find((f) => f.text === outcome.text)?.name : undefined;
  return {
    client,
    tool,
    args,
    isError: outcome.isError,
    ...(whole === undefined ? { text } : { whole }),
    events: newEvents(run),
  };
}

/** The headings of a document as the chunker makes them, and its id. */
function sectionsOf(file: CorpusFile): { id: string; headings: string[]; hasPreamble: boolean } {
  const parsed = parseDoc(path.join('/k', file.name), file.text);
  return { id: parsed.meta.id, headings: parsed.chunks.filter((c) => c.heading !== '').map((c) => c.heading), hasPreamble: parsed.chunks.some((c) => c.heading === '') };
}

function valid(file: CorpusFile): boolean {
  try {
    parseDoc(path.join('/k', file.name), file.text);
    return /^[a-z0-9]+(?:-[a-z0-9]+)*\.md$/.test(file.name) && file.name !== 'index.md' && file.name !== 'log.md';
  } catch {
    return false;
  }
}

function sampled(files: readonly CorpusFile[], seed: number, count: number): string[] {
  const words = new Set<string>();
  for (const f of files) for (const m of f.text.toLowerCase().matchAll(/[\p{L}\p{N}]{4,}/gu)) words.add(m[0]);
  const all = [...words].sort();
  const next = lcg(seed);
  const picked = new Set<string>();
  while (picked.size < Math.min(count, all.length)) picked.add(all[Math.floor(next() * all.length)] ?? '');
  return [...picked];
}

function autoQueries(files: readonly CorpusFile[], seed: number): string[] {
  const single = sampled(files, seed, 24);
  const pairs = Array.from({ length: 10 }, (_, i) => `${single[i] ?? ''} ${single[i + 10] ?? ''}`);
  const prefixes = single.slice(0, 12).map((w) => `${w.slice(0, 3)}*`);
  const upper = single.slice(0, 6).map((w) => w.toUpperCase());
  return [...single, ...pairs, ...prefixes, ...upper, 'zzzz', 'a', '"', 'x -y'];
}

function getsOf(files: readonly CorpusFile[]): Array<Record<string, unknown>> {
  const out: Array<Record<string, unknown>> = [];
  for (const f of files.filter(valid)) {
    const { id, headings, hasPreamble } = sectionsOf(f);
    out.push({ id });
    if (hasPreamble) out.push({ id, heading: '' });
    for (const heading of headings) {
      out.push({ id, heading });
      out.push({ id, heading: heading.toLowerCase() });
      out.push({ id, heading: heading.toUpperCase() });
      out.push({ id, heading: `  ${heading}\t` });
    }
    out.push({ id, heading: 'no such section' });
  }
  out.push({ id: 'no-such-doc' }, { id: 'no-such-doc', heading: 'x' }, { id: ' padded ' }, { id: 'ДОКУМЕНТ' }, { id: 'Deploy-Guide' }, { id: 'deploy-guide ' }, { id: 'deploy-guide', heading: 'Rollback' });
  return out;
}

async function pass(run: Run, client: string, items: Array<readonly [string, Record<string, unknown>]>): Promise<Item[]> {
  const conn = await connect(run.env, client);
  try {
    const out: Item[] = [];
    for (const [tool, args] of items) out.push(await call(run, conn, client, tool, args));
    return out;
  } finally {
    await conn.close();
  }
}

async function corpus(name: string, files: readonly CorpusFile[], queries: readonly string[], filters: readonly Filter[], extra: { locked?: string }): Promise<unknown> {
  const run = setUp(name, files);
  const items: Array<readonly [string, Record<string, unknown>]> = [];
  for (const query of queries) items.push(['knowledge_search', { query }]);
  for (const f of filters) items.push(['knowledge_search', { query: f.query, ...f.args }]);
  for (const args of LIST_ARGS) items.push(['knowledge_list', args]);
  for (const args of getsOf(files)) items.push(['knowledge_get', args]);
  for (const args of USAGE_ARGS) items.push(['knowledge_usage', args]);
  const calls: Item[] = await pass(run, 'knowledge-vectors', items);
  // Clients that give no name, or a name that is not plain, leave their own callers.
  for (const client of ['', 'клиент/1 "q"']) {
    const first = files.find(valid);
    const { id } = first === undefined ? { id: 'none' } : sectionsOf(first);
    calls.push(...(await pass(run, client, [['knowledge_search', { query: queries[0] ?? 'a' }], ['knowledge_get', { id }], ['knowledge_get', { id, heading: 'no such section' }]])));
  }
  if (extra.locked !== undefined) {
    if (typeof process.getuid === 'function' && process.getuid() === 0) throw new Error('the unreadable file needs a user that is not root: run the generator as one');
    const file = path.join(run.folder, extra.locked);
    fs.chmodSync(file, 0);
    try {
      calls.push({ chmod: extra.locked, mode: 0 });
      const id = extra.locked.replace(/\.md$/, '');
      calls.push(...(await pass(run, 'knowledge-vectors', [['knowledge_get', { id }], ['knowledge_get', { id, heading: 'Locked' }], ['knowledge_search', { query: 'unreadable' }]])));
    } finally {
      fs.chmodSync(file, 0o644);
    }
  }
  return { name, files: files.map((f) => ({ name: f.name, text: f.text, mtimeSec: MTIME_SEC })), calls };
}

/** The match expression and the rows of searches made through the library alone, over words that are random but the same at every run: the expression is the one place a user's text meets FTS5's grammar. */
function fuzz(files: readonly CorpusFile[]): unknown {
  const run = setUp('fuzz', files);
  const db = openDb(path.join(run.dir, 'fuzz.sqlite'));
  try {
    reindex(db, run.folder);
    const pool = [...sampled(files, 31, 40), 'deploy', 'fox', 'café', 'диски', 'tmux-agent-state.sh'];
    const marks = ['"', '""', '*', '-', '(', ')', 'OR', 'NOT', 'AND', 'NEAR', ':', '^', '+', ',', '{', '}', "'", '.', '\\', '%', '_'];
    const next = lcg(20261101);
    const pick = <T,>(list: readonly T[]): T => list[Math.floor(next() * list.length)] as T;
    const cases = Array.from({ length: 170 }, () => {
      const count = 1 + Math.floor(next() * 3);
      const words = Array.from({ length: count }, () => {
        const parts = Array.from({ length: 1 + Math.floor(next() * 3) }, () => (next() < 0.7 ? pick(pool) : pick(marks)));
        const joined = parts.join(next() < 0.6 ? ' ' : '');
        return next() < 0.25 ? `${joined}*` : joined;
      });
      const limit = next() < 0.3 ? Math.floor(next() * 8) - 1 : undefined;
      const hits = search(db, words, { now: clock, ...(limit === undefined ? {} : { limit }) });
      return { words, ...(limit === undefined ? {} : { limit }), match: ftsQuery(words), hits: hits.map((h) => ({ ...h, path: relativize(h.path, run.folder) })) };
    });
    return { files: files.map((f) => ({ name: f.name, text: f.text, mtimeSec: MTIME_SEC })), cases: plain(cases) };
  } finally {
    db.close();
  }
}

export async function corpusVectors(): Promise<unknown> {
  const knowledge = fixtureFiles('knowledge');
  const okf = fixtureFiles('okf');
  return {
    corpora: [
      await corpus('search', SEARCH_FILES, SEARCH_QUERIES, SEARCH_FILTERS, { locked: 'locked-doc.md' }),
      await corpus('knowledge', knowledge, autoQueries(knowledge, 7), [], {}),
      await corpus('okf', okf, autoQueries(okf, 11), [], {}),
    ],
    fuzz: fuzz(SEARCH_FILES),
  };
}
