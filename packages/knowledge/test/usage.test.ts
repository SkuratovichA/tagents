// node --test usage.test.ts
//
// The usage store and the report over it, with no CLI in between. A store is a file in a scratch directory when what is under test is the file (creation, locks, damage), and a database in memory when only the counting is. The clock is passed in, so "29 days ago" is a fixed instant and the suite does not change with the date it runs on.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { test, type TestContext } from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { openDb, reindex } from '../src/db.ts';
import { utcDateOf } from '../src/doc.ts';
import type { Clock } from '../src/search.ts';
import {
  RETENTION_DAYS,
  UsageStoreError,
  appendEvents,
  callerFrom,
  callerFromEnv,
  getEvent,
  hitEvents,
  openUsageDb,
  parsePositive,
  parseSince,
  readUsageRows,
  recordReads,
  usageRows,
  type ReportOptions,
  type UsageEvent,
  type UsageRow,
} from '../src/usage.ts';
import { NODE, PKG, baseEnv, doc, eventsIn, readEvents, removeDir, tmpDir, writeDoc } from './helpers.ts';

const DAY = 86_400_000;
/** 2026-10-20, noon UTC: far from any midnight, so "n days ago" keeps the date it should have. */
const NOW = Date.parse('2026-10-20T12:00:00Z');
const clockAt = (ms: number): Clock => ({ now: () => ms });
const AT_NOW = clockAt(NOW);

const fail = (reason: string): never => assert.fail(`nothing should have gone wrong, but: ${reason}`);

/** A scratch directory that goes when the case ends. */
function scratch(t: TestContext, name: string): string {
  const root = tmpDir(name);
  t.after(() => removeDir(root));
  return root;
}

const get = (docId: string, heading = '', caller: string | null = null): UsageEvent => getEvent(docId, heading, caller);

// ---- the store ---------------------------------------------------------------------------------

test('an event reads back with every column, and the first one creates the file and its directory', (t) => {
  const file = path.join(scratch(t, 'usage-create'), 'deep', 'er', 'knowledge-usage.sqlite');
  assert.equal(fs.existsSync(file), false);
  recordReads(
    file,
    [get('deploy-runbook', 'Rollback', 'builder'), ...hitEvents([{ id: 'mashina-karta' }], null)],
    { now: AT_NOW, report: fail }
  );
  // Closed after the call, so nothing of a write-ahead log is left beside it (looked at before a reader opens it).
  assert.deepEqual(fs.readdirSync(path.dirname(file)), ['knowledge-usage.sqlite']);
  assert.deepEqual(eventsIn(file), [
    { ts: NOW, docId: 'deploy-runbook', heading: 'Rollback', kind: 'get', caller: 'builder' },
    { ts: NOW, docId: 'mashina-karta', heading: '', kind: 'hit', caller: null },
  ]);
});

test('the events of a call are added to the ones already there', (t) => {
  const file = path.join(scratch(t, 'usage-append'), 'u.sqlite');
  recordReads(file, [get('a')], { now: clockAt(NOW - 1000), report: fail });
  recordReads(file, [get('b'), get('c')], { now: AT_NOW, report: fail });
  assert.deepEqual(
    eventsIn(file).map((e) => [e.ts, e.docId]),
    [
      [NOW - 1000, 'a'],
      [NOW, 'b'],
      [NOW, 'c'],
    ]
  );
});

test('a call with no event does not even create the store', (t) => {
  const file = path.join(scratch(t, 'usage-none'), 'u.sqlite');
  recordReads(file, [], { now: AT_NOW, report: fail });
  assert.equal(fs.existsSync(file), false);
});

test('a get is one event with the heading as given, and a search records each document once, in the order of the results', () => {
  assert.deepEqual(getEvent('deploy-runbook', 'Rollback', 'x'), { docId: 'deploy-runbook', heading: 'Rollback', kind: 'get', caller: 'x' });
  const events = hitEvents([{ id: 'b' }, { id: 'a' }, { id: 'b' }, { id: 'a' }, { id: 'c' }], 'y');
  assert.deepEqual(
    events.map((e) => [e.docId, e.heading, e.kind, e.caller]),
    [
      ['b', '', 'hit', 'y'],
      ['a', '', 'hit', 'y'],
      ['c', '', 'hit', 'y'],
    ]
  );
  assert.deepEqual(hitEvents([], null), []);
});

