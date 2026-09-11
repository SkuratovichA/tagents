// The format: what a document must say about itself, and where it is cut.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { DocError, chunk, loadDir, parseDoc, readDoc, wikilinks } from '../src/doc.ts';
import { KNOWLEDGE, doc, removeDir, tmpDir, writeDoc } from './helpers.ts';

test('a valid document parses into frontmatter, body and sections', () => {
  const parsed = readDoc(path.join(KNOWLEDGE, 'deploy-runbook.md'));
  assert.equal(parsed.meta.id, 'deploy-runbook');
  assert.equal(parsed.meta.kind, 'runbook');
  assert.deepEqual([...parsed.meta.tags], ['deploy', 'ci']);
  assert.equal(parsed.meta.scope, 'project');
  assert.deepEqual(
    parsed.chunks.map((c) => c.heading),
    ['', 'Before you start', 'Deploy', 'Rollback']
  );
  assert.equal(parsed.chunks[0]?.ord, 0);
  assert.match(parsed.text, /^---\n/);
});

test('frontmatter is validated, not merely parsed', () => {
  const cases: Array<[string, RegExp]> = [
    ['no frontmatter at all\n', /no YAML frontmatter/],
    [doc({ kind: 'checklist' }), /kind/],
    [doc({ updated: '2026-02-30' }), /updated/],
    [doc({ updated: '11.09.2026' }), /updated/],
    [doc({ id: 'Not A Slug' }), /id/],
    [doc({ tags: '"deploy"' }), /tags/],
    [`---\nid: sample\ntitle: Sample\nkind: note\nupdated: 2026-09-11\n---\n\nbody\n`, /tags/],
    [doc({ extra: 'author: nobody' }), /author/],
  ];
  for (const [text, message] of cases) {
    assert.throws(
      () => parseDoc('/tmp/sample.md', text),
      (e: unknown) => e instanceof DocError && message.test(e.message),
      `expected ${message} for:\n${text}`
    );
  }
});

test('the id must equal the filename stem', () => {
  const dir = tmpDir('stem');
  try {
    const file = writeDoc(dir, 'other-name.md', doc({ id: 'sample' }));
    assert.throws(() => readDoc(file), /must equal the filename stem/);
    // parseDoc does not enforce it: lint reports the mismatch as a finding.
    assert.equal(parseDoc(file, fs.readFileSync(file, 'utf8')).meta.id, 'sample');
  } finally {
    removeDir(dir);
  }
});

test('chunking splits at "## " and nowhere else', () => {
  const chunks = chunk(
    [
      'preamble line',
      '',
      '## One',
      'first section',
      '',
      '```sh',
      '## not a heading, a shell comment',
      '```',
      '',
      '### Deeper heading stays inside',
      'still one',
      '',
      '## Two',
      'second section',
    ].join('\n')
  );
  assert.deepEqual(
    chunks.map((c) => c.heading),
    ['', 'One', 'Two']
  );
  assert.deepEqual(
    chunks.map((c) => c.ord),
    [0, 1, 2]
  );
  assert.match(chunks[1]?.body ?? '', /## not a heading/);
  assert.match(chunks[1]?.body ?? '', /### Deeper heading/);
  assert.equal(chunks[0]?.body, 'preamble line');
});

test('a document that opens with a heading has no preamble chunk', () => {
  const chunks = chunk('## Only\nbody\n');
  assert.deepEqual(
    chunks.map((c) => c.heading),
    ['Only']
  );
});

test('wikilinks are read with and without a heading', () => {
  assert.deepEqual(wikilinks('see [[other-doc]] and [[other-doc#Some Heading]]'), [
    { id: 'other-doc', heading: null },
    { id: 'other-doc', heading: 'Some Heading' },
  ]);
});

test('loadDir reports a duplicate id instead of silently keeping one', () => {
  const dir = tmpDir('dup');
  try {
    writeDoc(dir, 'first.md', doc({ id: 'first' }));
    writeDoc(dir, 'second.md', doc({ id: 'first' }));
    const loaded = loadDir(dir);
    assert.equal(loaded.docs.length, 1);
    assert.equal(loaded.errors.length, 1);
    assert.match(loaded.errors[0]?.message ?? '', /filename stem|duplicate id/);
  } finally {
    removeDir(dir);
  }
});

test('the fixture folder is the corpus the other suites assume', () => {
  const loaded = loadDir(KNOWLEDGE);
  assert.deepEqual([...loaded.errors], []);
  assert.deepEqual(
    loaded.docs.map((d) => d.meta.id).sort(),
    ['deploy-runbook', 'mashina-karta', 'relizy-zametki', 'sqlite-over-vectors', 'tmux-cheatsheet']
  );
});
