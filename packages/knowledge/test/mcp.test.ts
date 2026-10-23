// The MCP surface, driven the way a client drives it: spawn the binary, speak
// the protocol over stdio, call the tools, read what comes back.
//
// The child is started by the SDK transport and killed by closing it — a test
// that leaves an MCP server running is a test that leaves an MCP server
// running on the developer's machine forever.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { type TestContext } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { z } from 'zod';
import { getEvent, hitEvents, recordReads, type UsageEvent } from '../src/usage.ts';
import {
  IdRows,
  NODE,
  UsageRows,
  baseEnv,
  cliEntry,
  copyKnowledge,
  copyOkf,
  doc,
  recordedLines,
  removeDir,
  runCli,
  tmpDir,
  writeDoc,
} from './helpers.ts';

const ResultSchema = z.object({
  content: z.array(z.object({ type: z.string(), text: z.string().optional() })),
  isError: z.boolean().optional(),
});

function textOf(result: unknown): string {
  return ResultSchema.parse(result)
    .content.map((c) => c.text ?? '')
    .join('');
}

function failed(result: unknown): boolean {
  return ResultSchema.parse(result).isError === true;
}

test('an MCP client can search, read and list over stdio', async (t) => {
  const root = tmpDir('mcp');
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  // No Claude account dirs: the sessions tools must answer, not explode.
  const homes = path.join(root, 'claude-homes');
  const transport = new StdioClientTransport({
    command: NODE,
    args: [cliEntry(), 'mcp'],
    env: baseEnv({
      TAGENTS_KNOWLEDGE_DIR: dir,
      TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite'),
      CLAUDE_HOMES: homes,
      HOME: os.homedir(),
    }),
    stderr: 'pipe',
  });
  const client = new Client({ name: 'knowledge-suite', version: '0.0.0' });
  t.after(async () => {
    await client.close();
    removeDir(root);
  });
  await client.connect(transport);

  const { tools } = await client.listTools();
  assert.deepEqual(
    tools.map((x) => x.name).sort(),
    ['knowledge_get', 'knowledge_list', 'knowledge_search', 'knowledge_usage', 'sessions_recent', 'sessions_search']
  );
  const usage = tools.find((x) => x.name === 'knowledge_usage');
  assert.equal(usage?.inputSchema.type, 'object');
  assert.deepEqual(Object.keys(usage?.inputSchema.properties ?? {}).sort(), [
    'all',
    'candidates',
    'min_days',
    'min_gets',
    'since',
    'top',
    'type',
  ]);
  assert.deepEqual(usage?.inputSchema.required ?? [], [], 'every input of the report is optional');
  const search = tools.find((x) => x.name === 'knowledge_search');
  assert.equal(search?.inputSchema.type, 'object');
  assert.deepEqual(Object.keys(search?.inputSchema.properties ?? {}).sort(), [
    'kind',
    'limit',
    'query',
    'tag',
    'type',
  ]);
  assert.deepEqual(search?.inputSchema.required, ['query']);

  const hits: unknown = JSON.parse(
    textOf(await client.callTool({ name: 'knowledge_search', arguments: { query: 'rollback' } }))
  );
  assert.ok(Array.isArray(hits) && hits.length >= 2);
  const first = hits[0] as { id: string; heading: string; snippet: string; score: number };
  assert.equal(first.id, 'deploy-runbook');
  assert.equal(first.heading, 'Rollback');
  assert.equal(typeof first.score, 'number');

  const russian: unknown = JSON.parse(
    textOf(await client.callTool({ name: 'knowledge_search', arguments: { query: 'бэкапы', limit: 5 } }))
  );
  assert.deepEqual(
    (russian as Array<{ id: string }>).map((h) => h.id),
    ['mashina-karta']
  );

  const whole = textOf(await client.callTool({ name: 'knowledge_get', arguments: { id: 'mashina-karta' } }));
  assert.match(whole, /^---\nid: mashina-karta/);
  assert.match(whole, /## Сервисы/);

  const section = textOf(
    await client.callTool({ name: 'knowledge_get', arguments: { id: 'mashina-karta', heading: 'Диски' } })
  );
  assert.match(section, /^## Диски\n\n/);
  assert.ok(!section.includes('Сервисы'));

  const missing = await client.callTool({ name: 'knowledge_get', arguments: { id: 'no-such-doc' } });
  assert.ok(failed(missing), 'an unknown id is a tool error, not an empty answer');

  const docs: unknown = JSON.parse(
    textOf(await client.callTool({ name: 'knowledge_list', arguments: { kind: 'runbook' } }))
  );
  assert.deepEqual(
    (docs as Array<{ id: string; headings: string[] }>).map((d) => d.id),
    ['deploy-runbook']
  );

  const recent = textOf(await client.callTool({ name: 'sessions_recent', arguments: { limit: 3 } }));
  assert.match(recent, /sessions\.mjs show <id-prefix>/);
  const found = textOf(await client.callTool({ name: 'sessions_search', arguments: { words: 'nothing here' } }));
  assert.match(found, /nothing matches/);
});

test('the server refuses politely when no knowledge directory is configured', async (t) => {
  const root = tmpDir('mcp-unset');
  const transport = new StdioClientTransport({
    command: NODE,
    args: [cliEntry(), 'mcp'],
    env: baseEnv({ TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite') }),
    stderr: 'pipe',
  });
  const client = new Client({ name: 'knowledge-suite', version: '0.0.0' });
  t.after(async () => {
    await client.close();
    removeDir(root);
  });
  await client.connect(transport);
  const result = await client.callTool({ name: 'knowledge_list', arguments: {} });
  assert.ok(failed(result));
  assert.match(textOf(result), /TAGENTS_KNOWLEDGE_DIR/);
});

test('the OKF fields reach the tools, and kind is accepted as the alias of type', async (t) => {
  const root = tmpDir('mcp-okf');
  const dir = copyOkf(path.join(root, 'knowledge'));
  const transport = new StdioClientTransport({
    command: NODE,
    args: [cliEntry(), 'mcp'],
    env: baseEnv({
      TAGENTS_KNOWLEDGE_DIR: dir,
      TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite'),
      CLAUDE_HOMES: path.join(root, 'claude-homes'),
      HOME: os.homedir(),
    }),
    stderr: 'pipe',
  });
  const client = new Client({ name: 'knowledge-suite', version: '0.0.0' });
  t.after(async () => {
    await client.close();
    removeDir(root);
  });
  await client.connect(transport);

  const call = async (name: string, args: Record<string, unknown>): Promise<unknown> =>
    JSON.parse(textOf(await client.callTool({ name, arguments: args })));
  const byType = await call('knowledge_list', { type: 'RUNBOOK' });
  const byKind = await call('knowledge_list', { kind: 'runbook' });
  assert.deepEqual(byType, byKind);
  assert.ok(Array.isArray(byType) && byType.length === 1);
  assert.deepEqual(Object.keys(byType[0] as object).sort(), [
    'description',
    'headings',
    'id',
    'path',
    'stale',
    'status',
    'tags',
    'title',
    'type',
    'updated',
  ]);

  const all = (await call('knowledge_list', {})) as Array<{ id: string; status: string }>;
  assert.deepEqual(
    all.map((d) => d.id),
    ['backup-runbook', 'cache-policy', 'service-map', 'old-queue-notes']
  );
  const hits = (await call('knowledge_search', { query: 'failover', kind: 'note' })) as Array<Record<string, unknown>>;
  assert.deepEqual(
    hits.map((h) => [h['id'], h['status'], h['type']]),
    [['old-queue-notes', 'deprecated', 'Note']]
  );
  assert.deepEqual(Object.keys(hits[0] ?? {}).sort(), [
    'description',
    'heading',
    'id',
    'path',
    'score',
    'snippet',
    'stale',
    'status',
    'title',
    'type',
  ]);
  assert.equal(typeof hits[0]?.['stale'], 'boolean');
});

// ---- the usage store -------------------------------------------------------------------------------

const indexFile = (root: string): string => path.join(root, 'index.sqlite');
/** In a directory that does not exist yet: the first event makes it. */
const usageStore = (root: string): string => path.join(root, 'usage', 'knowledge-usage.sqlite');

/** The environment of a stdio server over `dir`, with its index and its usage store inside `root`. */
function serverEnv(root: string, dir: string): Record<string, string> {
  return {
    TAGENTS_KNOWLEDGE_DIR: dir,
    TAGENTS_KNOWLEDGE_DB: indexFile(root),
    TAGENTS_KNOWLEDGE_USAGE_DB: usageStore(root),
    CLAUDE_HOMES: path.join(root, 'claude-homes'),
    HOME: os.homedir(),
  };
}

/** A connected client of a stdio server. Closing it ends the server, and `root` goes with it. */
async function connect(
  t: TestContext,
  root: string,
  env: Record<string, string>,
  name = 'knowledge-suite'
): Promise<Client> {
  const transport = new StdioClientTransport({
    command: NODE,
    args: [cliEntry(), 'mcp'],
    env: baseEnv(env),
    stderr: 'pipe',
  });
  const client = new Client({ name, version: '0.0.0' });
  t.after(async () => {
    await client.close();
    removeDir(root);
  });
  await client.connect(transport);
  return client;
}

test('the tools that return a document record it for the client that asked, and nothing else leaves an event', async (t) => {
  const root = tmpDir('mcp-record');
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  const store = usageStore(root);
  const client = await connect(t, root, serverEnv(root, dir));
  const call = (name: string, args: Record<string, unknown> = {}): Promise<unknown> =>
    client.callTool({ name, arguments: args });
  const recorded = (): string[] => recordedLines(store);

  // Looking is not reading: no event, and not even a store.
  await call('knowledge_list');
  await call('sessions_recent', { limit: 3 });
  await call('sessions_search', { words: 'nothing here' });
  await call('knowledge_usage');
  assert.equal(fs.existsSync(store), false);

  // A call that fails records nothing.
  assert.ok(failed(await call('knowledge_get', { id: 'no-such-doc' })));
  assert.ok(failed(await call('knowledge_get', { id: 'deploy-runbook', heading: 'No such section' })));
  assert.equal(fs.existsSync(store), false);

  // A get: the document as indexed, the section as the document writes it.
  await call('knowledge_get', { id: 'mashina-karta' });
  await call('knowledge_get', { id: 'deploy-runbook', heading: 'rollback' });
  assert.deepEqual(recorded(), ['get mashina-karta# by knowledge-suite', 'get deploy-runbook#Rollback by knowledge-suite']);

  // A search: each document once, in the order of the results, however many of its sections matched.
  const hits = IdRows.parse(JSON.parse(textOf(await call('knowledge_search', { query: 'proxy' }))));
  const ids = hits.map((h) => h.id);
  assert.ok(
    ids.filter((id) => id === 'deploy-runbook').length >= 2,
    'two sections of one document must match, or this proves nothing'
  );
  assert.deepEqual(
    recorded().slice(2),
    [...new Set(ids)].map((id) => `hit ${id}# by knowledge-suite`)
  );

  // Nothing found, nothing recorded.
  const before = recorded().length;
  assert.match(textOf(await call('knowledge_search', { query: 'qqqzzzxxx' })), /nothing matches/);
  assert.equal(recorded().length, before);

  // Listing and reporting still add nothing.
  await call('knowledge_list');
  await call('knowledge_usage');
  assert.equal(recorded().length, before);

  // Another client is another caller.
  const other = await connect(t, root, serverEnv(root, dir), 'second-reader');
  await other.callTool({ name: 'knowledge_get', arguments: { id: 'tmux-cheatsheet' } });
  assert.equal(recorded().at(-1), 'get tmux-cheatsheet# by second-reader');
});

test('what was read does not move a document up: knowledge_search keeps its order after one of two alike documents is read many times', async (t) => {
  const root = tmpDir('mcp-no-rank');
  const dir = path.join(root, 'knowledge');
  const body = 'Where the trout sleeps in winter.\n';
  writeDoc(dir, 'perch-notes.md', doc({ id: 'perch-notes', title: 'Pond notes' }, body));
  writeDoc(dir, 'trout-notes.md', doc({ id: 'trout-notes', title: 'Pond notes' }, body));
  const client = await connect(t, root, serverEnv(root, dir));
  const ask = async (): Promise<string[]> =>
    IdRows.parse(JSON.parse(textOf(await client.callTool({ name: 'knowledge_search', arguments: { query: 'winter' } })))).map(
      (h) => h.id
    );

  // They tie on score, so the id decides, and the one that is read is the one that sorts second.
  const before = await ask();
  assert.deepEqual(before, ['perch-notes', 'trout-notes']);
  recordReads(usageStore(root), Array.from({ length: 40 }, () => getEvent('trout-notes', '', null)), {
    report: (reason) => assert.fail(reason),
  });
  assert.deepEqual(await ask(), before);
});

test('knowledge_usage returns the rows of usage --json on the same store, whatever it is asked', async (t) => {
  const root = tmpDir('mcp-report');
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  const store = usageStore(root);
  // deploy-runbook: five gets on three UTC dates (any two of 0, 30 and 60 hours ago are over a day apart), one of them for a section.
  const readHoursAgo = (hours: number, events: UsageEvent[]): void =>
    recordReads(store, events, {
      now: { now: () => Date.now() - hours * 3_600_000 },
      report: (reason) => assert.fail(reason),
    });
  readHoursAgo(0, [getEvent('deploy-runbook', '', null), getEvent('deploy-runbook', 'Rollback', 'builder')]);
  readHoursAgo(30, [getEvent('deploy-runbook', '', null), getEvent('deploy-runbook', '', null)]);
  readHoursAgo(60, [
    getEvent('deploy-runbook', '', null),
    getEvent('mashina-karta', '', null),
    ...hitEvents([{ id: 'tmux-cheatsheet' }], null),
  ]);
  readHoursAgo(5, [getEvent('left-the-folder', '', null)]);
  const client = await connect(t, root, serverEnv(root, dir));

  const tool = async (args: Record<string, unknown>): Promise<z.infer<typeof UsageRows>> =>
    UsageRows.parse(JSON.parse(textOf(await client.callTool({ name: 'knowledge_usage', arguments: args }))));
  const cli = (...flags: string[]): z.infer<typeof UsageRows> =>
    UsageRows.parse(
      JSON.parse(
        runCli(['usage', '--json', '--dir', dir, '--db', indexFile(root), '--usage-db', store, ...flags]).stdout
      )
    );

  const rows = await tool({});
  assert.deepEqual(
    rows.map((r) => [r.id, r.type, r.status, r.gets, r.hits, r.days]),
    [
      ['deploy-runbook', 'Runbook', 'stable', 5, 0, 3],
      ['mashina-karta', 'Map', 'stable', 1, 0, 1],
      ['tmux-cheatsheet', 'Cheatsheet', 'stable', 0, 1, 0],
      ['relizy-zametki', 'Note', 'stable', 0, 0, 0],
      ['sqlite-over-vectors', 'Decision', 'stable', 0, 0, 0],
    ]
  );
  assert.match(rows[0]?.last ?? '', /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(rows[2]?.last, null, 'only a hit: never read');

  const cases: Array<[Record<string, unknown>, string[]]> = [
    [{}, []],
    [{ candidates: true }, ['--candidates']],
    [{ type: 'runbook' }, ['--type', 'runbook']],
    [{ top: 1 }, ['--top', '1']],
    [{ all: true }, ['--all']],
    [{ since: '1d' }, ['--since', '1d']],
    [{ candidates: true, min_gets: 6 }, ['--candidates', '--min-gets', '6']],
    [{ candidates: true, min_days: 4 }, ['--candidates', '--min-days', '4']],
  ];
  for (const [args, flags] of cases) assert.deepEqual(await tool(args), cli(...flags), JSON.stringify(args));

  assert.deepEqual((await tool({ candidates: true })).map((r) => r.id), ['deploy-runbook']);
  assert.deepEqual(await tool({ candidates: true, min_gets: 6 }), [], 'no row is [], not an error');
  const gone = (await tool({ all: true })).find((r) => r.id === 'left-the-folder');
  assert.deepEqual([gone?.type, gone?.status, gone?.gets], [null, null, 1]);
  assert.ok(!rows.some((r) => r.id === 'left-the-folder'), 'an id that left the folder only with all');
  assert.equal((await tool({ since: '1d' }))[0]?.gets, 2);

  const empty = await client.callTool({ name: 'knowledge_usage', arguments: { type: 'no-such-type' } });
  assert.equal(failed(empty), false);
  assert.equal(textOf(empty), '[]');
  assert.equal(
    textOf(await client.callTool({ name: 'knowledge_usage', arguments: { top: 1 } })),
    JSON.stringify(await tool({ top: 1 }), null, 2),
    'pretty-printed'
  );

  for (const since of ['soon', '30', '0d']) {
    const result = await client.callTool({ name: 'knowledge_usage', arguments: { since } });
    assert.ok(failed(result), since);
    assert.match(textOf(result), /since/, since);
  }
});

test('a usage store that cannot be read is a tool error that names the file, and is left as it was', async (t) => {
  const root = tmpDir('mcp-damaged');
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  const store = usageStore(root);
  const garbage = 'this is text, not a database\n'.repeat(40);
  fs.mkdirSync(path.dirname(store), { recursive: true });
  fs.writeFileSync(store, garbage);
  const client = await connect(t, root, serverEnv(root, dir));

  const report = await client.callTool({ name: 'knowledge_usage', arguments: {} });
  assert.ok(failed(report));
  assert.ok(textOf(report).includes(store), textOf(report));
  // A read still answers: recording is best effort, and a store that is no database costs the event, not the document.
  const read = await client.callTool({ name: 'knowledge_get', arguments: { id: 'mashina-karta' } });
  assert.equal(failed(read), false);
  assert.match(textOf(read), /^---\nid: mashina-karta/);
  assert.equal(fs.readFileSync(store, 'utf8'), garbage);
});
