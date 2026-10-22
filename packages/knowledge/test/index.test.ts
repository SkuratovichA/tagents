// The index: what it costs to keep in step with the folder.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { SCHEMA_VERSION, docCount, openDb, reindex } from '../src/db.ts';
import { listDocs, search } from '../src/search.ts';
import { copyKnowledge, copyOkf, doc, removeDir, tmpDir, writeDoc } from './helpers.ts';

function withCorpus(name: string, run: (dir: string, db: ReturnType<typeof openDb>) => void): void {
  const root = tmpDir(name);
  const dir = copyKnowledge(path.join(root, 'knowledge'));
  const db = openDb(path.join(root, 'index.sqlite'));
  try {
    run(dir, db);
  } finally {
    db.close();
    removeDir(root);
  }
}

test('a first index reads every document, a second reads none', () => {
  withCorpus('incremental', (dir, db) => {
    const first = reindex(db, dir);
    assert.equal(first.added, 5);
    assert.equal(first.changed, 0);
    assert.equal(first.unchanged, 0);
    assert.equal(first.removed, 0);
    assert.equal(docCount(db), 5);

    const second = reindex(db, dir);
    assert.deepEqual(
      { added: second.added, changed: second.changed, unchanged: second.unchanged, removed: second.removed },
      { added: 0, changed: 0, unchanged: 5, removed: 0 }
    );
  });
});

test('a touched file whose bytes did not change is still unchanged', () => {
  withCorpus('touch', (dir, db) => {
    reindex(db, dir);
    const file = path.join(dir, 'tmux-cheatsheet.md');
    const later = new Date(Date.now() + 60_000);
    fs.utimesSync(file, later, later);
    const stats = reindex(db, dir);
    assert.equal(stats.changed, 0);
    assert.equal(stats.unchanged, 5);
  });
});

test('an edited file is re-chunked and a deleted one disappears', () => {
  withCorpus('edit', (dir, db) => {
    reindex(db, dir);
    const file = path.join(dir, 'tmux-cheatsheet.md');
    fs.writeFileSync(
      file,
      fs.readFileSync(file, 'utf8') + '\n## Copy mode\n\nprefix + [ scrolls back through the pane.\n'
    );
    const edited = reindex(db, dir);
    assert.equal(edited.changed, 1);
    assert.equal(edited.unchanged, 4);
    assert.deepEqual(
      search(db, ['scrolls']).map((h) => `${h.id}#${h.heading}`),
      ['tmux-cheatsheet#Copy mode']
    );

    fs.rmSync(path.join(dir, 'mashina-karta.md'));
    const removed = reindex(db, dir);
    assert.equal(removed.removed, 1);
    assert.equal(docCount(db), 4);
    assert.deepEqual(search(db, ['бэкапы']), []);
  });
});

test('a file that stopped parsing is reported and stops answering', () => {
  withCorpus('broken', (dir, db) => {
    reindex(db, dir);
    const file = path.join(dir, 'tmux-cheatsheet.md');
    // Neither `type` nor `kind`: the one thing the tolerant loader still refuses.
    fs.writeFileSync(file, '---\ntitle: Broken\n---\n\nbody\n');
    const stats = reindex(db, dir);
    assert.equal(stats.errors.length, 1);
    assert.match(stats.errors[0]?.message ?? '', /type: required/);
    assert.equal(docCount(db), 4);
    assert.deepEqual(
      listDocs(db).map((d) => d.id),
      ['deploy-runbook', 'mashina-karta', 'relizy-zametki', 'sqlite-over-vectors']
    );
  });
});

test('--full rebuilds from nothing and lands in the same place', () => {
  withCorpus('full', (dir, db) => {
    reindex(db, dir);
    const before = listDocs(db);
    const stats = reindex(db, dir, { full: true });
    assert.equal(stats.added, 5);
    assert.equal(stats.unchanged, 0);
    assert.deepEqual(listDocs(db), before);
  });
});

test('a document added later joins the index without a full rebuild', () => {
  withCorpus('grow', (dir, db) => {
    reindex(db, dir);
    writeDoc(dir, 'novyj-runbook.md', doc({ id: 'novyj-runbook', kind: 'runbook', tags: '[release]' }, 'Новый раннбук про откат релиза.\n'));
    const stats = reindex(db, dir);
    assert.equal(stats.added, 1);
    assert.equal(stats.unchanged, 5);
    assert.deepEqual(
      search(db, ['раннбук']).map((h) => h.id),
      ['novyj-runbook']
    );
  });
});

// The schema of the previous format, as it was written: `kind` and `updated`
// columns and meta.schema_version = 1. Opening such a file must not fail and
// must not serve its rows: the index is derived data and is rebuilt.
const OLD_SCHEMA = `
create table meta (key text primary key, value text not null);
create table docs (id text primary key, path text not null, title text not null, kind text not null,
  tags text not null, updated text not null, mtime integer not null, hash text not null);
create table chunks (doc_id text not null references docs(id) on delete cascade, heading text not null,
  ord integer not null, body text not null, primary key (doc_id, ord));
create virtual table chunks_fts using fts5(doc_id unindexed, heading, body, tokenize='unicode61 remove_diacritics 2');
insert into meta (key, value) values ('schema_version', '1');
insert into docs values ('ghost', '/nowhere/ghost.md', 'Ghost', 'note', '[]', '2026-01-01', 0, 'x');
insert into chunks values ('ghost', '', 0, 'phantomword');
insert into chunks_fts (rowid, doc_id, heading, body) values (1, 'ghost', '', 'phantomword');
`;

test('an index written by the previous schema version is dropped and rebuilt', () => {
  const root = tmpDir('old-index');
  try {
    const file = path.join(root, 'old.sqlite');
    const old = new DatabaseSync(file);
    old.exec(OLD_SCHEMA);
    old.close();

    const dir = copyOkf(path.join(root, 'knowledge'));
    const db = openDb(file);
    try {
      assert.equal(SCHEMA_VERSION, 2);
      const version = db.prepare("select value from meta where key = 'schema_version'").get();
      assert.equal(String(version?.['value']), '2');
      assert.equal(docCount(db), 0, 'the old rows are gone');
      assert.deepEqual(search(db, ['phantomword']), []);
      const columns = db.prepare('pragma table_info(docs)').all().map((r) => String(r['name']));
      for (const c of ['type', 'description', 'status', 'stale_after', 'generated_at'])
        assert.ok(columns.includes(c), `docs has no column ${c}: ${columns.join(',')}`);
      assert.ok(!columns.includes('kind'));

      const stats = reindex(db, dir);
      assert.equal(stats.added, 4, 'index.md and log.md are not documents');
      assert.deepEqual(
        listDocs(db).map((d) => d.id),
        ['backup-runbook', 'cache-policy', 'service-map', 'old-queue-notes']
      );
    } finally {
      db.close();
    }
  } finally {
    removeDir(root);
  }
});
