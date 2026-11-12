// `notify run` for a LaunchAgent that was installed before the wrapper existed and still starts `node main.js run`: the service is the Rust binary's, so node starts it as a child with the same stdio and passes the stop signals on, or says there is no binary and exits 69, the code a missing binary gets everywhere else.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import { createT } from '@tagents/core';

export const NO_BINARY = 69;

/** Set in the child's environment by node: a binary from before the hand-over was removed answers a failing start by running `node main.js run`, which would start the binary again. Seen set, node says there is no usable binary and stops. */
export const FROM_NODE = 'TAGENTS_NOTIFY_FROM_NODE';

export interface RunBinaryDeps {
  readonly bin: string;
  readonly args?: readonly string[];
  readonly env?: NodeJS.ProcessEnv;
  readonly err?: (text: string) => void;
}

/** The exit code to return: the child's, or 1 when a signal ended it without its own word, which launchd retries. */
export function runBinary(d: RunBinaryDeps): Promise<number> {
  const err = d.err ?? ((text: string): void => void process.stderr.write(text));
  const env = d.env ?? process.env;
  const noBinary = (): Promise<number> => {
    err(`${createT(env['TAGENTS_LOCALE'])('needsBinary', { verb: 'notify run' })}\n`);
    return Promise.resolve(NO_BINARY);
  };
  if (env[FROM_NODE] === '1') return noBinary();
  try {
    fs.accessSync(d.bin, fs.constants.X_OK);
  } catch {
    return noBinary();
  }
  return new Promise((resolve) => {
    const child = spawn(d.bin, ['notify', 'run', ...(d.args ?? [])], { stdio: 'inherit', env: { ...env, [FROM_NODE]: '1' } });
    const forward = (signal: NodeJS.Signals) => (): void => void child.kill(signal);
    const onTerm = forward('SIGTERM');
    const onInt = forward('SIGINT');
    process.on('SIGTERM', onTerm);
    process.on('SIGINT', onInt);
    const done = (code: number): void => {
      process.off('SIGTERM', onTerm);
      process.off('SIGINT', onInt);
      resolve(code);
    };
    child.on('error', (e) => {
      err(`could not start ${d.bin}: ${e.message}\n`);
      done(1);
    });
    child.on('close', (code) => done(code ?? 1));
  });
}
