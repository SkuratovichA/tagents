// The transcript reader, against the fixtures recorded from sessions.mjs.
//
// This one is pure formatted text: an agent reads it out of a shell and
// paraphrases it, so column widths, the `~`-folded project path, the
// `01-02 03:04` timestamp shape and the trailer line are all part of what
// callers see. The fixtures are the ORACLE — they were produced by the .mjs
// this file ports, and they are copied here byte for byte (including the
// trailer naming sessions.mjs) so the port can prove it changed nothing.
//
// Driven by synthetic transcripts under CLAUDE_HOMES with FIXED mtimes, so
// every byte of the output is deterministic.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import {
  collect,
  decodeProjectSlug,
  discoverAccounts,
  firstPrompt,
  lastAssistant,
  lastAssistantText,
  MIN_TRANSCRIPT_BYTES,
  renderRecent,
  renderSearch,
  renderShow,
} from '../src/transcripts.ts';
import { tmpDir } from '../src/testkit.ts';
import { expectFixture, seedSessions, writeSession } from './helpers.ts';

let tmp: string;
let claudeHome: string;
const saved = { HOME: process.env['HOME'], CLAUDE_HOMES: process.env['CLAUDE_HOMES'] };

before(() => {
  tmp = tmpDir('transcripts-test');
  claudeHome = path.join(tmp, '.claude');
  seedSessions(claudeHome);
  process.env['HOME'] = tmp;
  process.env['CLAUDE_HOMES'] = claudeHome;
});
after(() => {
  if (saved.HOME === undefined) delete process.env['HOME'];
  else process.env['HOME'] = saved.HOME;
  if (saved.CLAUDE_HOMES === undefined) delete process.env['CLAUDE_HOMES'];
  else process.env['CLAUDE_HOMES'] = saved.CLAUDE_HOMES;
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('recent: newest first, two lines per session, trailer', () => {
  expectFixture('sessions/recent.txt', renderRecent());
});

test('recent N caps the list', () => {
  expectFixture('sessions/recent-1.txt', renderRecent(1));
});

test('search matches the project path and the opening prompt', () => {
  expectFixture('sessions/search-deploy.txt', renderSearch(['deploy']));
  expectFixture('sessions/search-miss.txt', renderSearch(['zzzznothing']));
});

test('show: opening prompt + last assistant reply from the tail', () => {
  expectFixture('sessions/show.txt', renderShow('aaaaaaaa') ?? '(no such session)');
  assert.equal(renderShow('nope'), null, 'an unknown prefix is not an empty page');
});

test('CLAUDE_HOMES is the discovery override, and it points at projects/', () => {
  const accounts = discoverAccounts();
  assert.deepEqual(accounts, [{ name: 'personal', dir: path.join(claudeHome, 'projects') }]);
});

test('a transcript under the 2000-byte floor is an aborted start, not a session', () => {
  const dir = path.join(claudeHome, 'projects', '-Users-demo-git-tiny');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'cccccccc-0000-0000-0000-000000000000.jsonl'), '{"type":"user"}\n');
  assert.ok(fs.statSync(path.join(dir, 'cccccccc-0000-0000-0000-000000000000.jsonl')).size < MIN_TRANSCRIPT_BYTES);
  assert.equal(collect().some((r) => r.id.startsWith('cccccccc')), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('the head window holds the opening prompt, the tail window the last reply', () => {
  const rows = collect();
  const row = rows.find((r) => r.id.startsWith('aaaaaaaa'));
  assert.ok(row);
  assert.equal(firstPrompt(row.file), 'Fix the deploy script for the staging cluster');
  assert.equal(lastAssistantText(row.file), 'Deploy script fixed and staging is green.');
  const last = lastAssistant(row.file);
  assert.equal(last?.text, 'Deploy script fixed and staging is green.');
  assert.equal(last?.at, new Date('2026-01-02T03:04:05.000Z').getTime());
});

test('a meta first message is not the opening prompt', () => {
  const file = writeSession(claudeHome, {
    slug: '-Users-demo-git-meta',
    id: 'dddddddd-0000-0000-0000-000000000000',
    prompt: 'the real question',
    reply: 'the real answer',
    mtime: '2025-12-01T00:00:00.000Z',
  });
  assert.equal(firstPrompt(file), 'the real question');
  fs.rmSync(path.dirname(file), { recursive: true, force: true });
});

test('project slugs fold the home directory back to ~', () => {
  assert.equal(decodeProjectSlug('-Users-demo-git-x', '/Users/demo'), '~/git/x');
  assert.equal(decodeProjectSlug('-opt-src-y', '/Users/demo'), '/opt/src/y');
});
