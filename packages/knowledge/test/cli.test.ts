// The CLI: what it prints, and what it exits with.
//
// Every case runs the real binary in a child process with a temp knowledge
// folder and a temp index, because the exit code IS the contract: a caller in
// a shell script branches on 4 (nothing found) without reading a word.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { KNOWLEDGE, copyKnowledge, doc, removeDir, runCli, tmpDir, writeDoc } from './helpers.ts';

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
      'heading',
      'id',
      'path',
      'score',
      'snippet',
      'title',
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
    assert.match(text.stdout, /^deploy-runbook\s+runbook\s+2026-09-10\s+Deploying the demo service\s+#deploy #ci/);

    const asJson: unknown = JSON.parse(runCli(['list', '--tag', 'deploy', '--json'], env).stdout);
    assert.ok(Array.isArray(asJson));
    assert.deepEqual(
      asJson.map((d) => (d as { id: string }).id),
      ['deploy-runbook', 'relizy-zametki']
    );
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
