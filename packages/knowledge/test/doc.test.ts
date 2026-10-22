// The format: what a document must say about itself, and where it is cut.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import {
  DocError,
  chunk,
  documentLinks,
  fragmentMatches,
  headingSlug,
  isStale,
  listFiles,
  loadDir,
  parseDoc,
  parseOffsetDatetime,
  readDoc,
  utcDateOf,
  wikilinks,
} from '../src/doc.ts';
import { KNOWLEDGE, OKF, doc, okfDoc, removeDir, tmpDir, writeDoc } from './helpers.ts';

test('a valid document parses into frontmatter, body and sections', () => {
  const parsed = readDoc(path.join(KNOWLEDGE, 'deploy-runbook.md'));
  assert.equal(parsed.meta.id, 'deploy-runbook');
  // The legacy form is read and mapped: kind -> Type, updated -> generated.at.
  assert.equal(parsed.meta.legacy, true);
  assert.equal(parsed.meta.type, 'Runbook');
  assert.equal(parsed.meta.generated?.at, '2026-09-10T00:00:00Z');
  assert.equal(parsed.meta.status, 'stable');
  assert.deepEqual([...parsed.meta.tags], ['deploy', 'ci']);
  assert.equal(parsed.meta.scope, 'project');
  assert.deepEqual(
    parsed.chunks.map((c) => c.heading),
    ['', 'Before you start', 'Deploy', 'Rollback']
  );
  assert.equal(parsed.chunks[0]?.ord, 0);
  assert.match(parsed.text, /^---\n/);
});

test('a file the loader cannot classify or address is refused, naming the field', () => {
  const cases: Array<[string, RegExp]> = [
    ['no frontmatter at all\n', /no YAML frontmatter/],
    ['---\ntitle: no type here\n---\n\nbody\n', /type: required/],
    [okfDoc('""'), /type: must be a non-empty string/],
    ['---\ntype: [a, b]\n---\n\nbody\n', /type: must be a non-empty string/],
    ['---\nkind: 3\n---\n\nbody\n', /kind: must be a non-empty string/],
    ['---\ntype: [unclosed\n---\n\nbody\n', /not YAML/],
    ['---\n- a\n- b\n---\n\nbody\n', /expected a mapping/],
  ];
  for (const [text, message] of cases) {
    assert.throws(
      () => parseDoc('/tmp/sample.md', text),
      (e: unknown) => e instanceof DocError && message.test(e.message),
      `expected ${message} for:\n${text}`
    );
  }
});

test('the loader is tolerant: what OKF lets a consumer ignore never refuses a file', () => {
  const loaded = parseDoc(
    '/tmp/sample.md',
    okfDoc('Note', [
      'owner: platform',
      'x-note: 1',
      'tags: not-a-list',
      'status: retired',
      'scope: everywhere',
      'stale_after: 2026-10-01T00:00:00',
      'generated: {by: tool, at: 2026-13-01T00:00:00Z}',
      'sources: [{title: no resource}, {resource: ../a.yaml}]',
    ])
  );
  assert.equal(loaded.meta.title, 'sample', 'no title: the stem');
  assert.deepEqual([...loaded.meta.tags], []);
  assert.equal(loaded.meta.status, 'stable');
  assert.equal(loaded.meta.scope, undefined);
  assert.equal(loaded.meta.staleAfter, undefined);
  assert.equal(loaded.meta.generated, undefined);
  assert.deepEqual(
    loaded.meta.sources.map((s) => s.resource),
    ['../a.yaml']
  );
  // Unknown keys survive in raw, where lint reads them.
  assert.equal(loaded.raw['owner'], 'platform');
  // A kind outside the old five is just a type now.
  assert.equal(parseDoc('/tmp/sample.md', doc({ kind: 'checklist' })).meta.type, 'Checklist');
});

