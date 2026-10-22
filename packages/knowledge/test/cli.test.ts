// The CLI: what it prints, and what it exits with.
//
// Every case runs the real binary in a child process with a temp knowledge
// folder and a temp index, because the exit code IS the contract: a caller in
// a shell script branches on 4 (nothing found) without reading a word.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { main } from '../src/cli/main.ts';
import { KNOWLEDGE, OKF, copyKnowledge, doc, removeDir, runCli, tmpDir, writeDoc } from './helpers.ts';

type Env = Record<string, string>;

function corpus(name: string): { env: Env; dir: string; cleanup: () => void } {
  const root = tmpDir(name);
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  return {
    dir,
    env: { TAGENTS_KNOWLEDGE_DIR: dir, TAGENTS_KNOWLEDGE_DB: path.join(root, 'index.sqlite') },
    cleanup: () => removeDir(root),
  };
}

test('index reports what it did and search finds it afterwards', () => {
  const { env, cleanup } = corpus('cli-index');
  try {
    const indexed = runCli(['index'], env);
    assert.equal(indexed.code, 0, indexed.stderr);
    assert.match(indexed.stdout, /5 new, 0 changed, 0 unchanged, 0 removed/);
    assert.equal(indexed.stderr, '');

    const again = runCli(['index'], env);
    assert.match(again.stdout, /0 new, 0 changed, 5 unchanged/);
  } finally {
    cleanup();
  }
});

