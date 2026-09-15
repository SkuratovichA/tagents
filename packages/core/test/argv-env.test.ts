// What the child is actually started with. Two contracts meet here: the argv
// the orchestrator's oracle asserts on, and the environment that decides WHICH
// ACCOUNT the session lands on — a whole login, not a setting.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { buildArgs, childEnv, DISALLOWED_TOOLS } from '../src/claude-driver.ts';
import type { SessionSpec } from '../src/driver.ts';
import { ClaudeHeadlessDriver } from '../src/claude-driver.ts';
import { fakeClaude, tmpDir } from '../src/testkit.ts';

const base: SessionSpec = { kind: 'claude', cwd: '/tmp', skipPermissions: false };

let tmp: string;
before(() => {
  tmp = tmpDir('argv-test');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test('the minimum: -p, stream-json and --verbose, prompt last', () => {
  const args = buildArgs(base, 'hello', null);
  assert.deepEqual(args, ['-p', '--output-format', 'stream-json', '--verbose', 'hello']);
  assert.equal(args.at(-1), 'hello', 'the prompt is always the last positional');
});

test('every spec field lands on the command line, in the documented order', () => {
  const spec: SessionSpec = {
    ...base,
    model: 'fable',
    effort: 'high',
    skipPermissions: true,
    systemPromptFile: '/p/agent.md',
    mcpConfig: '/p/mcp.json',
    disallowedTools: ['Bash', 'WebFetch'],
  };
  assert.deepEqual(buildArgs(spec, 'go', 'sess-7'), [
    '-p',
    '--model',
    'fable',
    '--effort',
    'high',
    '--disallowedTools',
    'Bash,WebFetch',
    '--strict-mcp-config',
    '--mcp-config',
    '/p/mcp.json',
    '--output-format',
    'stream-json',
    '--verbose',
    '--dangerously-skip-permissions',
    '--append-system-prompt-file',
    '/p/agent.md',
    '--resume',
    'sess-7',
    'go',
  ]);
});

// `--disallowedTools <tools...>` and `--mcp-config <configs...>` are variadic
// on the CLI: they eat argv words until the next option. With the prompt right
// after one of them, `claude -p` turned the busano ticket agent's prompt into
// tool names and died with "Input must be provided either through stdin or as
// a prompt argument" on every fresh session (15.09.2026). Whatever the spec,
// each variadic option must be followed by its one value and then an option.
test('a variadic option is never the last thing before the prompt', () => {
  const specs: SessionSpec[] = [
    { ...base, disallowedTools: ['Bash'] },
    { ...base, mcpConfig: '/p/mcp.json' },
    { ...base, disallowedTools: ['Bash'], mcpConfig: '/p/mcp.json' },
    { ...base, model: 'opus', skipPermissions: true, systemPromptFile: '/p/a.md', disallowedTools: DISALLOWED_TOOLS },
    { ...base, effort: 'high', mcpConfig: '/p/mcp.json', disallowedTools: DISALLOWED_TOOLS },
  ];
  for (const spec of specs)
    for (const resume of [null, 'sess-1']) {
      const args = buildArgs(spec, 'the prompt', resume);
      assert.equal(args.at(-1), 'the prompt');
      for (const flag of ['--disallowedTools', '--mcp-config']) {
        const i = args.indexOf(flag);
        if (i === -1) continue;
        assert.ok(
          args[i + 2]?.startsWith('--'),
          `${flag} must be followed by one value and then an option, got: ${args.slice(i, i + 3).join(' ')}`
        );
      }
    }
});

test('tools are refused by name, never with an empty --tools', () => {
  const args = buildArgs({ ...base, disallowedTools: DISALLOWED_TOOLS }, 'go', null);
  assert.ok(args.includes('--disallowedTools'));
  assert.ok(!args.includes('--tools'), '`--tools ""` drops the MCP tools as well');
  assert.equal(args[args.indexOf('--disallowedTools') + 1], DISALLOWED_TOOLS.join(','));
  assert.deepEqual(buildArgs({ ...base, disallowedTools: [] }, 'go', null), buildArgs(base, 'go', null));
});

test('every CLAUDE* variable is dropped before the child sees it', () => {
  const e = childEnv(base, { CLAUDE_CONFIG_DIR: '/a/.claude-work', CLAUDE_CODE_X: '1', KEEP: 'yes' });
  assert.equal(e['CLAUDE_CODE_X'], undefined);
  assert.equal(e['KEEP'], 'yes');
});

test('configDir is tri-state: inherit, unset, set', () => {
  const parent = { CLAUDE_CONFIG_DIR: '/a/.claude-work' };
  assert.equal(childEnv(base, parent)['CLAUDE_CONFIG_DIR'], '/a/.claude-work', 'undefined inherits');
  assert.equal(childEnv({ ...base, configDir: null }, parent)['CLAUDE_CONFIG_DIR'], undefined, 'null unsets');
  assert.equal(childEnv({ ...base, configDir: '/b/.claude-x' }, parent)['CLAUDE_CONFIG_DIR'], '/b/.claude-x');
});

test('our node is pinned on the child PATH, ahead of whatever was inherited', () => {
  const e = childEnv(base, { PATH: '/usr/bin:/bin' });
  const dirs = (e['PATH'] ?? '').split(':');
  assert.equal(dirs[0], path.dirname(process.execPath));
  assert.ok(dirs.includes(path.join(os.homedir(), '.local', 'bin')), 'where the claude symlink lives');
  assert.ok(dirs.includes('/usr/bin'));
  assert.equal(new Set(dirs).size, dirs.length, 'no duplicate entries');
});

test('the label and the log reach the child as TA_LABEL / TA_LOG', () => {
  const e = childEnv({ ...base, label: 'tg-orchestrator', logFile: '/var/log/x.log' }, {});
  assert.equal(e['TA_LABEL'], 'tg-orchestrator');
  assert.equal(e['TA_LOG'], '/var/log/x.log');
  assert.equal(childEnv(base, {})['TA_LABEL'], undefined);
});

test('spec.env is merged last and wins', () => {
  const e = childEnv({ ...base, label: 'a', env: { TA_LABEL: 'b', EXTRA: '1' } }, { PATH: '/bin' });
  assert.equal(e['TA_LABEL'], 'b');
  assert.equal(e['EXTRA'], '1');
});

test('the argv and env a real spawn produces', async () => {
  const argvFile = path.join(tmp, 'argv.json');
  const fake = fakeClaude({ argvFile, result: { text: 'ok' } }, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const d = new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state') });
  const spec: SessionSpec = {
    kind: 'claude',
    cwd: tmp,
    skipPermissions: true,
    bin: fake.bin,
    label: 'smoke',
    model: 'fable',
    effort: 'high',
    configDir: '/x/.claude-smoke',
  };
  const ref = await d.open(spec, 'sess-old');
  const o = await d.prompt(ref, 'hello there', { timeoutMs: 5000 });
  assert.equal(o.kind, 'ok');
  const seen: unknown = JSON.parse(fs.readFileSync(argvFile, 'utf8'));
  const call = seen as { argv: string[]; env: Record<string, string> };
  assert.deepEqual(call.argv, buildArgs(spec, 'hello there', 'sess-old'));
  assert.equal(call.env['TA_LABEL'], 'smoke');
  assert.equal(call.env['CLAUDE_CONFIG_DIR'], '/x/.claude-smoke');
});
