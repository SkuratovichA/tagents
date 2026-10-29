// A call: the program of the verb, run as a child with no stdin, and what it did told back in one JSON document. Nothing here knows a verb; the program, the words and the exit table all come from the tool.
//
// Nothing a call starts outlives the call. The child leads a process group of its own, a call ends by exit, timeout, cancellation of its request or closing of the server, and each time the whole group is stopped: SIGTERM, then SIGKILL once the grace is over, and whatever is left in the group after the program itself exited is killed at once.
import { spawn, type ChildProcess } from 'node:child_process';
import type { Readable } from 'node:stream';
import { argvFor, type ToolSpec } from './tools.ts';

export interface RunDeps {
  /** the environment the program is looked up and run in: the server's own */
  readonly env: NodeJS.ProcessEnv;
  readonly timeoutMs: number;
  /** how long a stopped group has to leave on SIGTERM before it is killed */
  readonly killGraceMs?: number;
  /** how long the call waits for the output pipes after the program exited: a process that left the group can hold them open for good */
  readonly drainMs?: number;
}

export interface CallResult {
  readonly isError: boolean;
  readonly content: readonly [{ readonly type: 'text'; readonly text: string }];
}

/** More than this many bytes of one stream is cut: a transcript or an index can be larger than any client will take. */
export const MAX_STREAM = 256 * 1024;
const KILL_GRACE_MS = 2000;
const DRAIN_MS = 250;
const REFUSED = 3;
const USAGE = 2;

const outcomeOf = (exit: Readonly<Record<string, number>>, code: number): string =>
  Object.entries(exit).find(([, value]) => value === code)?.[0] ?? `exit ${code}`;

/** Stdout that is a JSON document is handed over parsed, so the model reads fields and not an escaped string; anything else stays text. */
function parsedOrText(stdout: string): unknown {
  const trimmed = stdout.trimStart();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return stdout;
  try {
    return JSON.parse(stdout);
  } catch {
    return stdout;
  }
}

/** The first bytes of a stream up to the cap. The rest is read and thrown away, so the program never blocks on a full pipe. */
class Capture {
  private readonly chunks: Buffer[] = [];
  private size = 0;
  cut = false;

  push(chunk: Buffer): void {
    const room = MAX_STREAM - this.size;
    if (chunk.length <= room) {
      this.chunks.push(chunk);
      this.size += chunk.length;
      return;
    }
    if (room > 0) this.chunks.push(chunk.subarray(0, room));
    this.size = MAX_STREAM;
    this.cut = true;
  }

  /** The text read so far; once cut, it ends before the character the cap fell in, and a marker says so. */
  text(): string {
    const bytes = Buffer.concat(this.chunks);
    if (!this.cut) return bytes.toString('utf8');
    return `${bytes.subarray(0, completeEnd(bytes)).toString('utf8')}\n[output cut at ${MAX_STREAM} bytes]`;
  }
}

/** The end of the last whole UTF-8 character of `bytes`: a sequence the cap cut in the middle is left out whole. */
function completeEnd(bytes: Buffer): number {
  let lead = bytes.length - 1;
  while (lead > 0 && bytes.length - lead < 4 && ((bytes[lead] ?? 0) & 0xc0) === 0x80) lead -= 1;
  const first = bytes[lead] ?? 0;
  const length = first >= 0xf0 ? 4 : first >= 0xe0 ? 3 : first >= 0xc0 ? 2 : 1;
  return lead + length > bytes.length ? lead : bytes.length;
}

/** `stdoutCut` keeps the text as text; `truncated` is set when either stream was cut. */
function finish(code: number, outcome: string, stdout: string, stderr: string, stdoutCut = false, stderrCut = false): CallResult {
  const body = {
    exit: code,
    outcome,
    stdout: stdoutCut ? stdout : parsedOrText(stdout),
    stderr,
    ...(stdoutCut || stderrCut ? { truncated: true } : {}),
  };
  return { isError: code !== 0, content: [{ type: 'text', text: JSON.stringify(body, null, 2) }] };
}

export const resultText = (result: CallResult): string => result.content[0].text;

const refusal = (code: number, outcome: string, message: string): CallResult => finish(code, outcome, '', `${message}\n`);

/** The calls in flight, so the server can stop them all when it closes. */
export class Calls {
  private readonly stops = new Set<() => Promise<void>>();

  /** Registers the way to stop one call; the returned function takes it out again. */
  track(stop: () => Promise<void>): () => void {
    this.stops.add(stop);
    return () => void this.stops.delete(stop);
  }

  /** Stops every call in flight and settles once each has ended and its group is gone. */
  async stopAll(): Promise<void> {
    await Promise.all([...this.stops].map((stop) => stop()));
  }
}

export interface CallOptions {
  /** the request's own signal: aborted when the client cancels it or the connection closes */
  readonly signal?: AbortSignal;
  readonly calls?: Calls;
}

