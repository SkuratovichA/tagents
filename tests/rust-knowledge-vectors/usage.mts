// The usage section of the knowledge vectors: what the store keeps of the events it is given, what the reports make of them, and what a store that cannot be opened or read does.
//
// The index the reports join with is built by the node code over a folder of six documents; the events are explicit batches at explicit clocks, so the retention, the window and the dates of `last` are the same at every run.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { openDb, reindex, silenceSqliteWarning } from '../../packages/knowledge/src/db.ts';
import {
  UsageStoreError,
  appendEvents,
  openUsageDb,
  parsePositive,
  parseSince,
  readUsageRows,
  recordReads,
  type ReportOptions,
  type UsageEvent,
} from '../../packages/knowledge/src/usage.ts';
import { NOW, lcg, plain, relativize, scratch, writeFiles, type CorpusFile } from './util.mts';

const DAY = 86_400_000;
const doc = (front: string): string => `---\n${front}\n---\n## Section\nbody\n`;

const FILES: CorpusFile[] = [
  { name: 'alpha.md', text: doc('type: Note\ntitle: Alpha') },
  { name: 'beta.md', text: doc('type: Runbook\ntitle: Beta') },
  { name: 'gamma.md', text: doc('type: Runbook\ntitle: Gamma\nstatus: deprecated') },
  { name: 'delta.md', text: doc('type: Note\ntitle: Delta\nstatus: draft') },
  { name: 'epsilon.md', text: doc('type: Заметка\ntitle: Epsilon') },
  { name: 'unread.md', text: doc('type: Note\ntitle: Unread') },
];

const ev = (docId: string, kind: 'get' | 'hit', caller: string | null = 'client', heading = ''): UsageEvent => ({ docId, heading, kind, caller });

/** Batches of events and the clock each was recorded at: the first is older than the retention of every later one. */
const BATCHES: ReadonlyArray<{ readonly now: number; readonly events: readonly UsageEvent[] }> = [
  { now: NOW - 400 * DAY, events: [ev('alpha', 'get'), ev('alpha', 'get'), ev('ancient', 'get', null)] },
  { now: NOW - 370 * DAY, events: [ev('beta', 'get', null, 'Section')] },
  { now: NOW - 60 * DAY, events: [ev('alpha', 'get'), ev('gamma', 'get'), ev('gone-b', 'get', 'старый')] },
  { now: NOW - 40 * DAY, events: [ev('beta', 'hit'), ev('beta', 'get', 'a'), ev('delta', 'hit')] },
  { now: NOW - 29 * DAY - 3600_000, events: [ev('alpha', 'get'), ev('epsilon', 'get', 'клиент'), ev('\u{1F600}', 'get')] },
  { now: NOW - 20 * DAY, events: [ev('alpha', 'get', 'x', 'Section'), ev('alpha', 'hit'), ev('beta', 'get'), ev('beta', 'get', 'x', 'Section'), ev('\uFF21', 'get')] },
  { now: NOW - 10 * DAY, events: [ev('alpha', 'get'), ev('beta', 'hit'), ev('gamma', 'get'), ev('gone-a', 'get'), ev('B', 'get'), ev('a', 'get')] },
  { now: NOW - 3 * DAY - 1, events: [ev('alpha', 'get'), ev('delta', 'get'), ev('epsilon', 'hit')] },
  { now: NOW - 3 * DAY, events: [ev('alpha', 'hit'), ev('beta', 'get', null), ev('delta', 'get', 'a')] },
  { now: NOW - 2 * DAY, events: [ev('alpha', 'get'), ev('epsilon', 'get'), ev('epsilon', 'get'), ev('Ж', 'get'), ev('gone-b', 'get', 'x')] },
  { now: NOW - DAY, events: [ev('alpha', 'get'), ev('alpha', 'get'), ev('beta', 'get'), ev('delta', 'get'), ev('', 'get'), ev('with space', 'hit')] },
  { now: NOW - DAY + 1, events: [ev('alpha', 'get')] },
  { now: NOW - 1000, events: [ev('beta', 'get'), ev('beta', 'hit'), ev('gamma', 'hit')] },
  { now: NOW, events: [ev('alpha', 'get'), ev('alpha', 'hit', 'z'), ev('beta', 'get', null, 'Section'), ev('delta', 'get'), ev('unread-not-here', 'get')] },
];

