// One child process, awaited: stdin in, stdout and stderr out, a deadline, a kill.
//
// Nothing in the repo's other packages offers this (their `child_process` uses
// are one-off sync calls and a long-running driver), and two places here need
// it: the tmux probe, and the macOS helper that is given a notice on stdin.
// Both run inside a service that must never hang on a child that stopped
// answering, so the kill is part of the contract and not left to the caller.
import { execFile } from 'node:child_process';

export interface ExecResult {
  /** The exit code; null when the process was killed. */
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
}

export type Exec = (
  file: string,
  args: readonly string[],
  o: { readonly input?: string; readonly timeoutMs: number; readonly env?: NodeJS.ProcessEnv }
) => Promise<ExecResult>;

/**
 * Runs `file`. A non-zero exit is a result, in `code`; the promise rejects only
 * when the program cannot be started at all (no such file, not executable).
 * SIGKILL and not the default SIGTERM at the deadline: a helper that is stuck
 * is not going to handle a polite signal either.
 */
export const execText: Exec = (file, args, o) =>
  new Promise<ExecResult>((resolve, reject) => {
    const child = execFile(
      file,
      [...args],
      { timeout: o.timeoutMs, killSignal: 'SIGKILL', encoding: 'utf8', ...(o.env !== undefined ? { env: o.env } : {}) },
      (err, stdout, stderr) => {
        if (err === null) {
          resolve({ code: 0, stdout, stderr, timedOut: false });
          return;
        }
        // No pid: the process never existed.
        if (child.pid === undefined) {
          reject(err);
          return;
        }
        resolve({
          code: typeof err.code === 'number' ? err.code : null,
          stdout,
          stderr,
          timedOut: err.killed === true && err.signal === 'SIGKILL',
        });
      }
    );
    // A program that exits without reading its input closes the pipe under us:
    // EPIPE, which is its exit code's business and not an error of ours.
    child.stdin?.on('error', () => {});
    child.stdin?.end(o.input);
  });