test('a caller is a name that is not empty: the label of a session or the name a client gave, and nobody otherwise', () => {
  assert.equal(callerFrom('builder'), 'builder');
  assert.equal(callerFrom(''), null);
  assert.equal(callerFrom(undefined), null);
  assert.equal(callerFromEnv({ TA_LABEL: 'reviewer' }), 'reviewer');
  assert.equal(callerFromEnv({ TA_LABEL: '' }), null);
  assert.equal(callerFromEnv({}), null);
});

test('recording deletes the events older than 365 days, and only those', (t) => {
  assert.equal(RETENTION_DAYS, 365);
  const file = path.join(scratch(t, 'usage-prune'), 'u.sqlite');
  const db = openUsageDb(file);
  try {
    // Written in the past, each at its own time, so that nothing is pruned on the way in.
    appendEvents(db, [get('old')], clockAt(NOW - 366 * DAY));
    appendEvents(db, [get('recent')], clockAt(NOW - 364 * DAY));
    assert.deepEqual(readEvents(db).map((e) => e.docId), ['old', 'recent']);
    appendEvents(db, [get('now')], AT_NOW);
    assert.deepEqual(readEvents(db).map((e) => e.docId), ['recent', 'now']);
  } finally {
    db.close();
  }
});

const WRITER = `
import { recordReads } from ${JSON.stringify(pathToFileURL(path.join(PKG, 'src', 'usage.ts')).href)};
const [file, count, caller] = process.argv.slice(1);
let lost = 0;
for (let i = 0; i < Number(count); i++) {
  recordReads(file, [{ docId: 'deploy-runbook', heading: '', kind: 'get', caller }], { report: (reason) => { lost += 1; console.error(reason); } });
}
process.exit(lost === 0 ? 0 : 3);
`;

function runWriter(file: string, count: number, caller: string): Promise<{ code: number | null; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(NODE, ['--input-type=module', '-e', WRITER, file, String(count), caller], {
      env: baseEnv(),
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk: string) => {
      stderr += chunk;
    });
    child.once('error', reject);
    child.once('close', (code) => resolve({ code, stderr }));
  });
}

test('two processes recording at once lose nothing', async (t) => {
  const file = path.join(scratch(t, 'usage-race'), 'u.sqlite');
  const [a, b] = await Promise.all([runWriter(file, 25, 'cli'), runWriter(file, 25, 'daemon')]);
  assert.equal(a.code, 0, a.stderr);
  assert.equal(b.code, 0, b.stderr);
  const events = eventsIn(file);
  assert.equal(events.length, 50);
  assert.equal(events.filter((e) => e.caller === 'cli').length, 25);
  assert.equal(events.filter((e) => e.caller === 'daemon').length, 25);
});

// ---- recording is best effort -----------------------------------------------------------------

test('a store that cannot be opened is reported, not thrown', (t) => {
  const root = scratch(t, 'usage-unopenable');
  const blocker = path.join(root, 'a-file');
  fs.writeFileSync(blocker, 'not a directory');
  const reasons: string[] = [];
  recordReads(path.join(blocker, 'u.sqlite'), [get('a')], { now: AT_NOW, report: (r) => reasons.push(r) });
  assert.equal(reasons.length, 1);
  assert.ok(reasons[0] !== undefined && reasons[0] !== '', 'the reason is given');
  // And with nobody to tell, it is silent.
  assert.doesNotThrow(() => recordReads(path.join(blocker, 'u.sqlite'), [get('a')], { now: AT_NOW }));
});

