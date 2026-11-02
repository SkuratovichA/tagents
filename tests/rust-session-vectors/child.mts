// The args and env sections of the session vectors: the argv and the environment node's `buildArgs` and `childEnv` make for a spec, and for a parent environment.
//
// `childEnv` reads the directory of the running node and the home directory of the machine, so the cases name them `<node-dir>` and `<home>`: the generator puts the real ones into the parent's `PATH` before the call and takes them out of the answer, and the Rust test puts its own in.
import os from 'node:os';
import path from 'node:path';
import type { SessionSpec } from '../../packages/core/src/driver.ts';
import { buildArgs, childEnv } from '../../packages/core/src/claude-driver.ts';

const BASE: SessionSpec = { kind: 'claude', cwd: '/work', skipPermissions: false };

const SPECS: Array<{ readonly name: string; readonly spec: SessionSpec }> = [
  { name: 'minimal', spec: BASE },
  { name: 'model', spec: { ...BASE, model: 'opus' } },
  { name: 'effort', spec: { ...BASE, effort: 'high' } },
  { name: 'disallowed', spec: { ...BASE, disallowedTools: ['Bash', 'Edit'] } },
  { name: 'disallowed-empty', spec: { ...BASE, disallowedTools: [] } },
  { name: 'mcp', spec: { ...BASE, mcpConfig: '/m.json' } },
  { name: 'skip', spec: { ...BASE, skipPermissions: true } },
  { name: 'system-prompt', spec: { ...BASE, systemPromptFile: '/p.md' } },
  { name: 'empty-strings', spec: { ...BASE, model: '', effort: '', mcpConfig: '', systemPromptFile: '' } },
  {
    name: 'all',
    spec: { ...BASE, model: 'm', effort: 'e', disallowedTools: ['A', 'B', 'C'], mcpConfig: '/m', skipPermissions: true, systemPromptFile: '/p', label: 'l', logFile: '/l', env: { X: '1' }, bin: '/b', configDir: '/c' },
  },
];

const TEXTS = ['go', '-x go', '--', '', 'two words', '\u00e9\u{1F600}', 'line\nbreak'];
const RESUMES: Array<string | null> = [null, 'abc-123', ''];

export function argsVectors(): unknown {
  const cases = [];
  for (const { name, spec } of SPECS)
    for (const text of TEXTS) for (const resume of RESUMES) cases.push({ name, spec, text, resume, argv: buildArgs(spec, text, resume) });
  return { cases };
}

const NODE_DIR = path.dirname(process.execPath);
const LOCAL_BIN = path.join(os.homedir(), '.local', 'bin');
const HOME = os.homedir();

/** The real node directory and home written as placeholders, in either direction. */
const toPlaceholders = (text: string): string => text.split(NODE_DIR).join('<node-dir>').split(HOME).join('<home>');
const fromPlaceholders = (text: string): string => text.split('<node-dir>').join(NODE_DIR).split('<home>').join(HOME);

const PARENTS: Array<{ readonly name: string; readonly env: Record<string, string> }> = [
  { name: 'empty', env: {} },
  { name: 'path-only', env: { PATH: '/usr/bin:/bin' } },
  { name: 'path-with-empty-and-duplicate', env: { PATH: '/a::/b:/a:' } },
  { name: 'path-with-node-dir', env: { PATH: '<node-dir>:/a' } },
  { name: 'path-with-node-dir-late', env: { PATH: '/a:<node-dir>:/b' } },
  { name: 'path-with-local-bin', env: { PATH: '/a:<home>/.local/bin:/b' } },
  { name: 'path-empty', env: { PATH: '' } },
  { name: 'account', env: { CLAUDE_CONFIG_DIR: '/a', CLAUDE_X: '1', CLAUDECODE: '1', Claude_low: '2', NOTCLAUDE: '3', PATH: '/p' } },
  { name: 'account-empty', env: { CLAUDE_CONFIG_DIR: '', PATH: '/p' } },
  { name: 'other-vars', env: { HOME: '/h', TA_LABEL: 'old', TA_LOG: '/old', LANG: 'C', PATH: '/p' } },
];

const ENV_SPECS: Array<{ readonly name: string; readonly spec: SessionSpec }> = [
  { name: 'inherit', spec: BASE },
  { name: 'default-account', spec: { ...BASE, configDir: null } },
  { name: 'account', spec: { ...BASE, configDir: '/acct' } },
  { name: 'empty-account', spec: { ...BASE, configDir: '' } },
  { name: 'label-log', spec: { ...BASE, label: 'l', logFile: '/log' } },
  { name: 'empty-label-log', spec: { ...BASE, label: '', logFile: '' } },
  { name: 'env-wins', spec: { ...BASE, label: 'l', env: { TA_LABEL: 'mine', PATH: '/mine', CLAUDE_X: '9', NEW: 'n' } } },
  { name: 'env-empty-value', spec: { ...BASE, env: { E: '' } } },
  { name: 'env-account', spec: { ...BASE, configDir: '/acct', env: { CLAUDE_CONFIG_DIR: '/env' } } },
];

export function envVectors(): unknown {
  const cases = [];
  for (const parent of PARENTS)
    for (const { name, spec } of ENV_SPECS) {
      const real: NodeJS.ProcessEnv = Object.fromEntries(Object.entries(parent.env).map(([k, v]) => [k, fromPlaceholders(v)]));
      const env = childEnv(spec, real);
      cases.push({ parent: parent.name, spec: name, parentEnv: parent.env, specValue: spec, env: Object.fromEntries(Object.entries(env).map(([k, v]) => [k, toPlaceholders(v ?? '')])) });
    }
  return { cases, localBin: toPlaceholders(LOCAL_BIN) };
}
