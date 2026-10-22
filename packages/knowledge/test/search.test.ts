// Asking questions: what comes back first, in which language, and why.
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { openDb, reindex } from '../src/db.ts';
import { ftsQuery, getDoc, getSection, listDocs, parseAddress, search } from '../src/search.ts';
import { FakeClock } from '@tagents/core';
import { KNOWLEDGE, OKF, removeDir, tmpDir } from './helpers.ts';

function indexed(name: string, dir = KNOWLEDGE): { db: ReturnType<typeof openDb>; close: () => void } {
  const root = tmpDir(name);
  const db = openDb(path.join(root, 'index.sqlite'));
  reindex(db, dir);
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

test('the type filter is exact and case-insensitive, and kind is its alias', () => {
  const { db, close } = indexed('type-filter', OKF);
  try {
    const ids = (type: string): string[] => listDocs(db, { type }).map((d) => d.id);
    assert.deepEqual(ids('Runbook'), ['backup-runbook']);
    assert.deepEqual(ids('RUNBOOK'), ['backup-runbook']);
    assert.deepEqual(ids('run'), [], 'exact, not a prefix');
    assert.deepEqual(
      listDocs(db, { kind: 'runbook' }).map((d) => d.id),
      ids('Runbook')
    );
    assert.deepEqual(
      search(db, ['failover'], { kind: 'NOTE' }).map((h) => h.id),
      search(db, ['failover'], { type: 'note' }).map((h) => h.id)
    );
    // `type` wins over `kind` when both are given.
    assert.deepEqual(
      listDocs(db, { type: 'map', kind: 'runbook' }).map((d) => d.id),
      ['service-map']
    );
    // Not an ASCII-only comparison.
    assert.deepEqual(listDocs(db, { type: 'Decision' }).map((d) => d.id), ['cache-policy']);
  } finally {
    close();
  }
});

test('a deprecated document ranks last without being hidden', () => {
  const { db, close } = indexed('deprecated', OKF);
  try {
    const hits = search(db, ['failover']);
    assert.deepEqual(
      hits.map((h) => `${h.id}#${h.heading}`),
      ['cache-policy#Decision', 'old-queue-notes#Failover']
    );
    // The rule is what puts it second: on score alone the deprecated hit wins.
    assert.ok((hits[1]?.score ?? 0) > (hits[0]?.score ?? 0), 'the deprecated section scores higher');
    assert.deepEqual(
      hits.map((h) => h.status),
      ['stable', 'deprecated']
    );
    // A limit that leaves room still returns it; nothing is filtered out by status.
    assert.equal(search(db, ['failover'], { limit: 5 }).length, 2);
    assert.deepEqual(
      listDocs(db).map((d) => d.id),
      ['backup-runbook', 'cache-policy', 'service-map', 'old-queue-notes']
    );
  } finally {
    close();
  }
});

test('hits and summaries carry type, description, status and a stale flag from the injected clock', () => {
  const { db, close } = indexed('lifecycle', OKF);
  try {
    const clock = new FakeClock(Date.parse('2026-09-30T21:59:59Z'));
    const stale = (): boolean[] => [
      search(db, ['failover'], { now: clock })[0]?.stale ?? false,
      listDocs(db, { now: clock }).find((d) => d.id === 'cache-policy')?.stale ?? false,
      getDoc(db, 'cache-policy', clock)?.stale ?? false,
    ];
    assert.deepEqual(stale(), [false, false, false]);
    clock.advance(1000);
    assert.deepEqual(stale(), [true, true, true]);

    const hit = search(db, ['failover'], { now: clock })[0];
    assert.equal(hit?.type, 'Decision');
    assert.equal(hit?.description, 'Why cache entries expire after a day.');
    assert.equal(hit?.status, 'stable');

    const docs = new Map(listDocs(db, { now: clock }).map((d) => [d.id, d]));
    // generated.at is 2026-09-12T10:00:00+02:00: the UTC date, not the written one's offset.
    assert.equal(docs.get('cache-policy')?.updated, '2026-09-12');
    assert.equal(docs.get('service-map')?.updated, '-');
    assert.equal(docs.get('service-map')?.title, 'service-map');
    assert.equal(docs.get('old-queue-notes')?.description, '');
    assert.deepEqual(
      [...docs.values()].filter((d) => d.stale).map((d) => d.id),
      ['cache-policy']
    );
  } finally {
    close();
  }
});

test('index.md and log.md are not searchable', () => {
  const { db, close } = indexed('reserved', OKF);
  try {
    assert.deepEqual(search(db, ['reservedmarker']), []);
    assert.deepEqual(search(db, ['okf_version']), []);
  } finally {
    close();
  }
});