test('a store that stays locked longer than the busy timeout is given up on, and nothing is written', (t) => {
  const file = path.join(scratch(t, 'usage-locked'), 'u.sqlite');
  const holder = openUsageDb(file);
  holder.exec('begin immediate');
  const reasons: string[] = [];
  const started = Date.now();
  try {
    recordReads(file, [get('a')], { now: AT_NOW, report: (r) => reasons.push(r) });
  } finally {
    holder.exec('rollback');
    holder.close();
  }
  const waited = Date.now() - started;
  assert.ok(waited >= 200, `waited for the lock first (${waited} ms)`);
  assert.ok(waited < 3000, `and then gave up (${waited} ms)`);
  assert.equal(reasons.length, 1);
  assert.match(reasons[0] ?? '', /locked/);
  assert.deepEqual(eventsIn(file), []);
});

test('a file that is not a database is reported and left as it was', (t) => {
  const file = path.join(scratch(t, 'usage-damaged'), 'u.sqlite');
  const content = 'this is not a database, only text\n'.repeat(40);
  fs.writeFileSync(file, content);
  const reasons: string[] = [];
  recordReads(file, [get('a')], { now: AT_NOW, report: (r) => reasons.push(r) });
  assert.equal(reasons.length, 1);
  assert.equal(fs.readFileSync(file, 'utf8'), content);
});

// ---- the report -------------------------------------------------------------------------------

type When = number | string;
type Seed = readonly [id: string, kind: 'get' | 'hit', when: When];

/** A usage store in memory. `when` is a number of days before NOW, or an ISO instant. */
function seeded(events: readonly Seed[]): DatabaseSync {
  const db = openUsageDb(':memory:');
  const insert = db.prepare("insert into usage_events (ts, doc_id, heading, kind, caller) values (?, ?, '', ?, null)");
  for (const [id, kind, when] of events) insert.run(typeof when === 'string' ? Date.parse(when) : Math.round(NOW - when * DAY), id, kind);
  return db;
}

/** `n` events of one kind for one document, a day ago. */
function times(id: string, kind: 'get' | 'hit', n: number, when: When = 1): Seed[] {
  return Array.from({ length: n }, () => [id, kind, when] as const);
}

interface Page {
  readonly id: string;
  readonly kind?: string;
  readonly status?: string;
}

/** An index in memory over a folder of one small document per page. */
function indexed(t: TestContext, pages: readonly Page[]): DatabaseSync {
  const root = scratch(t, 'usage-docs');
  for (const p of pages) {
    const fields = { id: p.id, kind: p.kind ?? 'note', ...(p.status === undefined ? {} : { extra: `status: ${p.status}` }) };
    writeDoc(root, `${p.id}.md`, doc(fields));
  }
  const db = openDb(':memory:');
  reindex(db, root);
  t.after(() => db.close());
  return db;
}

function rows(index: DatabaseSync, events: readonly Seed[], options: ReportOptions = {}): UsageRow[] {
  const usage = seeded(events);
  try {
    return usageRows(index, usage, { now: AT_NOW, ...options });
  } finally {
    usage.close();
  }
}

test('the report lists a read document first with its counts, an unread one after it with zeros', (t) => {
  const index = indexed(t, [
    { id: 'deploy-runbook', kind: 'runbook' },
    { id: 'mashina-karta', kind: 'map' },
  ]);
  const events: Seed[] = [
    // Four gets on two UTC dates: three on 10-17 (07:12, 09:36, 12:00) and one on 10-18.
    ['deploy-runbook', 'get', 3.2],
    ['deploy-runbook', 'get', 3.1],
    ['deploy-runbook', 'get', 3],
    ['deploy-runbook', 'get', 2],
    ['deploy-runbook', 'hit', 1],
  ];
  assert.deepEqual(rows(index, events), [
    { id: 'deploy-runbook', type: 'Runbook', status: 'stable', gets: 4, hits: 1, days: 2, last: '2026-10-18' },
    { id: 'mashina-karta', type: 'Map', status: 'stable', gets: 0, hits: 0, days: 0, last: null },
  ]);
});

test('rows are sorted by gets, then hits, then id', (t) => {
  const index = indexed(t, ['a', 'b', 'c', 'd', 'e', 'f'].map((id) => ({ id })));
  const events = [
    ...times('d', 'get', 5),
    ...times('a', 'get', 2),
    ...times('b', 'get', 2),
    ...times('b', 'hit', 3),
    ...times('c', 'get', 2),
    ...times('c', 'hit', 3),
    ...times('f', 'hit', 1),
  ];
  assert.deepEqual(rows(index, events).map((r) => r.id), ['d', 'b', 'c', 'a', 'f', 'e']);
});

