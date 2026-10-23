// lint: the claims a document makes about itself, checked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { lint } from '../src/lint.ts';
import { createT } from '../src/i18n/index.ts';
import { loadDir } from '../src/doc.ts';
import { writeIndex } from '../src/toc.ts';
import { FakeClock } from '@tagents/core';
import { copyKnowledge, copyOkf, doc, gitInit, okfDoc, removeDir, runCli, tmpDir, writeDoc } from './helpers.ts';

const t = createT('en');

/** The fixed "now" of the cases that do not care about the clock: far before any `stale_after` they write. */
const NOW = new FakeClock(Date.parse('2026-09-20T00:00:00Z'));

/** A small OKF folder whose findings are none: the fixture folder minus the keys lint rejects on purpose, with a current index.md. */
function cleanFolder(dir: string): string {
  copyOkf(dir);
  writeDoc(dir, 'service-map.md', okfDoc('Map', ['tags: [map]'], '## Services\n\nThe web tier calls the queue and the cache.\n'));
  const cache = path.join(dir, 'cache-policy.md');
  fs.writeFileSync(cache, fs.readFileSync(cache, 'utf8').replace('stale_after: 2026-10-01T00:00:00+02:00', 'stale_after: 2099-01-01T00:00:00Z'));
  writeIndex(dir, loadDir(dir).docs);
  return dir;
}

/** `code: message` of every finding, so a case asserts on what a person would read. */
function findings(dir: string, now = NOW): string[] {
  return lint(dir, t, process.env, now).issues.map((i) => `${i.code} ${path.basename(i.file)}: ${i.message}`);
}

const only = (dir: string, code: string, now = NOW): string[] =>
  lint(dir, t, process.env, now).issues.filter((i) => i.code === code).map((i) => i.message);


test('a clean OKF folder has no findings, and index.md and log.md are not counted', () => {
  const root = tmpDir('lint-clean');
  try {
    const dir = cleanFolder(path.join(root, 'knowledge'));
    assert.ok(fs.existsSync(path.join(dir, 'log.md')));
    const result = lint(dir, t, process.env, NOW);
    assert.deepEqual([...result.issues], []);
    assert.equal(result.checked, 4);
    const cli = runCli(['lint', '--dir', dir], {});
    assert.equal(cli.code, 0, cli.stdout + cli.stderr);
    assert.match(cli.stdout, /4 document\(s\).*no problems/);
  } finally {
    removeDir(root);
  }
});

test('every document of the legacy form gets exactly one legacy finding', () => {
  const root = tmpDir('lint-legacy');
  try {
    const dir = copyKnowledge(path.join(root, 'knowledge'));
    const legacy = lint(dir, t, process.env, NOW).issues.filter((i) => i.code === 'legacy');
    assert.equal(legacy.length, 5);
    assert.equal(new Set(legacy.map((i) => i.file)).size, 5);
    assert.match(legacy[0]?.message ?? '', /legacy.*OKF form/);
    // The legacy keys are known to a legacy document: nothing is "unknown".
    assert.deepEqual(only(dir, 'frontmatter'), []);
    const cli = runCli(['lint', '--dir', dir], {});
    assert.equal(cli.code, 1);
    assert.match(cli.stdout, /deploy-runbook\.md: legacy form/);
  } finally {
    removeDir(root);
  }
});

test('frontmatter: an unknown key is named, and the legacy keys are unknown in an OKF document', () => {
  const dir = tmpDir('lint-unknown');
  try {
    writeDoc(dir, 'a.md', okfDoc('Note', ['owner: platform', 'kind: x', 'updated: 2026-09-01']));
    writeDoc(dir, 'b.md', okfDoc('Note', ['status: draft', 'scope: project', 'resource: ./x']));
    assert.deepEqual(only(dir, 'frontmatter').sort(), ['unknown key "kind"', 'unknown key "owner"', 'unknown key "updated"']);
  } finally {
    removeDir(dir);
  }
});

