// toc: the OKF index.md, written and checked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { loadDir } from '../src/doc.ts';
import { indexState, renderIndex } from '../src/toc.ts';
import { OKF, okfDoc, removeDir, runCli, tmpDir, writeDoc } from './helpers.ts';

const LAYOUT = [
  '---',
  'okf_version: "0.2"',
  '---',
  '',
  '# Note',
  '',
  '* [Retired queue](old-queue-notes.md) (deprecated)',
  '',
  '# Runbook',
  '',
  '* [Nightly backup run](backup-runbook.md) - How the nightly backup runs',
  '',
].join('\n');

function layoutFolder(dir: string): string {
  writeDoc(dir, 'backup-runbook.md', okfDoc('Runbook', ['title: Nightly backup run', 'description: How the nightly backup runs']));
  writeDoc(dir, 'old-queue-notes.md', okfDoc('Note', ['title: Retired queue', 'status: deprecated']));
  return dir;
}

test('toc writes the exact layout and prints the path', () => {
  const dir = tmpDir('toc-layout');
  try {
    layoutFolder(dir);
    const r = runCli(['toc', '--dir', dir]);
    assert.equal(r.code, 0, r.stderr);
    assert.equal(r.stdout, `wrote ${path.join(dir, 'index.md')}\n`);
    assert.equal(fs.readFileSync(path.join(dir, 'index.md'), 'utf8'), LAYOUT);
    // a second run changes nothing
    runCli(['toc', '--dir', dir]);
    assert.equal(fs.readFileSync(path.join(dir, 'index.md'), 'utf8'), LAYOUT);
  } finally {
    removeDir(dir);
  }
});

test('the fixture folder index.md is what renderIndex gives for it', () => {
  assert.equal(renderIndex(loadDir(OKF).docs), fs.readFileSync(path.join(OKF, 'index.md'), 'utf8'));
});

test('groups ignore case and share the first spelling in id order, entries go by id, and an empty folder has no body', () => {
  const dir = tmpDir('toc-groups');
  try {
    writeDoc(dir, 'b-two.md', okfDoc('runbook', ['title: Two']));
    writeDoc(dir, 'a-one.md', okfDoc('Runbook', ['title: One', 'description: First']));
    writeDoc(dir, 'c-three.md', okfDoc('RUNBOOK'));
    writeDoc(dir, 'z-note.md', okfDoc('Note'));
    const text = renderIndex(loadDir(dir).docs);
    assert.equal(
      text,
      [
        '---',
        'okf_version: "0.2"',
        '---',
        '',
        '# Note',
        '',
        '* [z-note](z-note.md)',
        '',
        '# Runbook',
        '',
        '* [One](a-one.md) - First',
        '* [Two](b-two.md)',
        '* [c-three](c-three.md)',
        '',
      ].join('\n')
    );
    assert.equal(text.endsWith('\n') && !text.endsWith('\n\n'), true);
    const empty = tmpDir('toc-empty');
    try {
      assert.equal(renderIndex(loadDir(empty).docs), '---\nokf_version: "0.2"\n---\n');
    } finally {
      removeDir(empty);
    }
  } finally {
    removeDir(dir);
  }
});

test('toc --check writes nothing: exit 1 with one line when absent or different, 0 when current', () => {
  const dir = tmpDir('toc-check');
  try {
    layoutFolder(dir);
    const absent = runCli(['toc', '--check', '--dir', dir]);
    assert.equal(absent.code, 1);
    assert.equal(absent.stderr, 'index.md is out of date\n');
    assert.equal(absent.stdout, '');
    assert.equal(fs.existsSync(path.join(dir, 'index.md')), false, '--check must not write');

    assert.equal(runCli(['toc', '--dir', dir]).code, 0);
    const current = runCli(['toc', '--check', '--dir', dir]);
    assert.equal(current.code, 0, current.stderr);
    assert.equal(current.stdout + current.stderr, '');

    writeDoc(dir, 'added.md', okfDoc('Note'));
    const stale = runCli(['toc', '--check', '--dir', dir]);
    assert.equal(stale.code, 1);
    assert.equal(stale.stderr, 'index.md is out of date\n');
    assert.equal(fs.readFileSync(path.join(dir, 'index.md'), 'utf8'), LAYOUT, 'still the old file');
    assert.equal(indexState(dir, loadDir(dir).docs), 'outdated');
  } finally {
    removeDir(dir);
  }
});

test('toc on a folder that cannot be found is an error', () => {
  const r = runCli(['toc', '--dir', path.join(tmpDir('toc-none'), 'nope')]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /does not exist/);
});

test('index.md and log.md are never listed in the index', () => {
  const dir = tmpDir('toc-reserved');
  try {
    layoutFolder(dir);
    writeDoc(dir, 'log.md', '# Log\n\n- created\n');
    runCli(['toc', '--dir', dir]);
    runCli(['toc', '--dir', dir]);
    const text = fs.readFileSync(path.join(dir, 'index.md'), 'utf8');
    assert.doesNotMatch(text, /log\.md|index\.md/);
    assert.equal(text, LAYOUT);
  } finally {
    removeDir(dir);
  }
});