test('the window keeps events up to its edge, and last ignores the window', (t) => {
  const index = indexed(t, [{ id: 'w' }]);
  const events: Seed[] = [['w', 'get', 31], ['w', 'get', 29]];
  assert.deepEqual(rows(index, events), [{ id: 'w', type: 'Note', status: 'stable', gets: 1, hits: 0, days: 1, last: '2026-09-21' }]);
  assert.equal(rows(index, events, { sinceDays: 60 })[0]?.gets, 2);
  assert.equal(rows(index, events, { sinceDays: 10 })[0]?.gets, 0);
  assert.equal(rows(index, events, { sinceDays: 10 })[0]?.last, '2026-09-21');

  const exactly = new Date(NOW - 30 * DAY).toISOString();
  const justOver = new Date(NOW - 30 * DAY - 1).toISOString();
  assert.equal(rows(index, [['w', 'get', exactly]])[0]?.gets, 1, 'an event exactly 30 days old is inside the window');
  assert.equal(rows(index, [['w', 'get', justOver]])[0]?.gets, 0, 'a millisecond older is out');
});

test('days are distinct UTC dates, whatever the hours between the events', (t) => {
  const index = indexed(t, [{ id: 'd' }]);
  const same = ['2026-10-17T01:00:00Z', '2026-10-17T21:00:00Z'];
  const across = ['2026-10-17T23:30:00Z', '2026-10-18T00:30:00Z'];
  const gets = (stamps: readonly string[]): Seed[] => stamps.map((s) => ['d', 'get', s] as const);
  assert.equal(rows(index, gets(same))[0]?.days, 1, 'twenty hours apart on one date is one day');
  assert.equal(rows(index, gets(across))[0]?.days, 2, 'an hour apart over midnight is two');
  assert.equal(rows(index, [...gets(same), ...gets(across)])[0]?.days, 2);
  assert.equal(rows(index, [...gets(same), ...gets(across)])[0]?.gets, 4);
});

test('hits count as hits only: they make neither days nor last', (t) => {
  const index = indexed(t, [{ id: 'h' }]);
  const [row] = rows(index, times('h', 'hit', 3, 2));
  assert.deepEqual(row, { id: 'h', type: 'Note', status: 'stable', gets: 0, hits: 3, days: 0, last: null });
  // A newer hit does not move the date of the last get.
  assert.equal(rows(index, [['h', 'get', 5], ['h', 'hit', 1]])[0]?.last, '2026-10-15');
});

test('a document read only long ago has no gets in the window and still shows when it was last read', (t) => {
  const index = indexed(t, [{ id: 'o' }]);
  assert.deepEqual(rows(index, [['o', 'get', 100]]), [{ id: 'o', type: 'Note', status: 'stable', gets: 0, hits: 0, days: 0, last: '2026-07-12' }]);
});

test('an id that is no longer in the folder is listed only with all, and never with a type', (t) => {
  const index = indexed(t, [{ id: 'kept', kind: 'runbook' }, { id: 'other', kind: 'map' }]);
  const events = [...times('gone', 'get', 3), ...times('kept', 'get', 1)];
  assert.deepEqual(rows(index, events).map((r) => r.id), ['kept', 'other']);
  const all = rows(index, events, { all: true });
  assert.deepEqual(all.map((r) => r.id), ['gone', 'kept', 'other']);
  assert.deepEqual(all[0], { id: 'gone', type: null, status: null, gets: 3, hits: 0, days: 1, last: '2026-10-19' });
  assert.deepEqual(rows(index, events, { all: true, type: 'runbook' }).map((r) => r.id), ['kept']);
});