/** The sets of report arguments: some by hand, the rest drawn at random from the arguments the tool takes. */
function reportOptions(): ReportOptions[] {
  const byHand: ReportOptions[] = [
    {}, { sinceDays: 1 }, { sinceDays: 7 }, { sinceDays: 30 }, { sinceDays: 45 }, { sinceDays: 365 }, { sinceDays: 100000 }, { top: 1 }, { top: 3 }, { top: 100 },
    { type: 'note' }, { type: 'Note' }, { type: 'NOTE' }, { type: 'runbook' }, { type: '' }, { type: 'заметка' }, { type: 'ЗАМЕТКА' }, { type: 'none' },
    { all: true }, { all: true, type: 'note' }, { all: true, top: 100 }, { all: true, sinceDays: 1 },
    { candidates: true }, { candidates: true, minGets: 1, minDays: 1 }, { candidates: true, minGets: 2, minDays: 2 }, { candidates: true, minGets: 3, minDays: 1 }, { candidates: true, all: true, minGets: 1, minDays: 1 },
    { candidates: true, type: 'runbook', minGets: 1, minDays: 1 }, { sinceDays: 1, top: 2, type: 'runbook' },
  ];
  const next = lcg(31102026);
  const pick = <T,>(list: readonly T[]): T => list[Math.floor(next() * list.length)] as T;
  const drawn: ReportOptions[] = Array.from({ length: 90 }, () => ({
    ...(next() < 0.7 ? { sinceDays: pick([1, 2, 3, 7, 10, 20, 30, 45, 61, 365, 500]) } : {}),
    ...(next() < 0.4 ? { top: pick([1, 2, 3, 5, 100]) } : {}),
    ...(next() < 0.3 ? { type: pick(['note', 'runbook', 'Заметка', '', 'x']) } : {}),
    ...(next() < 0.4 ? { all: next() < 0.8 } : {}),
    ...(next() < 0.4 ? { candidates: next() < 0.8, minGets: pick([1, 2, 3, 5]), minDays: pick([1, 2, 3]) } : {}),
  }));
  return [...byHand, ...drawn];
}

const SINCE = ['30d', '1d', '0d', '00d', '007d', '-1d', '1.5d', '30', 'd', '30D', ' 30d', '30d ', '9007199254740991d', '9007199254740992d', '999999999999999999999d', '१d', '１d', '', '1d1d', '+1d'];
const POSITIVE = ['1', '20', '0', '-1', '01', '1.0', '', '9007199254740991', '9007199254740992', '٣', '1e3', ' 1', '1 ', '+1', '0x10'];

/** The store `batches` make, read as rows in the order they were written. */
function storeRows(file: string): unknown {
  silenceSqliteWarning();
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    return plain(db.prepare('select ts, doc_id, heading, kind, caller from usage_events order by rowid').all().map((r) => ({ ...r })));
  } finally {
    db.close();
  }
}

function batchVectors(): unknown {
  const dir = scratch('usage-batches');
  const file = path.join(dir, 'usage.sqlite');
  const snapshots = BATCHES.map((batch) => {
    const db = openUsageDb(file);
    try {
      appendEvents(db, batch.events, { now: () => batch.now });
    } finally {
      db.close();
    }
    return { now: batch.now, events: batch.events, rows: storeRows(file) };
  });
  return { snapshots };
}

function reportVectors(): unknown {
  const dir = scratch('usage-reports');
  const folder = path.join(dir, 'folder');
  writeFiles(folder, FILES, 1_700_000_000);
  const index = openDb(path.join(dir, 'index.sqlite'));
  reindex(index, folder);
  const file = path.join(dir, 'usage.sqlite');
  const db = openUsageDb(file);
  for (const batch of BATCHES) appendEvents(db, batch.events, { now: () => batch.now });
  db.close();
  const reports = reportOptions().map((options) => ({ options, rows: plain(readUsageRows(index, file, { ...options, now: { now: () => NOW } })) }));
  index.close();
  return { files: FILES.map((f) => ({ name: f.name, text: f.text, mtimeSec: 1_700_000_000 })), now: NOW, reports };
}