test('legacy fields are mapped as the design says', () => {
  const legacy = parseDoc(
    '/tmp/sample.md',
    doc({ kind: 'runbook', updated: '2026-09-11', extra: 'generated_from: ../src/hosts.yaml' })
  );
  assert.equal(legacy.meta.legacy, true);
  assert.equal(legacy.meta.type, 'Runbook');
  assert.equal(legacy.meta.generated?.at, '2026-09-11T00:00:00Z');
  assert.deepEqual(
    legacy.meta.sources.map((s) => s.resource),
    ['../src/hosts.yaml']
  );
  assert.equal(legacy.meta.status, 'stable');
  // `type` wins over `kind` when both are written: that is the OKF form.
  const both = parseDoc('/tmp/sample.md', okfDoc('Decision', ['kind: note']));
  assert.equal(both.meta.legacy, false);
  assert.equal(both.meta.type, 'Decision');
});

test('an OKF document is accepted and read as written', () => {
  const parsed = readDoc(path.join(OKF, 'backup-runbook.md'));
  assert.equal(parsed.meta.legacy, false);
  assert.equal(parsed.meta.id, 'backup-runbook');
  assert.equal(parsed.meta.type, 'Runbook');
  assert.equal(parsed.meta.description, 'How the nightly backup runs and how to restore it.');
  assert.deepEqual(parsed.meta.generated, { by: 'backup-tool', at: '2026-09-10T08:00:00Z' });
  assert.equal(parsed.meta.sources[0]?.resource, 'https://example.invalid/backup-docs');
  assert.equal(parsed.meta.sources[0]?.title, 'Backup tool manual');
  assert.deepEqual(
    parsed.chunks.map((c) => c.heading),
    ['', 'Run', 'Restore']
  );
});