test('an empty type filters nothing, as it does for list and search, so all still lists the ids that left the folder', (t) => {
  const index = indexed(t, [{ id: 'kept', kind: 'runbook' }, { id: 'other', kind: 'map' }]);
  const events = [...times('gone', 'get', 3), ...times('kept', 'get', 1)];
  assert.deepEqual(rows(index, events, { type: '' }), rows(index, events));
  assert.deepEqual(rows(index, events, { all: true, type: '' }), rows(index, events, { all: true }));
  assert.deepEqual(rows(index, events, { all: true, type: '' }).map((r) => r.id), ['gone', 'kept', 'other']);
});

test('a date of the report is the UTC date utcDateOf gives the same instant, one calendar for every date the package shows', (t) => {
  const index = indexed(t, [{ id: 'u' }]);
  const stamps = [
    '2026-10-17T23:59:59Z',
    '2026-10-18T00:00:00Z',
    '2026-10-18T02:30:00+03:00',
    '2026-10-17T22:30:00-05:00',
    '2026-02-28T23:30:00-02:00',
  ];
  for (const stamp of stamps) {
    const expected = utcDateOf(stamp);
    assert.notEqual(expected, null, stamp);
    assert.equal(rows(index, [['u', 'get', stamp]])[0]?.last, expected, stamp);
  }
});

test('a type keeps the documents of that type, matched the way list matches it', (t) => {
  const index = indexed(t, [{ id: 'a', kind: 'runbook' }, { id: 'b', kind: 'Runbook' }, { id: 'c', kind: 'map' }]);
  for (const type of ['runbook', 'RUNBOOK', 'Runbook']) assert.deepEqual(rows(index, [], { type }).map((r) => r.id), ['a', 'b'], type);
});

test('top limits the lines after the sort, and defaults to 20', (t) => {
  const ids = Array.from({ length: 25 }, (_, i) => `doc-${String(i).padStart(2, '0')}`);
  const index = indexed(t, ids.map((id) => ({ id })));
  const events = times('doc-24', 'get', 1);
  assert.equal(rows(index, events).length, 20);
  assert.equal(rows(index, events)[0]?.id, 'doc-24', 'the one read comes first although its id sorts last');
  assert.deepEqual(rows(index, events, { top: 3 }).map((r) => r.id), ['doc-24', 'doc-00', 'doc-01']);
  assert.equal(rows(index, events, { top: 50 }).length, 25);
});

// Five gets on three UTC dates, as the spec's threshold case.
const FIVE_ON_THREE_DATES: readonly When[] = [1, 1.1, 2, 3, 3.1];
const gets = (id: string, whens: readonly When[]): Seed[] => whens.map((w) => [id, 'get', w] as const);

test('candidates need enough gets on enough dates inside the window', (t) => {
  const index = indexed(t, ['ok', 'two-dates', 'four-gets', 'old'].map((id) => ({ id })));
  const events = [
    ...gets('ok', FIVE_ON_THREE_DATES),
    ...gets('two-dates', [1, 1.1, 1.2, 2, 2.1]),
    ...gets('four-gets', [1, 2, 3, 3.1]),
    ...gets('old', [40, 40.1, 41, 42, 42.1]),
  ];
  assert.deepEqual(rows(index, events, { candidates: true }).map((r) => [r.id, r.gets, r.days]), [['ok', 5, 3]]);
});

test('hits and deprecated documents are never candidates, and neither is an id that left the folder', (t) => {
  const index = indexed(t, [{ id: 'retired', status: 'deprecated' }, { id: 'chatty' }, { id: 'live' }]);
  const events = [
    ...gets('retired', [1, 1.1, 2, 2.1, 3, 3.1, 4, 4.1, 5]),
    ...gets('chatty', [1, 2]),
    ...times('chatty', 'hit', 40),
    ...gets('gone', [1, 1.1, 2, 2.1, 3, 3.1, 4, 4.1, 5]),
    ...gets('live', FIVE_ON_THREE_DATES),
  ];
  assert.deepEqual(rows(index, events, { candidates: true }).map((r) => r.id), ['live']);
  assert.deepEqual(rows(index, events, { candidates: true, all: true }).map((r) => r.id), ['live']);
});

