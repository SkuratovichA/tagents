// The CLI: what it prints, and what it exits with.
//
// Every case runs the real binary in a child process with a temp knowledge
// folder and a temp index, because the exit code IS the contract: a caller in
// a shell script branches on 4 (nothing found) without reading a word.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { z } from 'zod';
import { main } from '../src/cli/main.ts';
import type { Clock } from '../src/search.ts';
import { getEvent, hitEvents, recordReads, type UsageEvent } from '../src/usage.ts';
import {
  IdRows,
  KNOWLEDGE,
  OKF,
  UsageRows,
  copyKnowledge,
  doc,
  recordedEvents,
  removeDir,
  runCli,
  tmpDir,
  writeDoc,
} from './helpers.ts';

type Env = Record<string, string>;

function corpus(name: string): { env: Env; dir: string; root: string; usage: string; cleanup: () => void } {
  const root = tmpDir(name);
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  return {
    dir,
    root,
    // Where the usage store lands when nothing names it: beside the index.
    usage: path.join(root, 'knowledge-usage.sqlite'),
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
    assert.match(unset.stderr, /config\.toml/);

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
    const both = runCli(['list', '--type', 'map', '--kind', 'runbook'], env).stdout.trim().split('\n');
    assert.equal(both.length, 1);
    assert.match(both[0] ?? '', /^mashina-karta\s/);
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

// ---- the usage store: what a read leaves behind ----------------------------------------------------

test('show records one get for a call that returns text: the id, the heading as the document writes it, nobody', () => {
  const { env, usage, cleanup } = corpus('cli-record-show');
  try {
    assert.equal(runCli(['show', 'no-such-document'], env).code, 4);
    assert.equal(runCli(['show', 'deploy-runbook#no-such-section'], env).code, 4);
    assert.equal(fs.existsSync(usage), false, 'a call that failed records nothing and creates nothing');

    assert.equal(runCli(['show', 'deploy-runbook'], env).code, 0);
    assert.equal(runCli(['show', 'deploy-runbook#rollback'], env).code, 0);
    assert.deepEqual(
      recordedEvents(usage).map((e) => [e.docId, e.heading, e.kind, e.caller]),
      [
        ['deploy-runbook', '', 'get', null],
        ['deploy-runbook', 'Rollback', 'get', null],
      ]
    );
  } finally {
    cleanup();
  }
});

test('search records one hit for each distinct document it returns, however many sections matched, and never the query', () => {
  const { env, dir, usage, cleanup } = corpus('cli-record-search');
  try {
    writeDoc(dir, 'fish-notes.md', doc({ id: 'fish-notes' }, 'About zebrafish.\n\n## Care\n\nZebrafish need warm water.\n\n## Food\n\nFeed zebrafish daily.\n'));
    writeDoc(dir, 'tank-notes.md', doc({ id: 'tank-notes' }, 'A tank for zebrafish.\n'));

    const found = runCli(['search', 'zebrafish', '--json'], env);
    assert.equal(found.code, 0, found.stderr);
    const hits = IdRows.parse(JSON.parse(found.stdout));
    const ids = [...new Set(hits.map((h) => h.id))];
    assert.ok(hits.length > ids.length, 'one document answered with several of its sections');
    assert.deepEqual([...ids].sort(), ['fish-notes', 'tank-notes']);
    assert.deepEqual(
      recordedEvents(usage).map((e) => [e.docId, e.heading, e.kind]),
      ids.map((id) => [id, '', 'hit'])
    );
    assert.ok(!JSON.stringify(recordedEvents(usage)).includes('zebrafish'), 'the query is in no column of any row');
  } finally {
    cleanup();
  }
});

test('a search that finds nothing records nothing', () => {
  const { env, usage, cleanup } = corpus('cli-record-nothing');
  try {
    assert.equal(runCli(['search', 'qqqzzzxxx'], env).code, 4);
    assert.equal(runCli(['search', 'qqqzzzxxx', '--json'], env).code, 4);
    assert.equal(fs.existsSync(usage), false);
  } finally {
    cleanup();
  }
});

test('search prints what it printed before, whatever the usage store holds: usage does not rank', () => {
  const { env, dir, usage, cleanup } = corpus('cli-no-rank');
  try {
    const body = 'Where the trout sleeps in winter.\n';
    writeDoc(dir, 'perch-notes.md', doc({ id: 'perch-notes', title: 'Pond notes' }, body));
    writeDoc(dir, 'trout-notes.md', doc({ id: 'trout-notes', title: 'Pond notes' }, body));
    const ask = (): string => {
      const r = runCli(['search', 'winter', '--json'], env);
      assert.equal(r.code, 0, r.stderr);
      return r.stdout;
    };

    const before = ask();
    const ids = IdRows.parse(JSON.parse(before));
    assert.deepEqual(
      ids.map((h) => h.id),
      ['perch-notes', 'trout-notes'],
      'they tie on score, so the id decides, and the one that is read is the one that sorts second'
    );
    recordReads(usage, Array.from({ length: 60 }, () => [getEvent('trout-notes', '', 'reader'), ...hitEvents([{ id: 'trout-notes' }], 'reader')]).flat());
    assert.ok(recordedEvents(usage).length >= 120, 'the store holds what was read');
    assert.equal(ask(), before);
  } finally {
    cleanup();
  }
});

test('a usage store that cannot be written changes neither stdout nor the exit code, and is named only with --verbose', () => {
  const { env, root, usage, cleanup } = corpus('cli-record-fails');
  try {
    // Below a regular file: the store can be neither opened nor created.
    const blocker = path.join(root, 'a-file');
    fs.writeFileSync(blocker, 'not a directory');
    const broken = path.join(blocker, 'usage.sqlite');
    const failing = { ...env, TAGENTS_KNOWLEDGE_USAGE_DB: broken };

    for (const args of [['show', 'deploy-runbook'], ['search', 'rollback']]) {
      const clean = runCli(args, env);
      assert.equal(clean.code, 0, clean.stderr);
      const silent = runCli(args, failing);
      assert.equal(silent.code, clean.code, args.join(' '));
      assert.equal(silent.stdout, clean.stdout, args.join(' '));
      assert.equal(silent.stderr, '', `${args.join(' ')}: nothing on stderr without --verbose`);

      const loud = runCli([...args, '--verbose'], failing);
      assert.equal(loud.code, 0, loud.stderr);
      assert.equal(loud.stdout, clean.stdout, args.join(' '));
      assert.ok(loud.stderr.includes(broken), `${args.join(' ')}: stderr names the store: ${loud.stderr}`);
    }

    const fine = runCli(['show', 'deploy-runbook', '--verbose'], env);
    assert.equal(fine.stderr, '', '--verbose says nothing when the event was recorded');
    assert.ok(recordedEvents(usage).length > 0);
  } finally {
    cleanup();
  }
});

test('the usage store sits beside the index in use, unless a flag or a variable names another file', () => {
  const { env, root, usage, cleanup } = corpus('cli-locate');
  try {
    const moved = path.join(root, 'moved');
    runCli(['show', 'deploy-runbook', '--db', path.join(moved, 'index.sqlite')], env);
    assert.equal(recordedEvents(path.join(moved, 'knowledge-usage.sqlite')).length, 1, 'beside an index chosen by --db');
    assert.equal(fs.existsSync(usage), false);

    const a = path.join(root, 'a', 'usage.sqlite');
    const b = path.join(root, 'b', 'usage.sqlite');
    runCli(['show', 'deploy-runbook', '--usage-db', a], { ...env, TAGENTS_KNOWLEDGE_USAGE_DB: b });
    assert.equal(recordedEvents(a).length, 1, 'the flag outranks the variable');
    assert.equal(fs.existsSync(b), false);
    runCli(['show', 'deploy-runbook'], { ...env, TAGENTS_KNOWLEDGE_USAGE_DB: b });
    assert.equal(recordedEvents(b).length, 1, 'the variable alone');
    assert.equal(recordedEvents(a).length, 1);
    assert.equal(fs.existsSync(usage), false);

    runCli(['show', 'deploy-runbook'], env);
    assert.equal(recordedEvents(usage).length, 1, 'beside an index chosen by TAGENTS_KNOWLEDGE_DB');
  } finally {
    cleanup();
  }
});

test('the caller of a CLI event is TA_LABEL when it is set and not empty', () => {
  const { env, usage, cleanup } = corpus('cli-caller');
  try {
    runCli(['show', 'deploy-runbook'], { ...env, TA_LABEL: 'builder' });
    runCli(['show', 'deploy-runbook'], { ...env, TA_LABEL: '' });
    runCli(['search', 'rollback'], { ...env, TA_LABEL: 'reviewer' });
    runCli(['show', 'deploy-runbook'], env);
    const events = recordedEvents(usage);
    assert.deepEqual(events.filter((e) => e.kind === 'get').map((e) => e.caller), ['builder', null, null]);
    const hits = events.filter((e) => e.kind === 'hit');
    assert.ok(hits.length > 0 && hits.every((e) => e.caller === 'reviewer'));
  } finally {
    cleanup();
  }
});

test('index, list, lint, toc and usage record nothing, so a report is not a read', () => {
  const { env, usage, cleanup } = corpus('cli-record-none');
  try {
    // lint may well find something to say about the fixtures; the exit code is not what is looked at here.
    for (const args of [['index'], ['index', '--full'], ['list'], ['list', '--json'], ['lint'], ['toc'], ['usage'], ['usage', '--json']]) {
      runCli(args, env);
      assert.equal(fs.existsSync(usage), false, `${args.join(' ')} created the store`);
    }
    runCli(['show', 'deploy-runbook'], env);
    const first = runCli(['usage', '--json'], env);
    const second = runCli(['usage', '--json'], env);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(second.stdout, first.stdout, 'the same counts twice in a row');
    assert.equal(recordedEvents(usage).length, 1, 'neither report added an event');
  } finally {
    cleanup();
  }
});

test('events outlive the index: index --full and the loss of the index file leave them as they were', () => {
  const { env, root, usage, cleanup } = corpus('cli-survive');
  try {
    runCli(['show', 'deploy-runbook#Rollback'], env);
    const before = recordedEvents(usage);
    assert.equal(before.length, 1);

    assert.equal(runCli(['index', '--full'], env).code, 0);
    for (const name of ['index.sqlite', 'index.sqlite-wal', 'index.sqlite-shm']) fs.rmSync(path.join(root, name), { force: true });
    assert.equal(runCli(['list'], env).code, 0, 'a read builds the index again');
    assert.equal(fs.existsSync(path.join(root, 'index.sqlite')), true);
    assert.deepEqual(recordedEvents(usage), before);
  } finally {
    cleanup();
  }
});

// ---- the usage verb ----------------------------------------------------------------------------------

const NOW = '2026-10-20T12:00:00Z';
const DAY = 86_400_000;

/** Record `events` as if they had been read `daysAgo` days (and `plusHours` hours) before NOW. */
function seed(file: string, daysAgo: number, events: readonly UsageEvent[], plusHours = 0): void {
  const clock: Clock = { now: () => Date.parse(NOW) - daysAgo * DAY + plusHours * 3_600_000 };
  recordReads(file, events, { now: clock, report: (reason) => assert.fail(reason) });
}

const get = (docId: string, heading = ''): UsageEvent => getEvent(docId, heading, null);

/** The fixture folder with the usage of a week: `deploy-runbook` read four times on two UTC dates, matched once. */
function busyWeek(name: string): { base: string[]; usage: string; cleanup: () => void } {
  const { dir, root, usage, cleanup } = corpus(name);
  seed(usage, 1, [get('deploy-runbook')]);
  seed(usage, 1, [get('deploy-runbook')], 1);
  seed(usage, 2, [get('deploy-runbook')]);
  seed(usage, 2, [get('deploy-runbook')], 1);
  seed(usage, 0, hitEvents([{ id: 'deploy-runbook' }], null));
  return { base: ['--dir', dir, '--db', path.join(root, 'index.sqlite'), '--usage-db', usage], usage, cleanup };
}

/** A line of the report, cut into its columns: they are at least two spaces apart. */
const cells = (line: string): string[] => line.trim().split(/ {2,}/);

test('usage prints a header and a line per document, the busiest first, with - for what is unknown', async () => {
  const { base, cleanup } = busyWeek('cli-usage-table');
  try {
    const r = await inProcess(['usage', ...base], NOW);
    assert.equal(r.code, 0, r.err);
    assert.equal(r.err, '');
    const lines = r.out.trimEnd().split('\n');
    assert.deepEqual(cells(lines[0] ?? ''), ['id', 'type', 'status', 'gets', 'hits', 'days', 'last']);
    assert.deepEqual(cells(lines[1] ?? ''), ['deploy-runbook', 'Runbook', 'stable', '4', '1', '2', '2026-10-19']);
    assert.deepEqual(
      lines.slice(2).map((l) => cells(l)[0]),
      ['mashina-karta', 'relizy-zametki', 'sqlite-over-vectors', 'tmux-cheatsheet'],
      'the unread ones follow, by id'
    );
    for (const line of lines.slice(2)) assert.deepEqual(cells(line).slice(3), ['0', '0', '0', '-']);

    const top = await inProcess(['usage', '--top', '2', ...base], NOW);
    assert.equal(top.out.trimEnd().split('\n').length, 3, 'the header and two lines');
  } finally {
    cleanup();
  }
});

test('usage --json is an array of objects with exactly seven keys, and no row left is exit 4', async () => {
  const { base, cleanup } = busyWeek('cli-usage-json');
  try {
    const r = await inProcess(['usage', '--json', ...base], NOW);
    assert.equal(r.code, 0, r.err);
    // A record, not UsageRows: an object schema hands its keys back in its own order, and the order of the keys is under test.
    const rows = z.array(z.record(z.string(), z.unknown())).parse(JSON.parse(r.out));
    assert.equal(rows.length, 5);
    for (const row of rows) assert.deepEqual(Object.keys(row), ['id', 'type', 'status', 'gets', 'hits', 'days', 'last']);
    assert.deepEqual(rows[0], { id: 'deploy-runbook', type: 'Runbook', status: 'stable', gets: 4, hits: 1, days: 2, last: '2026-10-19' });
    assert.deepEqual(rows[1], { id: 'mashina-karta', type: 'Map', status: 'stable', gets: 0, hits: 0, days: 0, last: null });

    const none = await inProcess(['usage', '--candidates', '--json', ...base], NOW);
    assert.equal(none.code, 4);
    assert.equal(none.out.trim(), '[]');

    const quiet = await inProcess(['usage', '--candidates', ...base], NOW);
    assert.equal(quiet.code, 4);
    assert.equal(quiet.out, '');
    assert.notEqual(quiet.err.trim(), '', 'a sentence on stderr');
  } finally {
    cleanup();
  }
});

test('a bad --since, --top, --min-gets or --min-days is exit 2 and names the flag', async () => {
  const { base, cleanup } = busyWeek('cli-usage-flags');
  try {
    const bad: Array<[string, string]> = [
      ['--since', '30'],
      ['--since', '0d'],
      ['--since', 'soon'],
      ['--top', '0'],
      ['--top', 'many'],
      ['--min-gets', '0'],
      ['--min-days', 'x'],
    ];
    for (const [flag, value] of bad) {
      const r = await inProcess(['usage', flag, value, ...base], NOW);
      assert.equal(r.code, 2, `${flag} ${value}`);
      assert.ok(r.err.includes(flag), `${flag} ${value}: ${r.err}`);
      assert.equal(r.out, '');
    }
    assert.equal((await inProcess(['usage', '--since', '90d', '--top', '3', '--min-gets', '1', '--min-days', '1', ...base], NOW)).code, 0);
  } finally {
    cleanup();
  }
});

test('usage lists an id that left the folder only with --all, and --type drops it', async () => {
  const { base, usage, cleanup } = busyWeek('cli-usage-orphans');
  try {
    seed(usage, 1, [get('old-runbook'), get('old-runbook'), get('old-runbook'), get('old-runbook'), get('old-runbook')]);
    const ids = async (...extra: string[]): Promise<string[]> => {
      const rows = IdRows.parse(JSON.parse((await inProcess(['usage', '--json', ...base, ...extra], NOW)).out));
      return rows.map((row) => row.id);
    };
    assert.ok(!(await ids()).includes('old-runbook'));
    assert.deepEqual((await ids('--all')).slice(0, 2), ['old-runbook', 'deploy-runbook']);
    const all = UsageRows.parse(JSON.parse((await inProcess(['usage', '--json', '--all', ...base], NOW)).out));
    assert.deepEqual(all[0], { id: 'old-runbook', type: null, status: null, gets: 5, hits: 0, days: 1, last: '2026-10-19' });
    assert.deepEqual(await ids('--all', '--type', 'runbook'), ['deploy-runbook']);
  } finally {
    cleanup();
  }
});

test('usage --candidates names the documents read often enough on enough days, and takes its own thresholds', async () => {
  const { base, usage, cleanup } = busyWeek('cli-usage-candidates');
  try {
    seed(usage, 3, [get('deploy-runbook')]);
    const ids = async (...extra: string[]): Promise<string[]> => {
      const r = await inProcess(['usage', '--json', '--candidates', ...base, ...extra], NOW);
      const rows = IdRows.parse(JSON.parse(r.out));
      return rows.map((row) => row.id);
    };
    assert.deepEqual(await ids(), ['deploy-runbook'], '5 gets on 3 dates');
    assert.equal((await inProcess(['usage', '--candidates', '--json', '--min-gets', '6', ...base], NOW)).code, 4);
    assert.equal((await inProcess(['usage', '--candidates', '--json', '--min-days', '4', ...base], NOW)).code, 4);
    assert.deepEqual(await ids('--min-gets', '2', '--min-days', '1'), ['deploy-runbook']);
  } finally {
    cleanup();
  }
});

test('the days of a document are UTC dates, whatever zone the machine is in', () => {
  const { env, usage, cleanup } = corpus('cli-usage-zone');
  try {
    // Two reads half an hour either side of a UTC midnight five days back: two UTC dates, yet one calendar day in a zone nine hours ahead and in one eight hours behind.
    const midnight = Math.floor(Date.now() / DAY) * DAY - 5 * DAY;
    for (const ts of [midnight - 1_800_000, midnight + 1_800_000]) {
      recordReads(usage, [get('deploy-runbook')], { now: { now: () => ts }, report: (reason) => assert.fail(reason) });
    }
    const utcDate = new Date(midnight).toISOString().slice(0, 10);
    // POSIX zone strings need no zone database on the machine, and Node and SQLite both read them.
    for (const TZ of ['UTC', 'JST-9', 'PST8']) {
      const r = runCli(['usage', '--json'], { ...env, TZ });
      assert.equal(r.code, 0, r.stderr);
      const row = UsageRows.parse(JSON.parse(r.stdout)).find((candidate) => candidate.id === 'deploy-runbook');
      assert.deepEqual([row?.days, row?.last], [2, utcDate], TZ);
    }
  } finally {
    cleanup();
  }
});

test('a usage store that is not there counts as empty and is not made; a damaged one exits 1 and is named', async () => {
  const { dir, root, usage, cleanup } = corpus('cli-usage-missing');
  try {
    const base = ['--dir', dir, '--db', path.join(root, 'index.sqlite'), '--usage-db', usage];
    const missing = await inProcess(['usage', '--json', ...base], NOW);
    assert.equal(missing.code, 0, missing.err);
    const rows = UsageRows.parse(JSON.parse(missing.out));
    assert.equal(rows.length, 5);
    assert.ok(rows.every((row) => row.gets === 0));
    assert.equal(fs.existsSync(usage), false, 'a report does not make the store');

    const garbage = 'this is text, not a database\n';
    fs.writeFileSync(usage, garbage);
    const damaged = await inProcess(['usage', ...base], NOW);
    assert.equal(damaged.code, 1);
    assert.ok(damaged.err.includes(usage), damaged.err);
    assert.equal(damaged.out, '');
    assert.equal(fs.readFileSync(usage, 'utf8'), garbage, 'and it is left as it was');
  } finally {
    cleanup();
  }
});
