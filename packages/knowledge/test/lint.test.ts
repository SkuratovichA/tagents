// lint: the claims a document makes about itself, checked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { lint } from '../src/lint.ts';
import { createT } from '../src/i18n/index.ts';
import { copyKnowledge, doc, gitInit, removeDir, runCli, tmpDir, writeDoc } from './helpers.ts';

const t = createT('en');

test('the fixture corpus is clean', () => {
  const root = tmpDir('lint-clean');
  try {
    const dir = copyKnowledge(path.join(root, 'knowledge'));
    const result = lint(dir, t);
    assert.deepEqual([...result.issues], []);
    assert.equal(result.checked, 5);
    const cli = runCli(['lint', '--dir', dir], {});
    assert.equal(cli.code, 0, cli.stderr);
    assert.match(cli.stdout, /5 document\(s\).*no problems/);
  } finally {
    removeDir(root);
  }
});

test('a duplicate id is reported, not quietly resolved', () => {
  const dir = tmpDir('lint-dup');
  try {
    copyKnowledge(dir);
    writeDoc(dir, 'kopiya.md', doc({ id: 'mashina-karta', kind: 'map', tags: '[map]' }));
    const issues = lint(dir, t).issues;
    assert.ok(
      issues.some((i) => i.code === 'duplicate-id' && /mashina-karta/.test(i.message)),
      `expected a duplicate-id finding, got ${JSON.stringify(issues)}`
    );
    assert.ok(issues.some((i) => i.code === 'stem'));
    const cli = runCli(['lint', '--dir', dir], {});
    assert.equal(cli.code, 1);
    assert.match(cli.stdout, /duplicate id "mashina-karta"/);
  } finally {
    removeDir(dir);
  }
});

test('an "updated" older than the newest commit on the file is stale', () => {
  const dir = tmpDir('lint-stale');
  try {
    copyKnowledge(dir);
    // Backdate one document's claim, then commit the folder: the commit is
    // today, the claim is not.
    const file = path.join(dir, 'tmux-cheatsheet.md');
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('updated: 2026-09-09', 'updated: 2020-01-01'));
    gitInit(dir);
    const issues = lint(dir, t).issues;
    assert.ok(
      issues.some((i) => i.code === 'stale' && i.file === file),
      `expected a stale finding, got ${JSON.stringify(issues)}`
    );
    assert.equal(issues.filter((i) => i.code === 'stale').length, 1, 'only the backdated one');
  } finally {
    removeDir(dir);
  }
});

test('outside a git repository the commit check is skipped, not guessed', () => {
  const dir = tmpDir('lint-nogit');
  try {
    copyKnowledge(dir);
    const file = path.join(dir, 'tmux-cheatsheet.md');
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('updated: 2026-09-09', 'updated: 2020-01-01'));
    assert.deepEqual([...lint(dir, t).issues], []);
  } finally {
    removeDir(dir);
  }
});

test('a generated document whose source moved on is stale', () => {
  const root = tmpDir('lint-generated');
  try {
    const dir = path.join(root, 'knowledge');
    copyKnowledge(dir);
    const source = path.join(root, 'machine.yaml');
    fs.writeFileSync(source, 'hosts: []\n');
    const changed = new Date('2026-09-20T00:00:00Z');
    fs.utimesSync(source, changed, changed);
    writeDoc(
      dir,
      'iz-yaml.md',
      doc({ id: 'iz-yaml', kind: 'map', tags: '[map]', updated: '2026-09-11', extra: 'generated_from: ../machine.yaml' })
    );
    const issues = lint(dir, t).issues;
    assert.ok(
      issues.some((i) => i.code === 'generated' && /2026-09-20/.test(i.message)),
      `expected a generated finding, got ${JSON.stringify(issues)}`
    );

    // Regenerate: the document now claims a date at least as new as the source.
    writeDoc(
      dir,
      'iz-yaml.md',
      doc({ id: 'iz-yaml', kind: 'map', tags: '[map]', updated: '2026-09-20', extra: 'generated_from: ../machine.yaml' })
    );
    assert.deepEqual([...lint(dir, t).issues], []);

    // A source this machine does not have is not a finding.
    fs.rmSync(source);
    assert.deepEqual([...lint(dir, t).issues], []);
  } finally {
    removeDir(root);
  }
});

test('a wikilink to a document or heading that is gone is dead', () => {
  const dir = tmpDir('lint-links');
  try {
    copyKnowledge(dir);
    fs.rmSync(path.join(dir, 'sqlite-over-vectors.md'));
    const issues = lint(dir, t).issues;
    assert.deepEqual(
      issues.filter((i) => i.code === 'dead-link').map((i) => i.message),
      ['dead link [[sqlite-over-vectors]]']
    );

    const file = path.join(dir, 'relizy-zametki.md');
    fs.writeFileSync(
      file,
      fs.readFileSync(file, 'utf8').replace('[[deploy-runbook#Deploy]]', '[[deploy-runbook#Нет раздела]]')
    );
    assert.ok(
      lint(dir, t).issues.some((i) => i.message === 'dead link [[deploy-runbook#Нет раздела]]'),
      'a heading that does not exist is as dead as a missing document'
    );
  } finally {
    removeDir(dir);
  }
});

test('a file that does not parse is one finding, not a crash', () => {
  const dir = tmpDir('lint-broken');
  try {
    copyKnowledge(dir);
    writeDoc(dir, 'slomannyj.md', 'no frontmatter at all\n');
    const issues = lint(dir, t).issues;
    assert.equal(issues.filter((i) => i.code === 'frontmatter').length, 1);
    assert.equal(lint(dir, t).checked, 6);
  } finally {
    removeDir(dir);
  }
});

test('lint findings are translated, the codes are not', () => {
  const dir = tmpDir('lint-ru');
  try {
    copyKnowledge(dir);
    writeDoc(dir, 'kopiya.md', doc({ id: 'mashina-karta', kind: 'map', tags: '[map]' }));
    const issues = lint(dir, createT('ru')).issues;
    assert.ok(issues.some((i) => i.code === 'duplicate-id' && /дублирующийся/.test(i.message)));
  } finally {
    removeDir(dir);
  }
});
