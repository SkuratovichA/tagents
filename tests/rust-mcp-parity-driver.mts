// The client side of tests/rust-mcp-parity.sh: runs one MCP server command against a script of requests and prints what it said.
//
//   node tests/rust-mcp-parity-driver.mts run <script.json> <pids dir> -- <server command> [args...]
//   node tests/rust-mcp-parity-driver.mts versions <repo root>
//
// `run` starts the server with the environment it was itself started with, so the shell decides what the server sees, and works through the script, a JSON array of steps:
//
//   {"send": <message>}          write one JSON-RPC message as a line
//   {"raw": "<text>"}            write the text as it is, newline included when it has one
//   {"answered": [<id>, ...]}    wait until each of these requests has an answer, for ten seconds at most
//   {"file": "<path>"}           wait until the file exists, for ten seconds at most
//   {"gone": "<pid file>"}       wait until the process whose pid the file holds is gone, for ten seconds at most
//   {"quiet": <ms>}              let that long pass, for the answers that must not come
//   {"close": true}              close the server's stdin
//   {"touch": "<path>"}          create the file, for a program that waits for it
//   {"signal": "SIGTERM"}        send the server that signal
//
// Then it closes stdin (if the script has not), waits for the server to leave for fifteen seconds at most (SIGKILL after), and prints the transcript keyed by request id, one line each, so two servers can be compared with `cmp`:
//
//   answer <id><TAB><the line as the server wrote it>    or    no-answer <id>
//   other<TAB><a line that answers no request of the script>
//   unterminated<TAB><what the server wrote after its last newline>
//   order <ids in the order the answers came>
//   timeout <the step that did not complete>
//   exit <code | signal | killed>
//   stderr <bytes>
//   pids <gone | alive: names>      of the *.pid files in the pids dir, a minute after the server left at the latest
//
// `versions` prints the protocol versions the SDK of packages/mcp supports, one per line: the Rust list is pinned to them by the suite.
//
// Needs node 22.18 or newer (it runs TypeScript as it is). No dependency of the repo is imported.
import { type ChildProcessWithoutNullStreams, spawn } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';

type Id = number | string;

type Step =
  | { readonly kind: 'send'; readonly message: unknown }
  | { readonly kind: 'raw'; readonly text: string }
  | { readonly kind: 'answered'; readonly ids: readonly Id[] }
  | { readonly kind: 'file'; readonly path: string }
  | { readonly kind: 'gone'; readonly path: string }
  | { readonly kind: 'quiet'; readonly ms: number }
  | { readonly kind: 'touch'; readonly path: string }
  | { readonly kind: 'signal'; readonly name: NodeJS.Signals }
  | { readonly kind: 'close' };

const WAIT_MS = 10_000;
const EXIT_MS = 15_000;
const PIDS_MS = 5_000;

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
const isId = (value: unknown): value is Id => typeof value === 'number' || typeof value === 'string';
const isSignal = (value: unknown): value is NodeJS.Signals => value === 'SIGTERM' || value === 'SIGINT' || value === 'SIGHUP';
const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** A bounded poll: true as soon as the condition holds, false when `ms` have passed. */
async function until(condition: () => boolean, ms: number): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await sleep(10);
  }
  return condition();
}

/** Whether the promise settles within `ms`; the timer is cleared, so it does not keep the process alive after the answer. */
async function within(done: Promise<void>, ms: number): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => resolve(false), ms);
  });
  try {
    return await Promise.race([done.then(() => true), late]);
  } finally {
    clearTimeout(timer);
  }
}

function step(value: unknown): Step {
  if (!isRecord(value)) throw new Error(`a step is an object: ${JSON.stringify(value)}`);
  if ('send' in value) return { kind: 'send', message: value['send'] };
  if (typeof value['raw'] === 'string') return { kind: 'raw', text: value['raw'] };
  if (typeof value['file'] === 'string') return { kind: 'file', path: value['file'] };
  if (typeof value['gone'] === 'string') return { kind: 'gone', path: value['gone'] };
  if (typeof value['quiet'] === 'number') return { kind: 'quiet', ms: value['quiet'] };
  if (typeof value['touch'] === 'string') return { kind: 'touch', path: value['touch'] };
  if (isSignal(value['signal'])) return { kind: 'signal', name: value['signal'] };
  if (value['close'] === true) return { kind: 'close' };
  const ids: unknown = value['answered'];
  if (Array.isArray(ids)) {
    const found: unknown[] = ids;
    if (found.every(isId)) return { kind: 'answered', ids: found };
  }
  throw new Error(`not a step: ${JSON.stringify(value)}`);
}

function readScript(file: string): readonly Step[] {
  const parsed: unknown = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(parsed)) throw new Error('the script is an array of steps');
  const steps: unknown[] = parsed;
  return steps.map(step);
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function pidOf(file: string): number | undefined {
  try {
    const pid = Number.parseInt(fs.readFileSync(file, 'utf8'), 10);
    return Number.isInteger(pid) ? pid : undefined;
  } catch {
    return undefined;
  }
}

/** The pid files of the dir, by name without the extension, whose process is still there. */
function livePids(dir: string): readonly string[] {
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith('.pid'))
    .filter((name) => {
      const pid = pidOf(path.join(dir, name));
      return pid !== undefined && alive(pid);
    })
    .map((name) => name.slice(0, -'.pid'.length))
    .sort();
}

