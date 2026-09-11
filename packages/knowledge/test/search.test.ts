// Asking questions: what comes back first, in which language, and why.
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { openDb, reindex } from '../src/db.ts';
import { ftsQuery, getDoc, getSection, listDocs, parseAddress, search } from '../src/search.ts';
import { KNOWLEDGE, removeDir, tmpDir } from './helpers.ts';

function indexed(name: string): { db: ReturnType<typeof openDb>; close: () => void } {
  const root = tmpDir(name);
  const db = openDb(path.join(root, 'index.sqlite'));
  reindex(db, KNOWLEDGE);
  return {
    db,
    close: () => {
      db.close();
      removeDir(root);
    },
  };
}

test('a section whose HEADING matches outranks one that mentions the word', () => {
  const { db, close } = indexed('rank');
  try {
    const hits = search(db, ['rollback']);
    assert.ok(hits.length >= 2, `expected the heading and the mention, got ${hits.length}`);
    assert.equal(`${hits[0]?.id}#${hits[0]?.heading}`, 'deploy-runbook#Rollback');
    assert.ok(
      hits.some((h) => h.id === 'tmux-cheatsheet'),
      'the passing mention must still be found, just lower'
    );
    assert.ok((hits[0]?.score ?? 0) > (hits[1]?.score ?? 0), 'score must order the hits');
  } finally {
    close();
  }
});

test('a Russian query hits the Russian body, an English one the English body', () => {
  const { db, close } = indexed('locale');
  try {
    assert.deepEqual(
      search(db, ['бэкапы']).map((h) => `${h.id}#${h.heading}`),
      ['mashina-karta#Диски']
    );
    assert.deepEqual(
      search(db, ['манифесте']).map((h) => h.id),
      ['relizy-zametki']
    );
    const english = search(db, ['embeddings']);
    assert.deepEqual(
      english.map((h) => `${h.id}#${h.heading}`),
      ['sqlite-over-vectors#The decision']
    );
    // Neither language leaks into the other's results.
    assert.deepEqual(search(db, ['бэкапы', 'embeddings']), []);
  } finally {
    close();
  }
});

test('every hit carries the address, the snippet and the file behind it', () => {
  const { db, close } = indexed('shape');
  try {
    const hit = search(db, ['proxy'], { limit: 1 })[0];
    assert.ok(hit, 'expected a hit');
    assert.equal(hit.title, 'Deploying the demo service');
    assert.ok(hit.snippet.includes('['), `snippet must mark the match: ${hit.snippet}`);
    assert.ok(!hit.snippet.includes('\n'), 'a snippet is one line');
    assert.equal(hit.path, path.join(KNOWLEDGE, 'deploy-runbook.md'));
  } finally {
    close();
  }
});

test('tag and kind narrow the same query', () => {
  const { db, close } = indexed('filters');
  try {
    // Terms are ANDed, so this is one query about one word in one language.
    assert.ok(search(db, ['релиз*']).length >= 1, 'the prefix form finds "релизы"');
    assert.deepEqual(
      search(db, ['релиз*'], { kind: 'note' }).map((h) => h.id),
      ['relizy-zametki']
    );
    assert.deepEqual(search(db, ['релиз*'], { kind: 'cheatsheet' }), []);
    assert.deepEqual(
      search(db, ['rollback'], { tag: 'tmux' }).map((h) => h.id),
      ['tmux-cheatsheet']
    );
    assert.deepEqual(search(db, ['rollback'], { tag: 'no-such-tag' }), []);
  } finally {
    close();
  }
});

test('limit is honoured', () => {
  const { db, close } = indexed('limit');
  try {
    assert.equal(search(db, ['и', 'the', 'a', 'на'], { limit: 2 }).length <= 2, true);
    assert.equal(search(db, ['rollback'], { limit: 1 }).length, 1);
  } finally {
    close();
  }
});

test('listing and filtering documents', () => {
  const { db, close } = indexed('list');
  try {
    assert.deepEqual(
      listDocs(db).map((d) => d.id),
      ['deploy-runbook', 'mashina-karta', 'relizy-zametki', 'sqlite-over-vectors', 'tmux-cheatsheet']
    );
    assert.deepEqual(
      listDocs(db, { kind: 'runbook' }).map((d) => d.id),
      ['deploy-runbook']
    );
    assert.deepEqual(
      listDocs(db, { tag: 'deploy' }).map((d) => d.id),
      ['deploy-runbook', 'relizy-zametki']
    );
    const map = listDocs(db, { kind: 'map' })[0];
    assert.deepEqual([...(map?.headings ?? [])], ['Диски', 'Сервисы']);
  } finally {
    close();
  }
});

test('a document and one of its sections can be fetched by address', () => {
  const { db, close } = indexed('get');
  try {
    assert.equal(getDoc(db, 'mashina-karta')?.title, 'Карта машины');
    assert.equal(getDoc(db, 'no-such-doc'), null);
    const section = getSection(db, 'mashina-karta', 'Диски');
    assert.match(section?.body ?? '', /Бэкапы уезжают/);
    // Headings are matched the way a human types them.
    assert.equal(getSection(db, 'mashina-karta', 'диски')?.ord, section?.ord);
    assert.equal(getSection(db, 'mashina-karta', 'Нет такого'), null);
    assert.match(getSection(db, 'mashina-karta', '')?.body ?? '', /Что где стоит/);
  } finally {
    close();
  }
});

test('an address is split on the first #', () => {
  assert.deepEqual(parseAddress('deploy-runbook'), { id: 'deploy-runbook', heading: null });
  assert.deepEqual(parseAddress('deploy-runbook#Rollback'), {
    id: 'deploy-runbook',
    heading: 'Rollback',
  });
  assert.deepEqual(parseAddress('deploy-runbook#'), { id: 'deploy-runbook', heading: '' });
});

test('a query cannot be made to break FTS5 syntax', () => {
  assert.equal(ftsQuery(['tmux-agent-state.sh']), '"tmux-agent-state.sh"');
  assert.equal(ftsQuery(['"unbalanced']), '"unbalanced"');
  assert.equal(ftsQuery(['deplo*']), '"deplo"*');
  assert.equal(ftsQuery(['  ']), '');
  const { db, close } = indexed('syntax');
  try {
    assert.deepEqual(search(db, ['"']), []);
    assert.deepEqual(
      search(db, ['tmux-agent-state.sh OR']).map((h) => h.id),
      []
    );
    assert.deepEqual(
      search(db, ['proxy AND manifest']).map((h) => h.id),
      ['deploy-runbook']
    );
  } finally {
    close();
  }
});
