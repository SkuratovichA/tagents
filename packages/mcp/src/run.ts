// A call: the program of the verb, run as a child with no stdin, and what it did told back in one JSON document. Nothing here knows a verb; the program, the words and the exit table all come from the tool.
import { spawn } from 'node:child_process';
import { argvFor, type ToolSpec } from './tools.ts';

export interface RunDeps {
  /** the environment the program is looked up and run in: the server's own */
  readonly env: NodeJS.ProcessEnv;
  readonly timeoutMs: number;
}

export interface CallResult {
  readonly isError: boolean;
  readonly content: readonly [{ readonly type: 'text'; readonly text: string }];
}

/** More than this much of one stream is cut: a transcript or an index can be larger than any client will take. */
const MAX_STREAM = 256 * 1024;
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

function finish(code: number, outcome: string, stdout: string, stderr: string): CallResult {
  const truncated = stdout.length > MAX_STREAM || stderr.length > MAX_STREAM;
  const body = {
    exit: code,
    outcome,
    stdout: parsedOrText(stdout.slice(0, MAX_STREAM)),
    stderr: stderr.slice(0, MAX_STREAM),
    ...(truncated ? { truncated: true } : {}),
  };
  return { isError: code !== 0, content: [{ type: 'text', text: JSON.stringify(body, null, 2) }] };
}

export const resultText = (result: CallResult): string => result.content[0].text;

const refusal = (code: number, outcome: string, message: string): CallResult => finish(code, outcome, '', `${message}\n`);

export async function callTool(tool: ToolSpec, args: Readonly<Record<string, unknown>>, deps: RunDeps): Promise<CallResult> {
  const argv = argvFor(tool, args);
  if (!argv.ok) return refusal(tool.exit['usage'] ?? USAGE, 'usage', argv.message);
  if (tool.command.requires === 'tmux' && (deps.env['TMUX'] ?? '') === '') {
    const message = `${tool.name} needs a tmux server of its own to open a window in, and Claude Code is not running inside tmux (TMUX is not set)`;
    return refusal(tool.exit['refused'] ?? REFUSED, 'refused', message);
  }
  return new Promise<CallResult>((resolve) => {
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const child = spawn(tool.program, [...argv.argv], { env: deps.env, stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
    }, deps.timeoutMs);
    child.stdout.setEncoding('utf8').on('data', (chunk: string) => {
      if (stdout.length <= MAX_STREAM) stdout += chunk;
    });
    child.stderr.setEncoding('utf8').on('data', (chunk: string) => {
      if (stderr.length <= MAX_STREAM) stderr += chunk;
    });
    child.on('error', (error: NodeJS.ErrnoException) => {
      clearTimeout(timer);
      const why = error.code === 'ENOENT' ? `${tool.program} is not on PATH` : error.message;
      resolve(refusal(tool.exit['error'] ?? 1, 'error', why));
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (timedOut) return resolve(finish(tool.exit['timeout'] ?? 4, 'timeout', stdout, `${stderr}${tool.program} did not finish within ${deps.timeoutMs} ms and was stopped\n`));
      const exit = code ?? tool.exit['error'] ?? 1;
      resolve(finish(exit, outcomeOf(tool.exit, exit), stdout, stderr));
    });
  });
}
