// The index: what it costs to keep in step with the folder.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { docCount, openDb, reindex } from '../src/db.ts';
import { listDocs, search } from '../src/search.ts';
import { copyKnowledge, doc, removeDir, tmpDir, writeDoc } from './helpers.ts';

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
    fs.writeFileSync(file, doc({ id: 'tmux-cheatsheet', kind: 'nonsense' }));
    const stats = reindex(db, dir);
    assert.equal(stats.errors.length, 1);
    assert.match(stats.errors[0]?.message ?? '', /kind/);
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