/** What the server wrote to stdout, split into lines the way a client reads them: on the newline only. */
class Lines {
  readonly all: string[] = [];
  private readonly decoder = new StringDecoder('utf8');
  pending = '';

  push(chunk: Buffer): void {
    this.pending += this.decoder.write(chunk);
    for (let at = this.pending.indexOf('\n'); at >= 0; at = this.pending.indexOf('\n')) {
      this.all.push(this.pending.slice(0, at));
      this.pending = this.pending.slice(at + 1);
    }
  }
}

const idOf = (message: unknown): Id | undefined => (isRecord(message) && isId(message['id']) ? message['id'] : undefined);

function lineIdOf(line: string): Id | undefined {
  try {
    return idOf(JSON.parse(line));
  } catch {
    return undefined;
  }
}

async function run(scriptFile: string, pidsDir: string, command: readonly string[]): Promise<void> {
  const [program, ...args] = command;
  if (program === undefined) throw new Error('no server command');
  const steps = readScript(scriptFile);
  const server: ChildProcessWithoutNullStreams = spawn(program, args, { stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
  const lines = new Lines();
  let stderrBytes = 0;
  let status = 'killed';
  server.stdout.on('data', (chunk: Buffer) => lines.push(chunk));
  server.stderr.on('data', (chunk: Buffer) => void (stderrBytes += chunk.length));
  server.stdin.on('error', () => undefined);
  const closed = new Promise<void>((resolve) => server.on('close', (code, signal) => void ((status = code !== null ? String(code) : (signal ?? 'killed')), resolve())));
  let stdinOpen = true;
  const close = (): void => {
    if (stdinOpen) server.stdin.end();
    stdinOpen = false;
  };

  const requested: Id[] = [];
  const timeouts: string[] = [];
  const answerOf = (id: Id): string | undefined => lines.all.find((line) => lineIdOf(line) === id);
  for (const next of steps) {
    switch (next.kind) {
      case 'send': {
        const id = idOf(next.message);
        if (id !== undefined && isRecord(next.message) && 'method' in next.message) requested.push(id);
        server.stdin.write(`${JSON.stringify(next.message)}\n`);
        break;
      }
      case 'raw':
        server.stdin.write(next.text);
        break;
      case 'answered':
        if (!(await until(() => next.ids.every((id) => answerOf(id) !== undefined), WAIT_MS))) timeouts.push(`answered ${JSON.stringify(next.ids)}`);
        break;
      case 'file':
        if (!(await until(() => fs.existsSync(next.path), WAIT_MS))) timeouts.push(`file ${path.basename(next.path)}`);
        break;
      case 'gone':
        if (
          !(await until(() => {
            const pid = pidOf(next.path);
            return pid !== undefined && !alive(pid);
          }, WAIT_MS))
        )
          timeouts.push(`gone ${path.basename(next.path)}`);
        break;
      case 'quiet':
        await sleep(next.ms);
        break;
      case 'touch':
        fs.writeFileSync(next.path, '');
        break;
      case 'signal':
        server.kill(next.name);
        break;
      case 'close':
        close();
        break;
    }
  }
  close();
  if (!(await within(closed, EXIT_MS))) {
    server.kill('SIGKILL');
    await closed;
  }
  await until(() => livePids(pidsDir).length === 0, PIDS_MS);

  const out: string[] = [];
  for (const id of requested) {
    const line = answerOf(id);
    if (line === undefined) {
      out.push(`no-answer ${JSON.stringify(id)}`);
    } else {
      out.push(`answer ${JSON.stringify(id)}\t${line}`);
    }
  }
  for (const line of lines.all) {
    const id = lineIdOf(line);
    if (id === undefined || !requested.includes(id)) out.push(`other\t${line}`);
  }
  const order = lines.all.map(lineIdOf).filter((id): id is Id => id !== undefined && requested.includes(id));
  if (lines.pending !== '') out.push(`unterminated\t${lines.pending}`);
  out.push(`order ${order.map((id) => JSON.stringify(id)).join(' ')}`);
  for (const timeout of timeouts) out.push(`timeout ${timeout}`);
  out.push(`exit ${status}`, `stderr ${stderrBytes}`);
  const still = livePids(pidsDir);
  out.push(still.length === 0 ? 'pids gone' : `pids alive: ${still.join(' ')}`);
  process.stdout.write(`${out.join('\n')}\n`);
}

function versions(repo: string): void {
  const sdk = createRequire(path.join(repo, 'packages', 'mcp', 'package.json'))('@modelcontextprotocol/sdk/types.js') as unknown;
  const listed = isRecord(sdk) ? sdk['SUPPORTED_PROTOCOL_VERSIONS'] : undefined;
  if (!Array.isArray(listed)) throw new Error('the SDK does not export SUPPORTED_PROTOCOL_VERSIONS');
  const found: unknown[] = listed;
  if (!found.every((version): version is string => typeof version === 'string')) throw new Error('SUPPORTED_PROTOCOL_VERSIONS is not a list of strings');
  process.stdout.write(`${found.join('\n')}\n`);
}

const [verb, ...rest] = process.argv.slice(2);
if (verb === 'versions' && rest[0] !== undefined) {
  versions(rest[0]);
} else if (verb === 'run' && rest[0] !== undefined && rest[1] !== undefined && rest[2] === '--') {
  await run(rest[0], rest[1], rest.slice(3));
} else {
  process.stderr.write('usage: rust-mcp-parity-driver.mts run <script.json> <pids dir> -- <server command...> | versions <repo root>\n');
  process.exitCode = 2;
}
