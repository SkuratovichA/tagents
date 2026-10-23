// What was read, and how often.
//
// The usage store is a SQLite file of its own, beside the index in use and never inside it: the index is derived, and is dropped and rebuilt whenever its schema moves, while this is the only copy of what happened. It holds one row per event rather than a counter per document, because the report asks for a window, for the number of distinct days and for the last read, and a counter answers none of those.
//
// Recording is best effort and happens after a read succeeded. It opens the store, writes the events of one call in one transaction and closes it again, as `withDb` does for the index: the shared daemon lives for hours, and a handle kept between calls would pin a file the owner may move and keep the path of its first caller. WAL and a short busy timeout let a CLI process and the daemon write at once. Every error is caught: a full disk must not turn `show` into a failure while somebody reads a runbook.
//
// What is stored is the document, the heading, whether it was read or only matched, and who read. Never the text of a query and never a session id.
import fs from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { realClock } from '@tagents/core';
import { int, openFile, silenceSqliteWarning, text } from './db.ts';
import type { Status } from './doc.ts';
import { listDocs, type Clock, type Hit } from './search.ts';

export const RETENTION_DAYS = 365;
export const BUSY_TIMEOUT_MS = 250;
export const DEFAULT_SINCE_DAYS = 30;
export const DEFAULT_TOP = 20;
export const DEFAULT_MIN_GETS = 5;
export const DEFAULT_MIN_DAYS = 3;
const DAY_MS = 86_400_000;

const DDL = `
create table if not exists usage_events (
  ts      integer not null,             -- ms since the epoch
  doc_id  text    not null,
  heading text    not null default '',  -- '' for a whole document or a search hit
  kind    text    not null,             -- 'get' | 'hit'
  caller  text                          -- the MCP client or $TA_LABEL; null when nobody said
);
create index if not exists usage_by_doc on usage_events(doc_id, ts);  -- the report groups by document without a sort
create index if not exists usage_by_ts on usage_events(ts);           -- the retention finds what is old without a scan
`;

export type UsageKind = 'get' | 'hit';

export interface UsageEvent {
  readonly docId: string;
  /** '' for a whole document or a search hit. */
  readonly heading: string;
  /** A `get` returned the text; a `hit` only matched a query. */
  readonly kind: UsageKind;
  readonly caller: string | null;
}

/** Open (creating it, and its directory, if need be) and bring the table up to date. */
export function openUsageDb(file: string): DatabaseSync {
  const db = openFile(file);
  try {
    db.exec(`pragma busy_timeout = ${BUSY_TIMEOUT_MS}`);
    try {
      db.exec('pragma journal_mode = wal');
    } catch {
      // Switching a new file to WAL does not wait for a lock: when two callers create the store at once, the second is refused at once. The file works in either mode and the next call finds it switched, so this is not a reason to lose the event.
    }
    db.exec('pragma synchronous = normal'); // a power cut may take the last event; a read must not wait for the disk
    db.exec(DDL);
  } catch (e) {
    db.close();
    throw e;
  }
  return db;
}

/** One transaction: the events older than the retention go, the new ones come in. */
export function appendEvents(db: DatabaseSync, events: readonly UsageEvent[], clock: Clock = realClock): void {
  const now = clock.now();
  db.exec('begin immediate');
  try {
    db.prepare('delete from usage_events where ts < ?').run(now - RETENTION_DAYS * DAY_MS);
    const insert = db.prepare('insert into usage_events (ts, doc_id, heading, kind, caller) values (?, ?, ?, ?, ?)');
    for (const e of events) insert.run(now, e.docId, e.heading, e.kind, e.caller);
    db.exec('commit');
  } catch (e) {
    try {
      db.exec('rollback');
    } catch {
      // SQLite already rolled back on its own; the original error is the one to report.
    }
    throw e;
  }
}

export interface RecordOptions {
  readonly now?: Clock;
  /** Told why an event was not recorded. Nothing else happens: the read that called goes on. */
  readonly report?: (reason: string) => void;
}

/** Record the events of one successful read. Never throws. */
export function recordReads(file: string, events: readonly UsageEvent[], options: RecordOptions = {}): void {
  if (events.length === 0) return;
  try {
    const db = openUsageDb(file);
    try {
      appendEvents(db, events, options.now ?? realClock);
    } finally {
      db.close();
    }
  } catch (e) {
    options.report?.(e instanceof Error ? e.message : String(e));
  }
}

export function getEvent(docId: string, heading: string, caller: string | null): UsageEvent {
  return { docId, heading, kind: 'get', caller };
}

/** A search matched sections; what it tells is which documents, once each, in the order of the results. */
export function hitEvents(hits: readonly Pick<Hit, 'id'>[], caller: string | null): UsageEvent[] {
  return [...new Set(hits.map((h) => h.id))].map((docId): UsageEvent => ({ docId, heading: '', kind: 'hit', caller }));
}

/** A caller is a name that is not empty: the label of a session or the name a client gave in the handshake. Anything else is nobody. */
export function callerFrom(name: string | undefined): string | null {
  return name !== undefined && name !== '' ? name : null;
}

/** `TA_LABEL` names who is reading when a session has set it. */
export function callerFromEnv(env: NodeJS.ProcessEnv): string | null {
  return callerFrom(env['TA_LABEL']);
}

// ---- the report ------------------------------------------------------------------------------

export interface UsageRow {
  readonly id: string;
  /** null for an id that is no longer in the folder. */
  readonly type: string | null;
  readonly status: Status | null;
  readonly gets: number;
  readonly hits: number;
  /** Distinct UTC dates with a `get` inside the window. */
  readonly days: number;
  /** The UTC date of the newest `get` of any age, null when there is none. */
  readonly last: string | null;
}