test('frontmatter: tags, status, scope, generated, verified, stale_after and sources are held to the profile', () => {
  const dir = tmpDir('lint-profile');
  try {
    writeDoc(dir, 'tags.md', okfDoc('Note', ['tags: [Not A Slug, fine]']));
    writeDoc(dir, 'status.md', okfDoc('Note', ['status: retired']));
    writeDoc(dir, 'scope.md', okfDoc('Note', ['scope: everywhere']));
    writeDoc(dir, 'gen.md', okfDoc('Note', ['generated:', '  by: tool', '  at: 2026-09-01']));
    writeDoc(dir, 'gen-by.md', okfDoc('Note', ['generated:', '  at: 2026-09-01T00:00:00Z']));
    writeDoc(dir, 'ver.md', okfDoc('Note', ['verified:', '  - by: someone', '    at: yesterday']));
    writeDoc(dir, 'stale.md', okfDoc('Note', ['stale_after: 2026-10-01T00:00:00']));
    writeDoc(dir, 'src.md', okfDoc('Note', ['sources:', '  - title: x']));
    const by = (file: string): string[] =>
      lint(dir, t, process.env, NOW).issues.filter((i) => i.code === 'frontmatter' && path.basename(i.file) === file).map((i) => i.message);
    assert.match(by('tags.md').join('\n'), /^tags: "Not A Slug" is not a slug/);
    assert.equal(by('tags.md').length, 1, 'the valid tag is not reported');
    assert.match(by('status.md').join(), /^status: "retired"/);
    assert.match(by('scope.md').join(), /^scope: "everywhere"/);
    assert.match(by('gen.md').join(), /^generated:/);
    assert.match(by('gen-by.md').join(), /^generated:/);
    assert.match(by('ver.md').join(), /^verified:/);
    assert.match(by('stale.md').join(), /^stale_after: "2026-10-01T00:00:00"/);
    assert.match(by('src.md').join(), /^sources: entry 1 has no `resource`/);
  } finally {
    removeDir(dir);
  }
});

test('frontmatter: valid values of every checked key produce no finding', () => {
  const dir = tmpDir('lint-profile-ok');
  try {
    writeDoc(
      dir,
      'ok.md',
      okfDoc('Note', [
        'tags: [a, b-c]',
        'status: deprecated',
        'scope: global',
        'generated:',
        '  by: tool',
        '  at: 2026-09-01T00:00:00+02:00',
        'verified:',
        '  - by: someone',
        '    at: 2026-09-02T00:00:00Z',
        'stale_after: 2099-01-01T00:00:00Z',
        'sources:',
        '  - resource: https://example.invalid/page',
        '    author: someone',
      ])
    );
    assert.deepEqual(only(dir, 'frontmatter'), []);
    writeDoc(dir, 'ok.md', okfDoc('Note', ['verified:', '  by: someone', '  at: 2026-09-02T00:00:00Z']));
    assert.deepEqual(only(dir, 'frontmatter'), [], 'verified may be a single mapping');
  } finally {
    removeDir(dir);
  }
});

test('a file that is refused by the loader is one frontmatter finding', () => {
  const dir = tmpDir('lint-refused');
  try {
    writeDoc(dir, 'no-type.md', '---\ntitle: x\n---\n\nBody.\n');
    assert.match(only(dir, 'frontmatter').join(), /type/);
    assert.equal(lint(dir, t, process.env, NOW).checked, 1);
  } finally {
    removeDir(dir);
  }
});

test('stem: a declared id that differs, and a stem that is not a slug', () => {
  const dir = tmpDir('lint-stem');
  try {
    writeDoc(dir, 'other-name.md', okfDoc('Note', ['id: sample']));
    writeDoc(dir, 'right-name.md', okfDoc('Note', ['id: right-name']));
    writeDoc(dir, 'Not A Slug.md', okfDoc('Note'));
    const messages = only(dir, 'stem');
    assert.equal(messages.length, 2);
    assert.ok(messages.some((m) => m.includes('"sample"') && m.includes('"other-name"')), messages.join());
    assert.ok(messages.some((m) => m.includes('"Not A Slug"')), messages.join());
  } finally {
    removeDir(dir);
  }
});