export async function callTool(tool: ToolSpec, args: Readonly<Record<string, unknown>>, deps: RunDeps, options: CallOptions = {}): Promise<CallResult> {
  const argv = argvFor(tool, args);
  if (!argv.ok) return refusal(tool.exit['usage'] ?? USAGE, 'usage', argv.message);
  if (tool.command.requires === 'tmux' && (deps.env['TMUX'] ?? '') === '') {
    const message = `${tool.name} needs a tmux server of its own to open a window in, and Claude Code is not running inside tmux (TMUX is not set)`;
    return refusal(tool.exit['refused'] ?? REFUSED, 'refused', message);
  }
  if (options.signal?.aborted === true) return refusal(tool.exit['error'] ?? 1, 'cancelled', `${tool.program} was not started: the request was cancelled`);
  return run(tool, argv.argv, deps, options);
}

const streamClosed = (stream: Readable): Promise<void> => new Promise((resolve) => stream.once('close', () => resolve()));

type Reason = 'timeout' | 'cancelled';

function run(tool: ToolSpec, argv: readonly string[], deps: RunDeps, options: CallOptions): Promise<CallResult> {
  const grace = deps.killGraceMs ?? KILL_GRACE_MS;
  const drain = deps.drainMs ?? DRAIN_MS;
  const stdout = new Capture();
  const stderr = new Capture();

  const result = new Promise<CallResult>((resolve) => {
    let child: ChildProcess;
    try {
      child = spawn(tool.program, [...argv], { env: deps.env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    } catch (error) {
      resolve(refusal(tool.exit['error'] ?? 1, 'error', error instanceof Error ? error.message : String(error)));
      return;
    }
    const { pid } = child;
    const { stdout: out, stderr: err } = child;
    if (out === null || err === null) {
      resolve(refusal(tool.exit['error'] ?? 1, 'error', `${tool.program} was started without output pipes`));
      return;
    }
    const closed = Promise.all([streamClosed(out), streamClosed(err)]);
    out.on('data', (chunk: Buffer) => stdout.push(chunk));
    err.on('data', (chunk: Buffer) => stderr.push(chunk));

    const timers: NodeJS.Timeout[] = [];
    let graceTimer: NodeJS.Timeout | undefined;
    let reason: Reason | undefined;
    let exited = false;
    let settled = false;

    const signalGroup = (signal: NodeJS.Signals): void => {
      if (pid === undefined) return;
      try {
        process.kill(-pid, signal);
      } catch {
        // the group is gone already
      }
    };

    const settle = (value: CallResult): void => {
      if (settled) return;
      settled = true;
      for (const timer of timers) clearTimeout(timer);
      options.signal?.removeEventListener('abort', onAbort);
      untrack?.();
      resolve(value);
    };

    const outcome = (code: number | null): CallResult => {
      const done = (exit: number, name: string, note = ''): CallResult => finish(exit, name, stdout.text(), `${stderr.text()}${note}`, stdout.cut, stderr.cut);
      if (reason === 'timeout') return done(tool.exit['timeout'] ?? 4, 'timeout', `${tool.program} did not finish within ${deps.timeoutMs} ms and was stopped\n`);
      if (reason === 'cancelled') return done(tool.exit['error'] ?? 1, 'cancelled', `${tool.program} was stopped: the request was cancelled or the server closed\n`);
      const exit = code ?? tool.exit['error'] ?? 1;
      return done(exit, outcomeOf(tool.exit, exit));
    };

    const stop = (why: Reason): Promise<void> => {
      if (!exited && reason === undefined) {
        reason = why;
        signalGroup('SIGTERM');
        graceTimer = setTimeout(() => signalGroup('SIGKILL'), grace);
        timers.push(graceTimer);
      }
      return result.then(() => undefined);
    };
    const onAbort = (): void => void stop('cancelled');
    const untrack = options.calls?.track(() => stop('cancelled'));

    child.once('error', (error: NodeJS.ErrnoException) => {
      signalGroup('SIGKILL');
      const why = error.code === 'ENOENT' ? `${tool.program} is not on PATH` : error.message;
      settle(refusal(tool.exit['error'] ?? 1, 'error', why));
    });
    child.once('exit', (code) => {
      exited = true;
      clearTimeout(graceTimer);
      // What the program left running in its group dies with it. The pipes are given a moment to drain, and no longer: a process outside the group can hold them open for good.
      signalGroup('SIGKILL');
      const ended = (): void => {
        out.destroy();
        err.destroy();
        settle(outcome(code));
      };
      timers.push(setTimeout(ended, drain));
      void closed.then(ended);
    });
    timers.push(setTimeout(() => void stop('timeout'), deps.timeoutMs));
    options.signal?.addEventListener('abort', onAbort, { once: true });
  });
  return result;
}