test('the id is the filename stem; a declared id that differs is kept for lint, a non-slug stem is refused', () => {
  const dir = tmpDir('stem');
  try {
    const file = writeDoc(dir, 'other-name.md', doc({ id: 'sample' }));
    const loaded = readDoc(file);
    assert.equal(loaded.meta.id, 'other-name');
    assert.equal(loaded.declaredId, 'sample');

    const odd = writeDoc(dir, 'Not A Slug.md', okfDoc('Note'));
    assert.throws(() => readDoc(odd), /stem "Not A Slug" must be a slug/);
    // parseDoc does not enforce it: lint reports the stem as a finding.
    assert.equal(parseDoc(odd, fs.readFileSync(odd, 'utf8')).meta.id, 'Not A Slug');
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

test('loadDir takes ids from stems, skips index.md and log.md and reports a bad stem while the rest loads', () => {
  const dir = tmpDir('load');
  try {
    writeDoc(dir, 'first.md', doc({ id: 'first' }));
    writeDoc(dir, 'second.md', doc({ id: 'first' }));
    writeDoc(dir, 'index.md', okfDoc('Note'));
    writeDoc(dir, 'log.md', 'no frontmatter, not a document\n');
    writeDoc(dir, 'Bad Stem.md', okfDoc('Note'));
    writeDoc(dir, '.hidden.md', okfDoc('Note'));
    fs.mkdirSync(path.join(dir, 'sub'));
    writeDoc(path.join(dir, 'sub'), 'nested.md', okfDoc('Note'));
    const loaded = loadDir(dir);
    assert.deepEqual(
      loaded.docs.map((d) => d.meta.id),
      ['first', 'second']
    );
    assert.equal(loaded.errors.length, 1);
    assert.match(loaded.errors[0]?.message ?? '', /must be a slug/);
    assert.deepEqual(
      listFiles(dir).map((f) => path.basename(f)),
      ['Bad Stem.md', 'first.md', 'second.md']
    );
  } finally {
    removeDir(dir);
  }
});

test('the OKF fixture folder loads clean, with index.md and log.md left out', () => {
  const loaded = loadDir(OKF);
  assert.deepEqual([...loaded.errors], []);
  assert.deepEqual(
    loaded.docs.map((d) => d.meta.id),
    ['backup-runbook', 'cache-policy', 'old-queue-notes', 'service-map']
  );
  const map = loaded.docs.find((d) => d.meta.id === 'service-map');
  assert.equal(map?.meta.title, 'service-map');
  assert.equal(map?.raw['x-note'], 1);
  assert.equal(loaded.docs.find((d) => d.meta.id === 'old-queue-notes')?.meta.status, 'deprecated');
});

test('stale and the date of generated.at are computed from an injected clock', () => {
  const fixed = Date.parse('2026-09-30T22:00:00Z');
  assert.equal(isStale('2026-10-01T00:00:00+02:00', fixed - 1), false);
  assert.equal(isStale('2026-10-01T00:00:00+02:00', fixed), true);
  assert.equal(isStale(undefined, fixed), false);
  assert.equal(isStale('2026-10-01T00:00:00', fixed), false, 'no offset: not a datetime we accept');
  assert.equal(utcDateOf('2026-09-12T01:30:00+02:00'), '2026-09-11');
  assert.equal(utcDateOf('2026-09-12T01:30:00'), null);
  assert.equal(parseOffsetDatetime('2026-02-30T10:00:00Z'), null);
  assert.equal(parseOffsetDatetime('2026-09-10T25:00:00Z'), null);
  assert.equal(parseOffsetDatetime('2026-09-10T10:00Z'), Date.parse('2026-09-10T10:00:00Z'));
});

test('document links: both forms, with fragments; schemes, non-md targets and fenced code are not links', () => {
  const body = [
    'see [[other-doc]] and [[other-doc#Some Heading]]',
    '[a](/cache-policy.md) [b](/cache-policy.md#decision) [c](./cache-policy.md) [d](cache-policy.md#decision)',
    '[x](https://example.invalid/a.md) [y](mailto:a@example.invalid) [z](notes.txt) [w](#local) ![i](pic.md)',
    '```sh',
    '[[in-code]] [q](/in-code.md)',
    '```',
    '~~~',
    '[[in-tilde-code]]',
    '~~~',
    'after [[tail-doc]]',
  ].join('\n');
  assert.deepEqual(
    documentLinks(body).map((l) => `${l.form} ${l.id} ${l.fragment ?? '-'} ${l.raw}`),
    [
      'wiki other-doc - [[other-doc]]',
      'wiki other-doc Some Heading [[other-doc#Some Heading]]',
      'markdown cache-policy - [a](/cache-policy.md)',
      'markdown cache-policy decision [b](/cache-policy.md#decision)',
      'markdown cache-policy - [c](./cache-policy.md)',
      'markdown cache-policy decision [d](cache-policy.md#decision)',
      'wiki tail-doc - [[tail-doc]]',
    ]
  );
  // The wikilink scanner follows the same fence rule.
  assert.deepEqual(
    wikilinks(body).map((l) => l.id),
    ['other-doc', 'other-doc', 'tail-doc']
  );
});

test('a fragment names a heading by its text or its slug', () => {
  assert.equal(fragmentMatches('Failover%20steps', 'Failover steps'), true);
  assert.equal(fragmentMatches('FAILOVER%20STEPS', 'Failover steps'), true);
  assert.equal(fragmentMatches('failover-steps', 'Failover steps'), true);
  assert.equal(fragmentMatches('failover-step', 'Failover steps'), false);
  assert.equal(headingSlug('Что делать? (быстро)'), 'что-делать-быстро');
  assert.equal(fragmentMatches('100%', '100%'), true, 'a malformed escape is compared as written');
  assert.equal(fragmentMatches('100%', 'Anything'), false);
  assert.equal(fragmentMatches('caf\u00e9-menu', 'Cafe\u0301 menu'), true, 'NFC fragment, NFD heading');
  assert.equal(headingSlug('Cafe\u0301 menu'), 'caf\u00e9-menu');
});

test('the fixture folder is the corpus the other suites assume', () => {
  const loaded = loadDir(KNOWLEDGE);
  assert.deepEqual([...loaded.errors], []);
  assert.deepEqual(
    loaded.docs.map((d) => d.meta.id).sort(),
    ['deploy-runbook', 'mashina-karta', 'relizy-zametki', 'sqlite-over-vectors', 'tmux-cheatsheet']
  );
});

test('documentLinks: inline code spans hide links, escaped brackets stay in the link text, order is document order', () => {
  const links = documentLinks('[a](x.md) then [[y]] and `[[no]]` and [b \\] c](z.md#f)\n');
  assert.deepEqual(links.map((l) => l.raw), ['[a](x.md)', '[[y]]', '[b \\] c](z.md#f)']);
});