test('expired: stale_after at or after the injected clock, never before', () => {
  const dir = tmpDir('lint-expired');
  try {
    writeDoc(dir, 'old.md', okfDoc('Note', ['stale_after: 2026-10-01T00:00:00+02:00']));
    writeDoc(dir, 'far.md', okfDoc('Note', ['stale_after: 2099-01-01T00:00:00Z']));
    writeDoc(dir, 'none.md', okfDoc('Note'));
    const clock = new FakeClock(Date.parse('2026-09-30T21:59:59Z'));
    assert.deepEqual(only(dir, 'expired', clock), []);
    clock.advance(1000);
    const hits = lint(dir, t, process.env, clock).issues.filter((i) => i.code === 'expired');
    assert.deepEqual(hits.map((i) => path.basename(i.file)), ['old.md']);
    assert.ok(hits[0]?.message.includes('2026-10-01T00:00:00+02:00'), 'the value as written');
  } finally {
    removeDir(dir);
  }
});

test('stale: generated.at older than the newest commit, only inside git, only committed, only with generated', () => {
  const root = tmpDir('lint-stale');
  try {
    const dir = path.join(root, 'knowledge');
    writeDoc(dir, 'backdated.md', okfDoc('Note', ['generated:', '  by: tool', '  at: 2020-01-01T00:00:00Z']));
    writeDoc(dir, 'current.md', okfDoc('Note', ['generated:', '  by: tool', '  at: 2026-09-10T00:00:00Z']));
    writeDoc(dir, 'plain.md', okfDoc('Note'));
    // The UTC date decides: 23:30 on the 6th at -02:00 is the 7th in UTC, the commit's day.
    writeDoc(dir, 'offset.md', okfDoc('Note', ['generated:', '  by: tool', '  at: 2026-09-06T23:30:00-02:00']));
    // Outside a repository the commit check is skipped, not guessed.
    assert.deepEqual(only(dir, 'stale'), []);
    gitInit(dir);
    writeDoc(dir, 'uncommitted.md', okfDoc('Note', ['generated:', '  by: tool', '  at: 2020-01-01T00:00:00Z']));
    const hits = lint(dir, t, process.env, NOW).issues.filter((i) => i.code === 'stale');
    assert.deepEqual(hits.map((i) => path.basename(i.file)), ['backdated.md']);
    assert.match(hits[0]?.message ?? '', /2020-01-01.*2026-09-07/);
  } finally {
    removeDir(root);
  }
});

test('generated: a source file that changed after generated.at; URLs, scopes and missing files are skipped', () => {
  const root = tmpDir('lint-generated');
  try {
    const dir = path.join(root, 'knowledge');
    const source = path.join(root, 'machine.yaml');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(source, 'hosts: []\n');
    const changed = new Date('2026-09-20T12:00:00Z');
    fs.utimesSync(source, changed, changed);
    fs.writeFileSync(path.join(dir, 'inside.yaml'), 'x: 1\n');
    fs.utimesSync(path.join(dir, 'inside.yaml'), changed, changed);
    const claim = (at: string, resource: string): string =>
      okfDoc('Map', ['generated:', '  by: tool', `  at: ${at}`, 'sources:', `  - resource: ${resource}`]);

    writeDoc(dir, 'rel.md', claim('2026-09-11T00:00:00Z', '../machine.yaml'));
    writeDoc(dir, 'bundle.md', claim('2026-09-11T00:00:00Z', '/inside.yaml'));
    writeDoc(dir, 'url.md', claim('2026-09-11T00:00:00Z', 'https://example.invalid/page'));
    writeDoc(dir, 'scope.md', claim('2026-09-11T00:00:00Z', 'the whole fleet'));
    writeDoc(dir, 'gone.md', claim('2026-09-11T00:00:00Z', '../missing.yaml'));
    const hits = (): string[] => lint(dir, t, process.env, NOW).issues.filter((i) => i.code === 'generated').map((i) => path.basename(i.file));
    assert.deepEqual(hits(), ['bundle.md', 'rel.md']);
    assert.match(only(dir, 'generated').join(), /2026-09-20.*2026-09-11/);

    // Regenerate: the claim is now at least as new as the source.
    writeDoc(dir, 'rel.md', claim('2026-09-20T23:00:00Z', '../machine.yaml'));
    writeDoc(dir, 'bundle.md', claim('2026-09-20T00:00:00Z', '/inside.yaml'));
    assert.deepEqual(hits(), []);

    // A source this machine does not have is not a finding.
    writeDoc(dir, 'rel.md', claim('2026-09-11T00:00:00Z', '../machine.yaml'));
    fs.rmSync(source);
    assert.deepEqual(hits(), []);
  } finally {
    removeDir(root);
  }
});

