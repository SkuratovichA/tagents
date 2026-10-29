// Fixtures the call tests share. Not a test file: the runner's glob only picks up *.test.ts.
//
// A program is a shell script written into a temporary directory that is the whole PATH, so nothing of the machine can answer. A script finds its own directory in `$D` and writes the pids it wants checked there, one file each: `rig.pids` reads them back, and `rig.stop` kills whatever is still alive, so a test that fails halfway leaves no `sleep` behind.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { CliContract } from '@tagents/core';
import { toolSpecs } from '../src/tools.ts';

export const fakeCli: CliContract = {
  program: 'tagents-fake',
  exit: { ok: 0, error: 1, usage: 2, refused: 3, timeout: 4 },
  commands: [
    { path: ['echo'], positionals: ['[text]'], options: { loud: { type: 'boolean' }, name: { type: 'string' } }, required: [], summary: 'prints', effect: 'read' },
    { path: ['stdin'], positionals: [], options: {}, required: [], summary: 'reads stdin', effect: 'read' },
    { path: ['hang'], positionals: [], options: {}, required: [], summary: 'never ends', effect: 'read' },
    { path: ['window'], positionals: [], options: {}, required: [], summary: 'opens a window', effect: 'spawn', requires: 'tmux' },
  ],
};

export function fakeTool(name: string) {
  const found = toolSpecs([fakeCli]).find((t) => t.name === name);
  if (found === undefined) throw new Error(`no fake tool ${name}`);
  return found;
}

export interface Rig {
  readonly dir: string;
  readonly env: NodeJS.ProcessEnv;
  /** the pids the script wrote into `$D/*.pid`, by file name without the extension */
  pids(): Readonly<Record<string, number>>;
}

const rigs: Rig[] = [];

export function rig(script: string): Rig {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-run-')));
  fs.writeFileSync(path.join(dir, 'tagents-fake'), `#!/bin/sh\nD=$(dirname "$0")\n${script}\n`, { mode: 0o755 });
  const made: Rig = {
    dir,
    env: { PATH: `${dir}:/usr/bin:/bin` },
    pids: () =>
      Object.fromEntries(
        fs
          .readdirSync(dir)
          .filter((file) => file.endsWith('.pid'))
          .flatMap((file) => {
            const pid = Number.parseInt(fs.readFileSync(path.join(dir, file), 'utf8'), 10);
            return Number.isInteger(pid) ? [[file.slice(0, -'.pid'.length), pid] as const] : [];
          })
      ),
  };
  rigs.push(made);
  return made;
}

/** Alive means running: a process that has exited and is waiting to be reaped is a zombie and counts as gone. */
export function alive(pid: number): boolean {
  try {
    return !execFileSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' }).trim().startsWith('Z');
  } catch {
    return false;
  }
}

const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** A bounded poll: true as soon as the condition holds, false when `ms` have passed. */
export async function until(condition: () => boolean, ms = 5000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await delay(25);
  }
  return condition();
}

/** The promise's value, or `undefined` when it has not settled within `ms`: a call that hangs fails an assertion instead of the whole run. */
export async function within<T>(promise: Promise<T>, ms: number): Promise<T | undefined> {
  return Promise.race([promise, delay(ms).then(() => undefined)]);
}

/** Kills every process any rig of this run recorded, whole group and then the process itself. Call it from `afterEach`. */
export function stopRigs(): void {
  for (const made of rigs.splice(0)) {
    for (const pid of Object.values(made.pids()).filter(alive)) {
      for (const target of [-pid, pid]) {
        try {
          process.kill(target, 'SIGKILL');
        } catch {
          // gone already
        }
      }
    }
    fs.rmSync(made.dir, { recursive: true, force: true });
  }
}
