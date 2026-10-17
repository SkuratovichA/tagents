// Reading what hooks/tmux-agent-state.sh writes.
//
// The two field-count cases are the point of this suite: SIX fields is a record
// written before the account column existed and says NOTHING about the account,
// which is not the same as an empty seventh field (that one means "the default
// account"). The dashboard tests `NF >= 7` for exactly this reason, and so does
// the reader.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { labelsBySession, parseStateLine, readAgentState, readHistory, readLabels, stateDir } from '../src/agent-state.ts';
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
  fs.writeFileSync(path.join(dir, 'not-a-key.tsv'), 'garbage\n');
  fs.mkdirSync(path.join(dir, 'sub'), { recursive: true });
  writeHistory(dir, [
    [1_760_000_000, 'start', 'sess-a', '%12', 'dashboard', '/Users/demo/git/demo'],
    [1_760_000_100, 'start', 'sess-b', '%0', 'tg-orchestrator', '/Users/demo/git/other'],
    [1_760_000_200, 'turn', 'sess-b', '%0', 'tg-orchestrator', '/Users/demo/git/other'],
  ]);
});
after(() => fs.rmSync(path.dirname(dir), { recursive: true, force: true }));

test('records are read newest first, and only real keys count', () => {
  const rows = readAgentState(dir);
  assert.deepEqual(rows.map((r) => r.key), ['s-sess-b', '12', '13']);
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
  assert.equal(readHistory(dir).length, 3);
});

// The shell owns labels.tsv (lib/tagents/names.sh), so the reader is pinned to
// label_of itself rather than to a copy of its rule: every key, a missing one
// included, must give what the dashboard's own lookup gives.
test('labels.tsv is read per key exactly as label_of reads it', () => {
  const tmp = tmpDir('agent-state-labels');
  try {
    const ldir = path.join(tmp, 'agent-state');
    fs.mkdirSync(ldir, { recursive: true });
    // `k` has an empty name on its first line and a real one on a later line: the
    // shell answers with the first line, empty or not.
    const lines = [
      'sess-a\tRenamed agent',
      '%12\tpane name',
      'no-tab-here',
      '\tno key',
      'sess-b\t',
      'sess-a\tlater line',
      'sess-c\tname\textra',
      'k\t',
      'k\tx',
    ];
    fs.writeFileSync(path.join(ldir, 'labels.tsv'), `${lines.join('\n')}\n`);
    const labels = readLabels(ldir);
    assert.deepEqual(
      [...labels],
      [
        ['sess-a', 'Renamed agent'],
        ['%12', 'pane name'],
        ['no-tab-here', ''],
        ['sess-b', ''],
        ['sess-c', 'name'],
        ['k', ''],
      ]
    );
    const root = fileURLToPath(new URL('../../..', import.meta.url));
    for (const key of ['sess-a', '%12', 'sess-b', 'sess-c', 'no-tab-here', 'k', 'missing']) {
      const r = spawnSync('bash', ['-c', `TAB=$'\\t'; . "$1/lib/tagents/names.sh" && label_of "$2"`, '_', root, key], {
        encoding: 'utf8',
        env: { ...process.env, STATE_DIR: ldir },
      });
      assert.equal(r.status, 0, r.stderr);
      assert.equal(labels.get(key) ?? '', r.stdout.replace(/\n$/, ''), key);
    }
    assert.equal(readLabels(path.join(ldir, 'missing')).size, 0);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('the driver lists what the hook published, filtered by label and state', async () => {
  const d = new ClaudeHeadlessDriver({ stateDir: dir });
  const all = await d.list();
  assert.deepEqual(all.map((r) => r.id), ['s-sess-b', '12', '13']);
  const first = all[0];
  assert.equal(first?.claudeSessionId, 'sess-b');
  assert.equal(first?.spec.label, 'tg-orchestrator');
  assert.equal(first?.spec.configDir, '/Users/demo/.claude-work');
  assert.equal(all[1]?.spec.configDir, null, 'an empty account column means the default one');
  assert.equal('configDir' in (all[2]?.spec ?? {}), false, 'a pre-account row says nothing, so it inherits');

  assert.deepEqual((await d.list({ label: 'dashboard' })).map((r) => r.id), ['12']);
  assert.deepEqual((await d.list({ state: ['blocked'] })).map((r) => r.id), ['s-sess-b']);
  assert.deepEqual((await d.list({ state: ['working', 'done'] })).map((r) => r.id), ['12', '13']);
});

test('last() reads the transcript the hook recorded', async () => {
  const d = new ClaudeHeadlessDriver({ stateDir: dir });
  const refs = await d.list({ state: ['working'] });
  const ref = refs[0];
  assert.ok(ref);
  assert.equal(await d.last(ref), null, 'the transcript in this fixture does not exist on disk');
});
