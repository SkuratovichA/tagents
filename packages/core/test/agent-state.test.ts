// Reading what hooks/tmux-agent-state.sh writes.
//
// The two field-count cases are the point of this suite: SIX fields is a record
// written before the account column existed and says NOTHING about the account,
// which is not the same as an empty seventh field (that one means "the default
// account"). The dashboard tests `NF >= 7` for exactly this reason, and so does
// the reader.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { labelsBySession, parseStateLine, readAgentState, readHistory, stateDir } from '../src/agent-state.ts';
import { ClaudeHeadlessDriver } from '../src/claude-driver.ts';
import { tmpDir } from '../src/testkit.ts';
import { writeHistory, writeStateRow } from './helpers.ts';

let dir: string;
before(() => {
  dir = path.join(tmpDir('agent-state-test'), 'agent-state');
  writeStateRow(dir, {
    key: '12',
    at: 1_760_000_000,
    state: 'working',
    sessionId: 'sess-a',
    cwd: '/Users/demo/git/demo',
    transcript: '/Users/demo/.claude/projects/-Users-demo-git-demo/sess-a.jsonl',
    detail: 'Bash ls',
    configDir: '',
  });
  writeStateRow(dir, {
    key: 's-sess-b',
    at: 1_760_000_100,
    state: 'blocked',
    sessionId: 'sess-b',
    cwd: '/Users/demo/git/other',
    detail: 'Claude needs your permission to use Bash',
    configDir: '/Users/demo/.claude-work',
    pid: 4242,
  });
  writeStateRow(dir, { key: '13', at: 1_759_000_000, state: 'done', sessionId: 'sess-c', configDir: null });
  // A headless record in full: ten fields, the last two the log and the label.
  writeStateRow(dir, {
    key: 's-sess-d',
    at: 1_760_000_050,
    state: 'working',
    sessionId: 'sess-d',
    cwd: '/Users/demo/git/demo',
    configDir: '',
    pid: 5151,
    logFile: '/tmp/ticket-agent.log',
    label: 'ticket-agent',
  });
  // ...and a child of it: twelve, the last two naming the agent that started it.
  writeStateRow(dir, {
    key: 's-sess-e',
    at: 1_760_000_060,
    state: 'working',
    sessionId: 'sess-e',
    cwd: '/Users/demo/git/scratch',
    configDir: '',
    pid: 5252,
    logFile: '',
    label: '',
    parentKey: 's-sess-d',
    parentSid: 'sess-d',
  });
  fs.writeFileSync(path.join(dir, 'not-a-key.tsv'), 'garbage\n');
  fs.mkdirSync(path.join(dir, 'sub'), { recursive: true });
  writeHistory(dir, [
    [1_760_000_000, 'start', 'sess-a', '%12', 'dashboard', '/Users/demo/git/demo'],
    [1_760_000_100, 'start', 'sess-b', '%0', 'tg-orchestrator', '/Users/demo/git/other'],
    [1_760_000_200, 'turn', 'sess-b', '%0', 'tg-orchestrator', '/Users/demo/git/other'],
    [1_760_000_300, 'start', 'sess-e', '', '', '/Users/demo/git/scratch', 'sess-d'],
  ]);
});
after(() => fs.rmSync(path.dirname(dir), { recursive: true, force: true }));

test('records are read newest first, and only real keys count', () => {
  const rows = readAgentState(dir);
  assert.deepEqual(rows.map((r) => r.key), ['s-sess-b', 's-sess-e', 's-sess-d', '12', '13']);
});

test('the seventh column is the account, and its absence is not an empty one', () => {
  const rows = readAgentState(dir);
  const byKey = new Map(rows.map((r) => [r.key, r]));
  assert.equal(byKey.get('12')?.configDir, '', 'empty seventh field = the default account');
  assert.equal(byKey.get('12')?.hasConfigDir, true);
  assert.equal(byKey.get('s-sess-b')?.configDir, '/Users/demo/.claude-work');
  assert.equal(byKey.get('13')?.configDir, null, 'six fields = written before the column existed');
  assert.equal(byKey.get('13')?.hasConfigDir, false);
});

test('an eighth column is the headless pid', () => {
  const rows = readAgentState(dir);
  assert.equal(rows.find((r) => r.key === 's-sess-b')?.pid, 4242);
  assert.equal(rows.find((r) => r.key === '12')?.pid, null);
});