test('the thresholds can be set by the caller', (t) => {
  const index = indexed(t, ['two-gets', 'one-get', 'six-gets'].map((id) => ({ id })));
  const events = [...gets('two-gets', [1, 1.1]), ...gets('one-get', [1]), ...times('six-gets', 'get', 6)];
  assert.deepEqual(rows(index, events, { candidates: true, minGets: 2, minDays: 1 }).map((r) => r.id), ['six-gets', 'two-gets']);
  assert.deepEqual(rows(index, events, { candidates: true, minGets: 6, minDays: 1 }).map((r) => r.id), ['six-gets']);
  assert.deepEqual(rows(index, events, { candidates: true, minGets: 2, minDays: 2 }).map((r) => r.id), []);
});

test('rows hold exactly the seven keys of the report, in order', (t) => {
  const index = indexed(t, [{ id: 'x' }]);
  assert.deepEqual(Object.keys(rows(index, [])[0] ?? {}), ['id', 'type', 'status', 'gets', 'hits', 'days', 'last']);
});

// ---- the store on disk, for the report --------------------------------------------------------

test('a store that does not exist holds no events, and reading it does not create it', (t) => {
  const root = scratch(t, 'usage-missing');
  const index = indexed(t, [{ id: 'a' }]);
  const file = path.join(root, 'not', 'yet', 'u.sqlite');
  assert.deepEqual(readUsageRows(index, file, { now: AT_NOW }), [{ id: 'a', type: 'Note', status: 'stable', gets: 0, hits: 0, days: 0, last: null }]);
  assert.equal(fs.existsSync(path.join(root, 'not')), false);
});

test('a file with nothing in it yet is an empty store, and is not touched', (t) => {
  const file = path.join(scratch(t, 'usage-empty'), 'u.sqlite');
  fs.writeFileSync(file, '');
  const index = indexed(t, [{ id: 'a' }]);
  assert.equal(readUsageRows(index, file, { now: AT_NOW })[0]?.gets, 0);
  assert.equal(fs.statSync(file).size, 0);
});

test('a store written by recordReads is read back by the report', (t) => {
  const file = path.join(scratch(t, 'usage-roundtrip'), 'u.sqlite');
  const index = indexed(t, [{ id: 'a' }, { id: 'b' }]);
  recordReads(file, [get('b', 'Part'), get('b'), ...hitEvents([{ id: 'a' }], null)], { now: clockAt(NOW - DAY), report: fail });
  assert.deepEqual(readUsageRows(index, file, { now: AT_NOW }), [
    { id: 'b', type: 'Note', status: 'stable', gets: 2, hits: 0, days: 1, last: '2026-10-19' },
    { id: 'a', type: 'Note', status: 'stable', gets: 0, hits: 1, days: 0, last: null },
  ]);
});

test('a store that cannot be read is an error that names the file, and is left as it was', (t) => {
  const file = path.join(scratch(t, 'usage-bad'), 'u.sqlite');
  const content = 'text, not a database\n'.repeat(40);
  fs.writeFileSync(file, content);
  const index = indexed(t, [{ id: 'a' }]);
  assert.throws(
    () => readUsageRows(index, file, { now: AT_NOW }),
    (e: unknown) => e instanceof UsageStoreError && e.file === file && e.message.includes(file)
  );
  assert.equal(fs.readFileSync(file, 'utf8'), content);
});

// ---- the flags' values ------------------------------------------------------------------------

test('a window is a positive whole number of days written with a d', () => {
  assert.equal(parseSince('30d'), 30);
  assert.equal(parseSince('1d'), 1);
  assert.equal(parseSince('365d'), 365);
  for (const bad of ['30', '0d', 'soon', '-3d', '1.5d', '', 'd', '30D', ' 30d', '30d ', '3 0d', '99999999999999999999d']) {
    assert.equal(parseSince(bad), null, JSON.stringify(bad));
  }
});

test('a count is a positive whole number', () => {
  assert.equal(parsePositive('1'), 1);
  assert.equal(parsePositive('20'), 20);
  for (const bad of ['0', '-1', 'many', '', '1.5', '2e3', ' 4', '4 ', '99999999999999999999']) {
    assert.equal(parsePositive(bad), null, JSON.stringify(bad));
  }
});
