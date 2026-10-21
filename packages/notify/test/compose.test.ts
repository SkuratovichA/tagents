// node --test compose.test.ts
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, test } from 'node:test';
import { tmpDir } from '@tagents/core';
import { agentName, compose, untitle } from '../src/compose.ts';
import { phrasesFor } from '../src/phrases.ts';
import { event } from './fakes.ts';

const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const en = phrasesFor('en');

test('untitle gives what the shell function gives, title by title', () => {
  const titles = [
    '✳ два слова',
    'два слова',
    '✳ Search index rebuild',
    'Search index rebuild',
    'A thing',
    '⚠️ two code points',
    ' leading space',
    'x',
    '',
    '✳  two spaces after the glyph',
    '7 days',
    'я иду',
    'é tout',
    'ω omega',
    '中 文',
    '· middle dot',
    '- dash',
    '⠂ braille spinner',
    '→ arrow',
    '🚀 rocket',
  ];
  for (const title of titles) {
    const shell = execFileSync(
      'bash',
      ['-c', '. "$1/lib/tagents/names.sh" && untitle_of "$2"', '_', REPO_ROOT, title],
      { encoding: 'utf8', env: { ...process.env, STATE_DIR: '/nonexistent' } }
    ).replace(/\n$/, '');
    assert.equal(untitle(title), shell, JSON.stringify(title));
  }
});

test('untitle keeps a one-letter word and drops a symbol glyph', () => {
  assert.equal(untitle('⠂ build agent'), 'build agent');
  assert.equal(untitle('я иду'), 'я иду');
  assert.equal(untitle('🚀 rocket'), 'rocket');
});

const nameArgs = {
  sessionId: 'sess-1',
  pane: '%12',
  paneTitle: '✳ pane title',
  label: 'ticket-agent',
  cwd: '/work/some-project',
  hostname: 'mbp.local',
  labels: new Map<string, string>(),
};

test('agentName: a label typed for the session beats one for the pane', () => {
  const labels = new Map([['sess-1', 'by session'], ['%12', 'by pane']]);
  assert.equal(agentName({ ...nameArgs, labels }), 'by session');
});

test('agentName: a label typed for the pane beats the pane title', () => {
  assert.equal(agentName({ ...nameArgs, labels: new Map([['%12', 'by pane']]) }), 'by pane');
});

test('agentName: the pane title, without its glyph, beats TA_LABEL', () => {
  assert.equal(agentName(nameArgs), 'pane title');
});

test('agentName: with no title, TA_LABEL; with no label either, the directory name', () => {
  assert.equal(agentName({ ...nameArgs, paneTitle: '' }), 'ticket-agent');
  assert.equal(agentName({ ...nameArgs, paneTitle: '', label: '' }), 'some-project');
});

test('agentName: a title equal to the hostname, long or short, falls to the directory name', () => {
  assert.equal(agentName({ ...nameArgs, paneTitle: 'mbp.local' }), 'some-project');
  assert.equal(agentName({ ...nameArgs, paneTitle: 'mbp' }), 'some-project');
  assert.equal(agentName({ ...nameArgs, paneTitle: '', label: 'mbp' }), 'some-project');
});

test('agentName: a session with no pane looks nothing up by pane', () => {
  const labels = new Map([['', 'must not be used']]);
  assert.equal(agentName({ ...nameArgs, pane: '', paneTitle: '', labels }), 'ticket-agent');
});

const dirs: string[] = [];
after(() => {
  for (const dir of dirs) fs.rmSync(dir, { recursive: true, force: true });
});

function transcript(text: string): string {
  const dir = tmpDir('notify-compose');
  dirs.push(dir);
  const file = path.join(dir, 't.jsonl');
  const line = { type: 'assistant', message: { content: [{ type: 'text', text }] } };
  fs.writeFileSync(file, `${JSON.stringify(line)}\n`);
  return file;
}

test('turn_done: the body is the first non-empty line of the last answer', () => {
  const e = event({ transcript: transcript('\n\nFirst line\nsecond') });
  const c = compose('turn_done', e, 'proj', {}, en);
  assert.equal(c.body, 'First line');
});

test('turn_done: a long first line is clipped to 200 characters', () => {
  const e = event({ transcript: transcript('x'.repeat(500)) });
  const body = compose('turn_done', e, 'proj', {}, en).body;
  assert.equal([...body].length, 200);
  assert.ok(body.endsWith('…'));
  const exact = compose('turn_done', event({ transcript: transcript('y'.repeat(200)) }), 'proj', {}, en).body;
  assert.equal(exact, 'y'.repeat(200));
});

test('turn_done: a missing transcript, or none given, is "Your move"', () => {
  assert.equal(compose('turn_done', event({ transcript: '/nonexistent/t.jsonl' }), 'p', {}, en).body, 'Your move');
  assert.equal(compose('turn_done', event({ transcript: '' }), 'p', {}, en).body, 'Your move');
});