test('a legacy generated_from and updated still drive stale and generated', () => {
  const root = tmpDir('lint-legacy-gen');
  try {
    const dir = path.join(root, 'knowledge');
    const source = path.join(root, 'machine.yaml');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(source, 'hosts: []\n');
    const changed = new Date('2026-09-20T00:00:00Z');
    fs.utimesSync(source, changed, changed);
    writeDoc(dir, 'iz-yaml.md', doc({ id: 'iz-yaml', kind: 'map', tags: '[map]', updated: '2026-09-11', extra: 'generated_from: ../machine.yaml' }));
    assert.match(only(dir, 'generated').join(), /2026-09-20/);
    gitInit(dir);
    writeDoc(dir, 'iz-yaml.md', doc({ id: 'iz-yaml', kind: 'map', tags: '[map]', updated: '2020-01-01' }));
    gitInit(dir);
    assert.match(only(dir, 'stale').join(), /2020-01-01/);
  } finally {
    removeDir(root);
  }
});

test('dead-link: both link forms, a fragment as heading text and as slug', () => {
  const dir = tmpDir('lint-links');
  try {
    writeDoc(dir, 'target.md', okfDoc('Note', [], '## Failover steps\n\nText.\n'));
    const links = [
      '[[target]]',
      '[[target#failover STEPS]]',
      '[a](/target.md)',
      '[b](./target.md#Failover%20steps)',
      '[c](target.md#FAILOVER%20STEPS)',
      '[d](/target.md#failover-steps)',
      '[ext](https://example.invalid/x.md) [mail](mailto:a@example.invalid) [txt](notes.txt) [here](#local)',
      '`inline` and a fence:',
      '```',
      '[[nothing-here]] [x](/nothing.md)',
      '```',
    ];
    writeDoc(dir, 'source.md', okfDoc('Note', [], `${links.join('\n\n')}\n`));
    assert.deepEqual(only(dir, 'dead-link'), []);

    const dead = [
      '[[sqlite-over-vectors]]',
      '[[target#Нет раздела]]',
      '[the plan](/no-such-doc.md)',
      '[e](/target.md#failover-step)',
      '[f](./target.md#nope)',
    ];
    writeDoc(dir, 'source.md', okfDoc('Note', [], `${dead.join('\n\n')}\n`));
    assert.deepEqual(only(dir, 'dead-link'), dead.map((l) => `dead link ${l}`));
    const cli = runCli(['lint', '--dir', dir], {});
    assert.match(cli.stdout, /source\.md: dead link \[the plan\]\(\/no-such-doc\.md\)/);
  } finally {
    removeDir(dir);
  }
});