export interface ReportOptions {
  readonly sinceDays?: number;
  readonly top?: number;
  /** Keep the documents of this type, matched as `list` matches it; ids no longer in the folder are dropped. */
  readonly type?: string;
  /** Also list the ids that have events but are no longer in the folder. */
  readonly all?: boolean;
  /** Keep the documents that were read often enough on enough days. */
  readonly candidates?: boolean;
  readonly minGets?: number;
  readonly minDays?: number;
  readonly now?: Clock;
}

interface Counts {
  readonly gets: number;
  readonly hits: number;
  readonly days: number;
  readonly last: string | null;
}

const NO_COUNTS: Counts = { gets: 0, hits: 0, days: 0, last: null };

/** The events by document: the window for the counts, all of time for `last`. The dates are UTC (`unixepoch` without `localtime`), the calendar `utcDateOf` in doc.ts uses for the dates of a document; test/usage.test.ts pins the two against each other. */
function countsByDoc(usage: DatabaseSync, sinceMs: number): Map<string, Counts> {
  const rows = usage
    .prepare(
      `select doc_id,
              count(case when kind = 'get' and ts >= ?1 then 1 end) as gets,
              count(case when kind = 'hit' and ts >= ?1 then 1 end) as hits,
              count(distinct case when kind = 'get' and ts >= ?1 then date(ts / 1000, 'unixepoch') end) as days,
              date(max(case when kind = 'get' then ts end) / 1000, 'unixepoch') as last
         from usage_events
        group by doc_id`
    )
    .all(sinceMs);
  return new Map(
    rows.map((r): [string, Counts] => [
      text(r, 'doc_id'),
      { gets: int(r, 'gets'), hits: int(r, 'hits'), days: int(r, 'days'), last: r['last'] === null ? null : text(r, 'last') },
    ])
  );
}

function windowStart(options: ReportOptions): number {
  return (options.now ?? realClock).now() - (options.sinceDays ?? DEFAULT_SINCE_DAYS) * DAY_MS;
}

const byId = (a: UsageRow, b: UsageRow): number => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/** The documents of the folder, joined by id with what the store counted, sorted and cut. */
function joinRows(index: DatabaseSync, counts: ReadonlyMap<string, Counts>, options: ReportOptions): UsageRow[] {
  const now = options.now ?? realClock;
  // An empty type filters nothing, as it does for `list` and `search`.
  const type = options.type === '' ? undefined : options.type;
  const docs = listDocs(index, { now, ...(type === undefined ? {} : { type }) });
  const inFolder = new Set(docs.map((d) => d.id));
  const row = (id: string, kind: string | null, status: Status | null): UsageRow => {
    const c = counts.get(id) ?? NO_COUNTS;
    return { id, type: kind, status, gets: c.gets, hits: c.hits, days: c.days, last: c.last };
  };
  const rows = docs.map((d) => row(d.id, d.type === '' ? null : d.type, d.status));
  if (options.all === true && type === undefined) {
    for (const id of counts.keys()) if (!inFolder.has(id)) rows.push(row(id, null, null));
  }
  const minGets = options.minGets ?? DEFAULT_MIN_GETS;
  const minDays = options.minDays ?? DEFAULT_MIN_DAYS;
  return rows
    .filter((r) => options.candidates !== true || (r.status !== null && r.status !== 'deprecated' && r.gets >= minGets && r.days >= minDays))
    .sort((a, b) => b.gets - a.gets || b.hits - a.hits || byId(a, b))
    .slice(0, options.top ?? DEFAULT_TOP);
}

/** The report over a usage store that is already open, or over none. */
export function usageRows(index: DatabaseSync, usage: DatabaseSync | null, options: ReportOptions = {}): UsageRow[] {
  return joinRows(index, usage === null ? new Map() : countsByDoc(usage, windowStart(options)), options);
}

/** A usage store that exists and cannot be read. */
export class UsageStoreError extends Error {
  readonly file: string;
  readonly reason: string;
  constructor(file: string, reason: string) {
    super(`${file}: ${reason}`);
    this.name = 'UsageStoreError';
    this.file = file;
    this.reason = reason;
  }
}

/** What the store at `file` counted. A file that is not there counts nothing, and is not created. A read-only connection to a WAL file leaves its `-wal` and `-shm` beside it until the next write closes them, which is harmless. */
function readCounts(file: string, sinceMs: number): Map<string, Counts> {
  if (!fs.existsSync(file)) return new Map();
  let usage: DatabaseSync | null = null;
  try {
    silenceSqliteWarning();
    usage = new DatabaseSync(file, { readOnly: true });
    usage.exec(`pragma busy_timeout = ${BUSY_TIMEOUT_MS}`);
    // A file that is a database without the table, or has nothing in it yet, is an empty store, not a broken one.
    const table = usage.prepare("select 1 from sqlite_master where type = 'table' and name = 'usage_events'").get();
    return table === undefined ? new Map() : countsByDoc(usage, sinceMs);
  } catch (e) {
    throw new UsageStoreError(file, e instanceof Error ? e.message : String(e));
  } finally {
    usage?.close();
  }
}

/** The report over the store at `file`; throws `UsageStoreError` when the file is there and unreadable. */
export function readUsageRows(index: DatabaseSync, file: string, options: ReportOptions = {}): UsageRow[] {
  return joinRows(index, readCounts(file, windowStart(options)), options);
}

/** `30d` → 30. A window is a positive whole number of days, written with the d. */
export function parseSince(value: string): number | null {
  const m = /^(\d+)d$/.exec(value);
  return m === null ? null : parsePositive(m[1] ?? '');
}

/** `20` → 20. Anything that is not a whole number from 1 up is null. */
export function parsePositive(value: string): number | null {
  if (!/^\d+$/.test(value)) return null;
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= 1 ? n : null;
}