test('subtitle: the phrase alone when the project is the title, with the project otherwise', () => {
  const e = event({ cwd: '/work/proj' });
  assert.equal(compose('turn_done', e, 'proj', {}, en).subtitle, 'Answer ready');
  assert.equal(compose('turn_done', e, 'build agent', {}, en).subtitle, 'Answer ready · proj');
  assert.equal(compose('turn_done', event({ cwd: '' }), 'build agent', {}, en).subtitle, 'Answer ready');
  assert.equal(compose('turn_done', e, 'build agent', {}, en).title, 'build agent');
});

test('question: the event text, or "Asking you something"; a plan has its own subtitle', () => {
  const q = compose('question', event({ text: 'Which database?' }), 'proj', {}, en);
  assert.equal(q.subtitle, 'Asks you something');
  assert.equal(q.body, 'Which database?');
  assert.equal(compose('question', event({ text: '' }), 'proj', {}, en).body, 'Asking you something');
  assert.equal(compose('question', event({}), 'proj', { plan: true }, en).subtitle, 'Plan ready for review');
});

test('permission: the event text', () => {
  const c = compose('permission', event({ text: 'Claude needs your permission to use Bash' }), 'proj', {}, en);
  assert.equal(c.subtitle, 'Needs your permission');
  assert.equal(c.body, 'Claude needs your permission to use Bash');
});

test('cache_expiring: the idle and the left minutes in the body', () => {
  const c = compose('cache_expiring', event(), 'proj', { idleMin: 50, leftMin: 10 }, en);
  assert.equal(c.subtitle, 'Prompt cache expiring');
  assert.equal(c.body, 'Idle 50 min — send anything within ~10 min to keep the prompt cache');
});

test('session_end', () => {
  const end = compose('session_end', event({ sub: 'prompt_input_exit' }), 'proj', {}, en);
  assert.equal(end.subtitle, 'Session ended');
  assert.equal(end.body, 'prompt_input_exit');
});

test('the Russian table speaks Russian and has the same shape', () => {
  const ru = phrasesFor('ru');
  assert.deepEqual(Object.keys(ru).sort(), Object.keys(en).sort());
  const c = compose('cache_expiring', event(), 'proj', { idleMin: 50, leftMin: 10 }, ru);
  assert.match(c.subtitle, /[а-я]/i);
  assert.match(c.body, /50/);
  assert.match(c.body, /10/);
});

test('cache_expiring: minutes left below one read "within a minute", never "~0 min", in both languages', () => {
  const e = event({});
  const ru = phrasesFor('ru');
  assert.equal(
    compose('cache_expiring', e, 'p', { idleMin: 55, leftMin: 0 }, en).body,
    'Idle 55 min — send anything within a minute to keep the prompt cache'
  );
  assert.equal(
    compose('cache_expiring', e, 'p', { idleMin: 55, leftMin: 0 }, ru).body,
    'Простой 55 мин — отправьте что угодно в течение минуты, чтобы сохранить кэш промпта'
  );
  assert.match(compose('cache_expiring', e, 'p', { idleMin: 55, leftMin: 1 }, en).body, /within ~1 min/);
  assert.match(compose('cache_expiring', e, 'p', { idleMin: 55, leftMin: 5 }, ru).body, /в течение ~5 мин/);
});

test('permission: an empty message falls back to a phrase, in both languages', () => {
  const e = event({ text: '' });
  assert.equal(compose('permission', e, 'p', {}, en).body, 'Waiting for your permission');
  assert.equal(compose('permission', e, 'p', {}, phrasesFor('ru')).body, 'Ждёт вашего разрешения');
  assert.equal(compose('permission', event({ text: 'Run rm?' }), 'p', {}, en).body, 'Run rm?');
});

test('session_end: an empty reason falls back to a phrase, in both languages', () => {
  const e = event({ sub: '' });
  assert.equal(compose('session_end', e, 'p', {}, en).body, 'No reason given');
  assert.equal(compose('session_end', e, 'p', {}, phrasesFor('ru')).body, 'Причина не указана');
  assert.equal(compose('session_end', event({ sub: 'logout' }), 'p', {}, en).body, 'logout');
});

test('turn_done: the event text wins over the transcript, and is clipped; empty text reads the transcript', () => {
  const file = transcript('Older answer');
  assert.equal(compose('turn_done', event({ text: 'Fresh answer', transcript: file }), 'p', {}, en).body, 'Fresh answer');
  const long = compose('turn_done', event({ text: 'z'.repeat(500), transcript: file }), 'p', {}, en).body;
  assert.equal([...long].length, 200);
  assert.equal(compose('turn_done', event({ text: '', transcript: file }), 'p', {}, en).body, 'Older answer');
});