test('the columns past the account belong to the rows with no pane', () => {
  const byKey = new Map(readAgentState(dir).map((r) => [r.key, r]));
  // Twelve fields: a child, and it says whose.
  const kid = byKey.get('s-sess-e');
  assert.equal(kid?.pid, 5252);
  assert.equal(kid?.parentKey, 's-sess-d');
  assert.equal(kid?.parentSid, 'sess-d');
  assert.equal(kid?.label, '', 'an inherited label is blanked by the hook, not absent');
  // Ten: a headless session, with a log and a name and nobody above it.
  const daemon = byKey.get('s-sess-d');
  assert.equal(daemon?.logFile, '/tmp/ticket-agent.log');
  assert.equal(daemon?.label, 'ticket-agent');
  assert.equal(daemon?.parentKey, null, 'ten fields say nothing about a parent');
  assert.equal(daemon?.parentSid, null);
  // Seven: a session with a pane, which carries none of it.
  const paned = byKey.get('12');
  assert.equal(paned?.pid, null);
  assert.equal(paned?.logFile, null);
  assert.equal(paned?.label, null);
  assert.equal(paned?.parentKey, null);
  assert.equal(paned?.parentSid, null);
});

test('a history line names the parent of a child, and of nobody else', () => {
  const byId = new Map(readHistory(dir).map((h) => [h.sessionId, h]));
  assert.equal(byId.get('sess-e')?.parentSid, 'sess-d');
  assert.equal(byId.get('sess-e')?.pane, '', 'a child has no pane to name');
  assert.equal(byId.get('sess-a')?.parentSid, '', 'six columns mean no parent');
});

test('a truncated or nonsense line is skipped, not crashed on', () => {
  assert.equal(parseStateLine('9', 'nope'), null);
  assert.equal(parseStateLine('9', '1760000000\tworking\tsess'), null, 'fewer than six fields');
  assert.equal(parseStateLine('9', 'not-a-number\tworking\ts\t/c\t/t\td\t'), null);
  assert.equal(parseStateLine('9', '1760000000\tinvented\ts\t/c\t/t\td\t'), null, 'an unknown state');
});

test('a missing directory is no agents, not an exception', () => {
  assert.deepEqual(readAgentState(path.join(dir, 'nope')), []);
  assert.deepEqual(readHistory(path.join(dir, 'nope')), []);
});

test('TA_STATE_DIR decides where the records are, ~/.claude/agent-state otherwise', () => {
  assert.equal(stateDir({ TA_STATE_DIR: '/x/state' }), '/x/state');
  assert.equal(stateDir({}), path.join(os.homedir(), '.claude', 'agent-state'));
});

test('history carries the labels, latest start wins', () => {
  const labels = labelsBySession(dir);
  assert.equal(labels.get('sess-a'), 'dashboard');
  assert.equal(labels.get('sess-b'), 'tg-orchestrator');
  assert.equal(readHistory(dir).length, 4);
});

test('the driver lists what the hook published, filtered by label and state', async () => {
  const d = new ClaudeHeadlessDriver({ stateDir: dir });
  const all = await d.list();
  assert.deepEqual(all.map((r) => r.id), ['s-sess-b', 's-sess-e', 's-sess-d', '12', '13']);
  const first = all.find((r) => r.id === 's-sess-b');
  assert.equal(first?.claudeSessionId, 'sess-b');
  assert.equal(first?.spec.label, 'tg-orchestrator');
  assert.equal(first?.spec.configDir, '/Users/demo/.claude-work');
  assert.equal(all.find((r) => r.id === '12')?.spec.configDir, null, 'an empty account column means the default one');
  assert.equal(
    'configDir' in (all.find((r) => r.id === '13')?.spec ?? {}),
    false,
    'a pre-account row says nothing, so it inherits'
  );

  assert.deepEqual((await d.list({ label: 'dashboard' })).map((r) => r.id), ['12']);
  assert.deepEqual((await d.list({ state: ['blocked'] })).map((r) => r.id), ['s-sess-b']);
  assert.deepEqual(
    (await d.list({ state: ['working', 'done'] })).map((r) => r.id),
    ['s-sess-e', 's-sess-d', '12', '13']
  );
});

test('last() reads the transcript the hook recorded', async () => {
  const d = new ClaudeHeadlessDriver({ stateDir: dir });
  const refs = await d.list({ state: ['working'] });
  const ref = refs[0];
  assert.ok(ref);
  assert.equal(await d.last(ref), null, 'the transcript in this fixture does not exist on disk');
});