// ---- stores that are not what they should be ---------------------------------------------------

type Setup = 'absent' | 'empty-database' | 'other-table' | 'not-a-database' | 'directory' | 'wrong-shape';

const SETUPS: readonly Setup[] = ['absent', 'empty-database', 'other-table', 'not-a-database', 'directory', 'wrong-shape'];

function prepare(dir: string, setup: Setup): string {
  const file = path.join(dir, `${setup}.sqlite`);
  switch (setup) {
    case 'absent':
      return file;
    case 'empty-database':
      new DatabaseSync(file).close();
      return file;
    case 'other-table': {
      const db = new DatabaseSync(file);
      db.exec('create table other (x integer)');
      db.close();
      return file;
    }
    case 'not-a-database':
      fs.writeFileSync(file, 'this is not a database file at all, and it is longer than one page header needs');
      return file;
    case 'directory':
      fs.mkdirSync(file);
      return file;
    case 'wrong-shape': {
      const db = new DatabaseSync(file);
      db.exec('create table usage_events (x integer)');
      db.close();
      return file;
    }
  }
}

function brokenStores(): unknown {
  const dir = scratch('usage-broken');
  const index = openDb(path.join(dir, 'index.sqlite'));
  return SETUPS.map((setup) => {
    const file = prepare(dir, setup);
    try {
      const rows = readUsageRows(index, file, { now: { now: () => NOW } });
      return { setup, rows: plain(rows), created: setup === 'absent' && fs.existsSync(file) };
    } catch (e) {
      if (!(e instanceof UsageStoreError)) throw e;
      return { setup, error: { reason: relativize(e.reason, dir) } };
    }
  });
}

/** Recording that cannot succeed says why and does not throw. */
function recordingVectors(): unknown {
  if (typeof process.getuid === 'function' && process.getuid() === 0) throw new Error('a read-only file needs a user that is not root: run the generator as one');
  const dir = scratch('usage-record');
  const events = [ev('alpha', 'get'), ev('beta', 'hit', null)];
  const reasons = (file: string): string[] => {
    const told: string[] = [];
    recordReads(file, events, { now: { now: () => NOW }, report: (reason) => told.push(relativize(reason, dir)) });
    return told;
  };

  const readOnly = path.join(dir, 'readonly.sqlite');
  const seed = new DatabaseSync(readOnly);
  seed.exec('create table usage_events (ts integer not null, doc_id text not null, heading text not null default \'\', kind text not null, caller text)');
  seed.close();
  fs.chmodSync(readOnly, 0o444);

  const directory = path.join(dir, 'directory.sqlite');
  fs.mkdirSync(directory);

  const garbage = path.join(dir, 'garbage.sqlite');
  fs.writeFileSync(garbage, 'this is not a database file at all, and it is longer than one page header needs');

  const noEvents = path.join(dir, 'untouched.sqlite');
  recordReads(noEvents, [], { now: { now: () => NOW } });

  const fine = path.join(dir, 'fine.sqlite');
  const ok = reasons(fine);

  const out = {
    readOnly: reasons(readOnly),
    directory: reasons(directory),
    notADatabase: reasons(garbage),
    noEventsCreatesNothing: !fs.existsSync(noEvents),
    ok,
    okRows: storeRows(fine),
  };
  fs.chmodSync(readOnly, 0o644);
  return out;
}

export function usageVectors(): unknown {
  return {
    batches: batchVectors(),
    reports: reportVectors(),
    brokenStores: brokenStores(),
    recording: recordingVectors(),
    parseSince: SINCE.map((value) => ({ value, days: parseSince(value) })),
    parsePositive: POSITIVE.map((value) => ({ value, n: parsePositive(value) })),
  };
}
