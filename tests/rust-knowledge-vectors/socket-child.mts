// Runs in a child process whose environment is the case: what `socketDir` and `canonicalEnv` make of it, as JSON on stdout.
import os from 'node:os';
import { KEY_VARS, canonicalEnv, serverKey, socketDir } from '../../packages/knowledge/src/mcp/socket.ts';

const input: unknown = JSON.parse(process.argv[2] ?? '{}');
const cwd = typeof input === 'object' && input !== null && 'cwd' in input && typeof input.cwd === 'string' ? input.cwd : '/';
const canonical = canonicalEnv(process.env, cwd);
process.stdout.write(
  JSON.stringify({
    uid: os.userInfo().uid,
    dir: socketDir(process.env),
    lines: KEY_VARS.map((name) => `${name}=${canonical[name] ?? ''}`),
    key: serverKey(canonical, 'vectors'),
  })
);
