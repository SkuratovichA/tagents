// `notify run` for a LaunchAgent that was installed before the wrapper existed and still starts `node main.js run`: the service is the Rust binary's, so node starts it as a child with the same stdio and passes the stop signals on, or says there is no binary and exits 69, the code a missing binary gets everywhere else.
import { spawn } from 'node:child_process';
import fs from 'node:fs';

export const NO_BINARY = 69;

export interface RunBinaryDeps {
  readonly bin: string;
  readonly args?: readonly string[];
  readonly env?: NodeJS.ProcessEnv;
  readonly err?: (text: string) => void;
}

/** The exit code to return: the child's, or 1 when a signal ended it without its own word, which launchd retries. */
export function runBinary(d: RunBinaryDeps): Promise<number> {
  const err = d.err ?? ((text: string): void => void process.stderr.write(text));
  try {
    fs.accessSync(d.bin, fs.constants.X_OK);
  } catch {
    err('notify run is served by the tagents-core binary, and this machine has none: run `tagents update`, or `cargo build --release -p tagents-core` in the checkout\n');
    return Promise.resolve(NO_BINARY);
  }
  return new Promise((resolve) => {
    const child = spawn(d.bin, ['notify', 'run', ...(d.args ?? [])], { stdio: 'inherit', env: d.env ?? process.env });
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