test('search prints one line per hit, address first', () => {
  const { env, cleanup } = corpus('cli-search');
  try {
    const r = runCli(['search', 'rollback'], env);
    assert.equal(r.code, 0, r.stderr);
    const first = r.stdout.split('\n')[0] ?? '';
    assert.match(first, /^deploy-runbook#Rollback\s+-?\d+\.\d+\s+\S/);
    assert.equal(r.stderr, '');
  } finally {
    cleanup();
  }
});

test('--json is a document, and it is not translated', () => {
  const { env, cleanup } = corpus('cli-json');
  try {
    const r = runCli(['search', 'бэкапы', '--json'], { ...env, TAGENTS_LOCALE: 'ru' });
    assert.equal(r.code, 0, r.stderr);
    const hits: unknown = JSON.parse(r.stdout);
    assert.ok(Array.isArray(hits) && hits.length === 1);
    assert.deepEqual(Object.keys(hits[0] as object).sort(), [
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
    const empty = runCli(['search', 'nothingmatchesthis', '--json'], env);
    assert.equal(empty.code, 4);
    assert.equal(empty.stdout, '[]\n');
  } finally {
    cleanup();
  }
});

test('tag and kind filters reach the CLI', () => {
  const { env, cleanup } = corpus('cli-filters');
  try {
    const byKind = runCli(['search', 'релиз*', '--kind', 'note'], env);
    assert.equal(byKind.code, 0, byKind.stderr);
    assert.match(byKind.stdout, /^relizy-zametki/);
    const byTag = runCli(['search', 'rollback', '--tag', 'tmux', '--limit', '1'], env);
    assert.equal(byTag.code, 0, byTag.stderr);
    assert.equal(byTag.stdout.trim().split('\n').length, 1);
    assert.match(byTag.stdout, /^tmux-cheatsheet/);
  } finally {
    cleanup();
  }
});

test('show prints a whole document or exactly one section', () => {
  const { env, cleanup } = corpus('cli-show');
  try {
    const whole = runCli(['show', 'mashina-karta'], env);
    assert.equal(whole.code, 0, whole.stderr);
    assert.equal(whole.stdout, fs.readFileSync(path.join(KNOWLEDGE, 'mashina-karta.md'), 'utf8'));

    const section = runCli(['show', 'mashina-karta#Диски'], env);
    assert.equal(section.code, 0, section.stderr);
    assert.match(section.stdout, /^## Диски\n\n/);
    assert.ok(!section.stdout.includes('Сервисы'), 'one section means one section');

    const preamble = runCli(['show', 'mashina-karta#'], env);
    assert.equal(preamble.code, 0, preamble.stderr);
    assert.match(preamble.stdout, /^Что где стоит/);
  } finally {
    cleanup();
  }
});

test('list is one line per document, or JSON', () => {
  const { env, cleanup } = corpus('cli-list');
  try {
    const text = runCli(['list', '--kind', 'runbook'], env);
    assert.equal(text.code, 0, text.stderr);
    assert.equal(text.stdout.trim().split('\n').length, 1);
    assert.match(text.stdout, /^deploy-runbook\s+Runbook\s+2026-09-10\s+Deploying the demo service\s+#deploy #ci\n$/);

    const asJson: unknown = JSON.parse(runCli(['list', '--tag', 'deploy', '--json'], env).stdout);
    assert.ok(Array.isArray(asJson));
    assert.deepEqual(
      asJson.map((d) => (d as { id: string }).id),
      ['deploy-runbook', 'relizy-zametki']
    );
    assert.deepEqual(Object.keys(asJson[0] as object), [
      'type',
      'description',
      'status',
      'stale',
      'id',
      'title',
      'tags',
      'updated',
      'path',
      'headings',
    ]);
  } finally {
    cleanup();
  }
});

test('exit codes: 0 ok · 1 error · 2 usage · 4 nothing found', () => {
  const { env, cleanup } = corpus('cli-exits');
  try {
    assert.equal(runCli(['list'], env).code, 0);
    assert.equal(runCli(['search'], env).code, 2, 'a search without a query is a usage error');
    assert.equal(runCli(['show'], env).code, 2);
    assert.equal(runCli(['search', '--nonsense', 'x'], env).code, 2);
    assert.equal(runCli(['nonsense'], env).code, 2);
    assert.equal(runCli([], env).code, 2);
    assert.equal(runCli(['help'], env).code, 0);

    assert.equal(runCli(['search', 'nothingmatchesthis'], env).code, 4);
    assert.equal(runCli(['show', 'no-such-doc'], env).code, 4);
    assert.equal(runCli(['show', 'mashina-karta#No Such Heading'], env).code, 4);

    // Nobody said where the documents are.
    const unset = runCli(['list'], { TAGENTS_KNOWLEDGE_DB: env['TAGENTS_KNOWLEDGE_DB'] ?? '' });
    assert.equal(unset.code, 1);
    assert.match(unset.stderr, /TAGENTS_KNOWLEDGE_DIR/);
    assert.match(unset.stderr, /config\.yaml/);

    // They did, and it is not there.
    const missing = runCli(['list'], { ...env, TAGENTS_KNOWLEDGE_DIR: '/no/such/knowledge' });
    assert.equal(missing.code, 1);
    assert.match(missing.stderr, /does not exist/);
  } finally {
    cleanup();
  }
});

test('human strings follow TAGENTS_LOCALE, and only human strings', () => {
  const { env, cleanup } = corpus('cli-locale');
  try {
    const ru = runCli(['search', 'nothingmatchesthis'], { ...env, TAGENTS_LOCALE: 'ru' });
    assert.equal(ru.code, 4);
    assert.match(ru.stderr, /ничего не найдено/);
    const en = runCli(['search', 'nothingmatchesthis'], env);
    assert.match(en.stderr, /nothing matches/);
    assert.match(runCli(['help'], { ...env, TAGENTS_LOCALE: 'ru' }).stdout, /использование/);
    // An unknown locale is English, not a crash.
    assert.match(runCli(['help'], { ...env, TAGENTS_LOCALE: 'xx' }).stdout, /usage:/);
  } finally {
    cleanup();
  }
});

test('a read command picks up an edit made since the last index', () => {
  const { env, dir, cleanup } = corpus('cli-fresh');
  try {
    runCli(['index'], env);
    writeDoc(dir, 'novyj-runbook.md', doc({ id: 'novyj-runbook', kind: 'runbook' }, 'Про откат очереди.\n'));
    const r = runCli(['search', 'очереди'], env);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /^novyj-runbook/);
  } finally {
    cleanup();
  }
});

test('a broken document is named on stderr and the rest still answers', () => {
  const { env, dir, cleanup } = corpus('cli-broken');
  try {
    writeDoc(dir, 'slomannyj.md', '---\nid: slomannyj\ntitle: no kind here\n---\n\nтело\n');
    const r = runCli(['search', 'rollback'], env);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stderr, /slomannyj\.md: frontmatter/);
    assert.match(r.stdout, /deploy-runbook#Rollback/);

    const indexed = runCli(['index'], env);
    assert.equal(indexed.code, 1, 'index refuses to call a folder it could not read clean');
  } finally {
    cleanup();
  }
});

test('nothing prints Node’s experimental SQLite notice', () => {
  const { env, cleanup } = corpus('cli-quiet');
  try {
    // The notice is queued when node:sqlite is imported, so a verb that never
    // opens the index is the one that used to leak it.
    for (const args of [['lint'], ['help'], ['list'], ['search', 'rollback']]) {
      const r = runCli(args, env);
      assert.ok(!r.stderr.includes('ExperimentalWarning'), `${args.join(' ')} printed: ${r.stderr}`);
    }
  } finally {
    cleanup();
  }
});

test('--kind is an alias of --type: same lines, either case', () => {
  const { env, cleanup } = corpus('cli-alias');
  try {
    const byKind = runCli(['list', '--kind', 'runbook'], env);
    const byType = runCli(['list', '--type', 'RUNBOOK'], env);
    assert.equal(byKind.code, 0, byKind.stderr);
    assert.equal(byType.stdout, byKind.stdout);
    const searchKind = runCli(['search', 'релиз*', '--kind', 'note'], env);
    const searchType = runCli(['search', 'релиз*', '--type', 'Note'], env);
    assert.equal(searchType.stdout, searchKind.stdout);
    assert.match(searchType.stdout, /^relizy-zametki/);
    // `type` wins when both are written.
    assert.equal(runCli(['list', '--type', 'map', '--kind', 'runbook'], env).stdout.split('\n').length, 2);
  } finally {
    cleanup();
  }
});

/** The CLI in this process, with the clock handed in: a test never reads the real one. */
async function inProcess(args: string[], now: string): Promise<{ code: number; out: string; err: string }> {
  const out: string[] = [];
  const err: string[] = [];
  const code = await main(args, { out: (s) => out.push(s), err: (s) => err.push(s) }, { now: () => Date.parse(now) });
  return { code, out: out.join(''), err: err.join('') };
}

test('list marks deprecated and stale documents, deprecated last, stale by the injected clock', async () => {
  const root = tmpDir('cli-marks');
  try {
    const base = ['--dir', OKF, '--db', path.join(root, 'index.sqlite')];
    const row = (id: string, type: string, updated: string, title: string, tags: string, mark = ''): string =>
      `${id.padEnd(28)} ${type.padEnd(10)} ${updated}  ${title}  ${tags}${mark}`;

    const before = await inProcess(['list', ...base], '2026-09-30T21:59:59Z');
    assert.equal(before.code, 0, before.err);
    assert.deepEqual(before.out.trimEnd().split('\n'), [
      row('backup-runbook', 'Runbook', '2026-09-10', 'Nightly backup run', '#backup #ops'),
      row('cache-policy', 'Decision', '2026-09-12', 'Cache policy', '#cache'),
      row('service-map', 'Map', '-', 'service-map', '#map'),
      row('old-queue-notes', 'Note', '2026-08-01', 'Retired queue', '#queue', ' [deprecated]'),
    ]);

    const after = await inProcess(['list', ...base], '2026-09-30T22:00:00Z');
    assert.equal(after.out.split('\n')[1], row('cache-policy', 'Decision', '2026-09-12', 'Cache policy', '#cache', ' [stale]'));

    const hits = await inProcess(['search', 'failover', ...base], '2026-09-30T22:00:00Z');
    const lines = hits.out.trimEnd().split('\n');
    assert.match(lines[0] ?? '', /^cache-policy#Decision\s+\d+\.\d+\s+.*\[stale\]$/);
    assert.match(lines[1] ?? '', /^old-queue-notes#Failover\s+\d+\.\d+\s+.*\[deprecated\]$/);

    const json = await inProcess(['list', '--json', ...base], '2026-09-30T22:00:00Z');
    const items: Array<{ id: string; status: string; stale: boolean; type: string; description: string; updated: string }> =
      JSON.parse(json.out);
    const byId = new Map(items.map((i) => [i.id, i]));
    assert.deepEqual(
      [byId.get('cache-policy')?.stale, byId.get('cache-policy')?.status, byId.get('old-queue-notes')?.status],
      [true, 'stable', 'deprecated']
    );
    assert.equal(byId.get('old-queue-notes')?.description, '');
    assert.equal(byId.get('service-map')?.updated, '-');
    assert.ok(items.every((i) => !('kind' in i)));
  } finally {
    removeDir(root);
  }
});