test('index: absent, out of date and current, around toc', () => {
  const root = tmpDir('lint-index');
  try {
    const dir = path.join(root, 'knowledge');
    writeDoc(dir, 'first.md', okfDoc('Note'));
    assert.deepEqual(findings(dir), ['index index.md: index.md is missing: run toc']);
    assert.equal(runCli(['toc', '--dir', dir]).code, 0);
    assert.deepEqual(findings(dir), []);
    writeDoc(dir, 'second.md', okfDoc('Note'));
    assert.deepEqual(findings(dir), ['index index.md: index.md is out of date: run toc']);
    const cli = runCli(['lint', '--dir', dir], {});
    assert.equal(cli.code, 1);
    assert.match(cli.stdout, /^index\.md: index\.md is out of date/m);
    assert.equal(runCli(['toc', '--dir', dir]).code, 0);
    assert.deepEqual(findings(dir), []);
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

test('generated: a source whose parent is a regular file does not abort the run', () => {
  const root = tmpDir('lint-enotdir');
  try {
    const dir = path.join(root, 'knowledge');
    writeDoc(dir, 'notes.md', okfDoc('Note'));
    writeDoc(
      dir,
      'a.md',
      okfDoc('Map', ['generated:', '  by: tool', '  at: 2026-09-11T00:00:00Z', 'sources:', '  - resource: notes.md/x', `  - resource: ${'n'.repeat(5000)}`])
    );
    assert.deepEqual(only(dir, 'generated'), []);
  } finally {
    removeDir(root);
  }
});

test('stale compares UTC dates on both sides: a commit at 00:20+02:00 is the day before in UTC', () => {
  const dir = tmpDir('lint-stale-utc');
  try {
    writeDoc(dir, 'a.md', okfDoc('Note', ['generated:', '  by: tool', '  at: 2026-10-21T22:10:00Z']));
    gitInit(dir, '2026-10-22T00:20:00+02:00');
    assert.deepEqual(only(dir, 'stale'), []);
  } finally {
    removeDir(dir);
  }
});

test('dead-link: a link to index.md or log.md is valid when the file exists, dead when it does not', () => {
  const dir = tmpDir('lint-reserved');
  try {
    const body = '[a](index.md) [b](/log.md) [c](./index.md#top) [[log]]\n';
    writeDoc(dir, 'src.md', okfDoc('Note', [], body));
    assert.equal(only(dir, 'dead-link').length, 4, 'neither file exists yet');
    writeDoc(dir, 'index.md', '---\nokf_version: "0.2"\n---\n');
    writeDoc(dir, 'log.md', '# Log\n');
    assert.deepEqual(only(dir, 'dead-link'), []);
  } finally {
    removeDir(dir);
  }
});

test('dead-link: links inside inline code spans are not links, in either form', () => {
  const dir = tmpDir('lint-inline-code');
  try {
    writeDoc(dir, 'src.md', okfDoc('Note', [], 'Write `[[nothing]]` or ``[x](/nothing.md)`` like that.\n'));
    assert.deepEqual(only(dir, 'dead-link'), []);
    writeDoc(dir, 'src.md', okfDoc('Note', [], 'Write `code` then [[nothing]].\n'));
    assert.deepEqual(only(dir, 'dead-link'), ['dead link [[nothing]]']);
  } finally {
    removeDir(dir);
  }
});

test('frontmatter: an id that is not a string is named', () => {
  const dir = tmpDir('lint-id-type');
  try {
    writeDoc(dir, 'a.md', okfDoc('Note', ['id: 42']));
    assert.deepEqual(only(dir, 'frontmatter'), ['id: must be a string']);
  } finally {
    removeDir(dir);
  }
});

test('dead-link: a fragment in NFC finds a heading written in NFD', () => {
  const dir = tmpDir('lint-nfd');
  try {
    writeDoc(dir, 'target.md', okfDoc('Note', [], `## Cafe\u0301 menu\n\nText.\n`));
    writeDoc(dir, 'src.md', okfDoc('Note', [], '[a](target.md#caf\u00e9-menu) [b](target.md#Caf%C3%A9%20menu)\n'));
    assert.deepEqual(only(dir, 'dead-link'), []);
  } finally {
    removeDir(dir);
  }
});
