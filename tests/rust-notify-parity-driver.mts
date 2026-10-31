// The daemon side of tests/rust-notify-parity.sh: starts one notify daemon on the scratch state the shell made, works through a script of steps and prints what the daemon and everything around it left.
//
//   node tests/rust-notify-parity-driver.mts run <script.json> <root> -- <daemon command...> [--other <command of the other kind...>]
//   node tests/rust-notify-parity-driver.mts probe <root> -- <daemon command...>
//
// `run` starts nothing itself but what the script says, with the environment it was started with, so the shell decides what the daemon sees. The script is a JSON array of steps, each an object with a `do`; paths are relative to <root> unless they are absolute, and the state directory is $TA_STATE_DIR:
//
//   put      {to, from | text}      write the file (atomically: a temporary name and a rename, so a watcher never reads half of it); `from` is a file of the shell's, `text` is written as it is with @hostname@ and @shorthost@ replaced
//   mkdir    {path}                 mkdir -p
//   rename   {from, to}             rename, which replaces `to`
//   remove   {path}                 rm -rf
//   truncate {path}                 cut the file to nothing, in place
//   symlink  {target, link}         make `link` point at `target` (written as given), replacing what is there with a rename
//   lock     {as}                   write notify.lock in the state directory: dead, reused, bare-dead, bare-old, bare-live, junk or empty
//   row      {key, state, at, ...}  write a state row <key>.tsv; `at` is seconds from the start of the run (negative: ago)
//   ev       {f}                    append one event to events.tsv with one write; `f` holds ev, key and any of at, sid, agent, pane, cwd, transcript, config, tool, sub, text, label
//   raw      {text}                 append the text to events.tsv as it is, with one write (@now@ is the seconds of the start of the run)
//   burst    {count, f, one, pad}   append `count` events, {n} in a field being the number of the event: one write each, or all in one write when `one`; `pad` bytes of padding after the text
//   start    {wait}                 start the daemon and wait for its `started` line (wait: started), for it to leave (wait: exit) or for either (wait: settled)
//   second   {}                     start a daemon of the other kind and wait for it to leave
//   expect   {text, n, ms}          wait until n lines (one by default) of the daemon's stderr hold the text
//   exited   {}                     wait until the daemon has left
//   file     {path}                 wait until the file exists
//   gone     {path}                 wait until the file does not exist
//   signal   {name}                 send the daemon that signal
//   quiet    {ms}                   let that long pass, for what must not happen without anything to wait for
//
// Every wait is bounded, and one that runs out is recorded as a `timeout` line and the run goes on. Then the daemon is stopped with SIGTERM if it is still there, and the transcript is printed, so two daemons can be compared with `cmp` once the shell has replaced the timestamps and the pids:
//
//   stderr<TAB><a line of the daemon's stderr>      stdout<TAB><a line of its stdout>
//   exit <code | signal>
//   second-stderr, second-stdout, second-exit       the same for the daemon of the other kind
//   helper <n> args <JSON>, helper <n> stdin <bytes><TAB><text>      what the stub helper recorded, in order
//   tmux <n> <the argument line of the call of the tmux shim>
//   state <the names in the state directory>, size <events file> <bytes>, lock <content as JSON | absent>
//   timeout <the step that did not complete>
//
// `probe` starts the command as the first check of the shell needs it: it waits for the `started` line and says what the process is.
//
// Needs node 22.18 or newer (it runs TypeScript as it is). No dependency of the repo is imported.
import { type ChildProcessByStdio, spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Readable } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';

type Fields = Readonly<Record<string, string>>;
type LockKind = 'dead' | 'reused' | 'bare-dead' | 'bare-old' | 'bare-live' | 'junk' | 'empty';
type Signal = 'SIGTERM' | 'SIGINT' | 'SIGHUP';

type Step =
  | { readonly kind: 'put'; readonly to: string; readonly from?: string; readonly text?: string }
  | { readonly kind: 'mkdir'; readonly path: string }
  | { readonly kind: 'rename'; readonly from: string; readonly to: string }
  | { readonly kind: 'remove'; readonly path: string }
  | { readonly kind: 'truncate'; readonly path: string }
  | { readonly kind: 'symlink'; readonly target: string; readonly link: string }
  | { readonly kind: 'lock'; readonly as: LockKind }
  | { readonly kind: 'row'; readonly key: string; readonly fields: Fields }
  | { readonly kind: 'ev'; readonly fields: Fields }
  | { readonly kind: 'raw'; readonly text: string }
  | { readonly kind: 'burst'; readonly count: number; readonly fields: Fields; readonly one: boolean; readonly pad: number }
  | { readonly kind: 'start'; readonly wait: 'started' | 'settled' | 'exit' }
  | { readonly kind: 'second' }
  | { readonly kind: 'expect'; readonly text: string; readonly n: number; readonly ms: number }
  | { readonly kind: 'exited' }
  | { readonly kind: 'file'; readonly path: string }
  | { readonly kind: 'gone'; readonly path: string }
  | { readonly kind: 'signal'; readonly name: Signal }
  | { readonly kind: 'quiet'; readonly ms: number };

const WAIT_MS = 10_000;
const EXIT_MS = 15_000;
const LOCK_KINDS: readonly string[] = ['dead', 'reused', 'bare-dead', 'bare-old', 'bare-live', 'junk', 'empty'];
const EVENTS_FILE = 'events.tsv';
const OLD = new Date('2001-01-01T00:00:00Z');
const STARTED_LINE = /^\S+ started pid (\d+) backend /;

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
const isSignal = (value: unknown): value is Signal => value === 'SIGTERM' || value === 'SIGINT' || value === 'SIGHUP';
const isLockKind = (value: unknown): value is LockKind => typeof value === 'string' && LOCK_KINDS.includes(value);
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

function text(value: Record<string, unknown>, key: string): string {
  const found = value[key];
  if (typeof found !== 'string') throw new Error(`step ${JSON.stringify(value)} needs a string ${key}`);
  return found;
}

function whole(value: Record<string, unknown>, key: string, otherwise: number): number {
  const found = value[key];
  if (found === undefined) return otherwise;
  if (typeof found !== 'number' || !Number.isInteger(found) || found < 0) throw new Error(`step ${JSON.stringify(value)} needs ${key} to be a whole number`);
  return found;
}

function fieldsOf(value: Record<string, unknown>, key: string): Fields {
  const found = value[key];
  if (!isRecord(found)) throw new Error(`step ${JSON.stringify(value)} needs an object ${key}`);
  const out: Record<string, string> = {};
  for (const [name, one] of Object.entries(found)) {
    if (typeof one !== 'string') throw new Error(`step ${JSON.stringify(value)}: field ${name} is a string`);
    out[name] = one;
  }
  return out;
}

function step(value: unknown): Step {
  if (!isRecord(value)) throw new Error(`a step is an object: ${JSON.stringify(value)}`);
  switch (value['do']) {
    case 'put': {
      const to = text(value, 'to');
      return typeof value['from'] === 'string' ? { kind: 'put', to, from: value['from'] } : { kind: 'put', to, text: text(value, 'text') };
    }
    case 'mkdir':
      return { kind: 'mkdir', path: text(value, 'path') };
    case 'rename':
      return { kind: 'rename', from: text(value, 'from'), to: text(value, 'to') };
    case 'remove':
      return { kind: 'remove', path: text(value, 'path') };
    case 'truncate':
      return { kind: 'truncate', path: text(value, 'path') };
    case 'symlink':
      return { kind: 'symlink', target: text(value, 'target'), link: text(value, 'link') };
    case 'lock': {
      const as = value['as'];
      if (!isLockKind(as)) throw new Error(`not a kind of lock: ${JSON.stringify(as)}`);
      return { kind: 'lock', as };
    }
    case 'row':
      return { kind: 'row', key: text(value, 'key'), fields: fieldsOf(value, 'f') };
    case 'ev':
      return { kind: 'ev', fields: fieldsOf(value, 'f') };
    case 'raw':
      return { kind: 'raw', text: text(value, 'text') };
    case 'burst':
      return { kind: 'burst', count: whole(value, 'count', 0), fields: fieldsOf(value, 'f'), one: value['one'] === true, pad: whole(value, 'pad', 0) };
    case 'start':
      return { kind: 'start', wait: value['wait'] === 'exit' || value['wait'] === 'settled' ? value['wait'] : 'started' };
    case 'second':
      return { kind: 'second' };
    case 'expect':
      return { kind: 'expect', text: text(value, 'text'), n: whole(value, 'n', 1), ms: whole(value, 'ms', WAIT_MS) };
    case 'exited':
      return { kind: 'exited' };
    case 'file':
      return { kind: 'file', path: text(value, 'path') };
    case 'gone':
      return { kind: 'gone', path: text(value, 'path') };
    case 'signal': {
      const name = value['name'];
      if (!isSignal(name)) throw new Error(`not a signal: ${JSON.stringify(name)}`);
      return { kind: 'signal', name };
    }
    case 'quiet':
      return { kind: 'quiet', ms: whole(value, 'ms', 0) };
    default:
      throw new Error(`not a step: ${JSON.stringify(value)}`);
  }
}

function readScript(file: string): readonly Step[] {
  const parsed: unknown = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(parsed)) throw new Error('the script is an array of steps');
  const steps: unknown[] = parsed;
  return steps.map(step);
}

/** What a process wrote to one of its pipes, split into lines on the newline only. */
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

  count(needle: string): number {
    return this.all.filter((line) => line.includes(needle)).length;
  }
}

interface Proc {
  readonly child: ChildProcessByStdio<null, Readable, Readable>;
  readonly err: Lines;
  readonly out: Lines;
  readonly closed: Promise<void>;
  status: string | undefined;
}

/** The daemon, with the environment the driver has, in the root of the scratch, and its pid noted for the shell's cleanup. */
function launch(command: readonly string[], root: string): Proc {
  const [program, ...args] = command;
  if (program === undefined) throw new Error('no daemon command');
  const child = spawn(program, args, { cwd: root, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
  const err = new Lines();
  const out = new Lines();
  const proc: Proc = {
    child,
    err,
    out,
    status: undefined,
    closed: new Promise<void>((resolve) => {
      child.on('close', (code, signal) => {
        proc.status = code !== null ? String(code) : (signal ?? 'killed');
        resolve();
      });
    }),
  };
  child.stdout.on('data', (chunk: Buffer) => out.push(chunk));
  child.stderr.on('data', (chunk: Buffer) => err.push(chunk));
  if (child.pid !== undefined) fs.appendFileSync(path.join(root, 'daemon.pids'), `${child.pid}\n`);
  return proc;
}

const hasStarted = (proc: Proc): boolean => proc.err.all.some((line) => STARTED_LINE.test(line));

/** Wait for the daemon to leave; a daemon that does not within EXIT_MS is killed. False when it had to be. */
async function leave(proc: Proc): Promise<boolean> {
  if (await within(proc.closed, EXIT_MS)) return true;
  proc.child.kill('SIGKILL');
  await within(proc.closed, EXIT_MS);
  return false;
}

function stateDir(): string {
  const dir = process.env['TA_STATE_DIR'];
  if (dir === undefined || dir === '') throw new Error('TA_STATE_DIR is not set');
  return dir;
}

function write(file: string, content: string | Buffer): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(temporary, content);
  fs.renameSync(temporary, file);
}

function deadPid(): number {
  const done = spawnSync(process.execPath, ['-e', '']);
  if (done.pid === undefined) throw new Error('cannot start a process to let it die');
  return done.pid;
}

function lockContent(as: LockKind): string {
  switch (as) {
    case 'dead':
      return `${deadPid()} Thu Jan  1 00:00:00 1970\n`;
    case 'reused':
      return `${process.pid} Mon Jan  1 00:00:00 2001\n`;
    case 'bare-dead':
      return `${deadPid()}\n`;
    case 'bare-old':
    case 'bare-live':
      return `${process.pid}\n`;
    case 'junk':
      return 'not a pid\n';
    case 'empty':
      return '';
  }
}

const unescapeHost = (value: string): string => value.replaceAll('@hostname@', os.hostname()).replaceAll('@shorthost@', os.hostname().split('.')[0] ?? '');

/** One line of events.tsv, in the order of the hook's 13 fields. `at` is seconds from `base`. */
function eventLine(f: Fields, base: number, root: string): string {
  const key = f['key'] ?? '';
  const transcript = f['transcript'] ?? '';
  const columns = [
    String(base + Number(f['at'] ?? '0')),
    f['ev'] ?? '',
    key,
    f['sid'] ?? `sid-${key}`,
    f['agent'] ?? '',
    f['pane'] ?? (/^\d+$/.test(key) ? `%${key}` : ''),
    f['cwd'] ?? '/work/project',
    transcript === '' || path.isAbsolute(transcript) ? transcript : path.join(root, transcript),
    f['config'] ?? '',
    f['tool'] ?? '',
    f['sub'] ?? '',
    f['text'] ?? '',
    f['label'] ?? '',
  ];
  return `${columns.join('\t')}\n`;
}

const numbered = (f: Fields, n: number, pad: number): Fields => {
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(f)) out[name] = value.replaceAll('{n}', String(n));
  if (pad > 0) out['text'] = `${out['text'] ?? ''}${'p'.repeat(pad)}`;
  return out;
};

function sizeOf(file: string): number | undefined {
  try {
    return fs.statSync(file).size;
  } catch {
    return undefined;
  }
}

/** The lock file, said without a pid or a start time of a process: whose it is, or that it is what the script wrote. */
function describeLock(file: string, wrote: { readonly kind: LockKind; readonly content: string } | undefined, main: number | undefined, second: number | undefined): string {
  let found: string;
  try {
    found = fs.readFileSync(file, 'utf8');
  } catch {
    return 'absent';
  }
  if (wrote !== undefined && found === wrote.content) return `as the script wrote it (${wrote.kind})`;
  const pid = /^(\d+)(?: .+)?\n$/.exec(found)?.[1];
  const form = pid !== undefined && found.includes(' ') ? 'pid and start time' : 'bare pid';
  if (pid !== undefined && Number(pid) === main) return `held by the daemon (${form})`;
  if (pid !== undefined && Number(pid) === second) return `held by the second daemon (${form})`;
  return `other ${JSON.stringify(found)}`;
}

/** What the stub helper recorded: one directory per call, h.1, h.2, ... in the order the calls started. */
function helperCalls(rec: string): string[] {
  const out: string[] = [];
  for (let n = 1; fs.existsSync(path.join(rec, `h.${n}`)); n += 1) {
    const dir = path.join(rec, `h.${n}`);
    const args = fs.readFileSync(path.join(dir, 'args'), 'utf8').split('\n');
    args.pop();
    out.push(`helper ${n} args ${JSON.stringify(args)}`);
    const stdin = fs.existsSync(path.join(dir, 'stdin')) ? fs.readFileSync(path.join(dir, 'stdin')) : Buffer.alloc(0);
    out.push(`helper ${n} stdin ${stdin.length}\t${stdin.toString('utf8')}`);
  }
  return out;
}

function tmuxCalls(rec: string): string[] {
  let log: string;
  try {
    log = fs.readFileSync(path.join(rec, 'tmux.log'), 'utf8');
  } catch {
    return [];
  }
  const lines = log.split('\n');
  lines.pop();
  return lines.map((line, at) => `tmux ${at + 1} ${line}`);
}

const lined = (prefix: string, lines: Lines): string[] => [...lines.all.map((line) => `${prefix}\t${line}`), ...(lines.pending === '' ? [] : [`${prefix}-unterminated\t${lines.pending}`])];

async function run(scriptFile: string, root: string, daemon: readonly string[], other: readonly string[]): Promise<void> {
  const steps = readScript(scriptFile);
  const state = stateDir();
  const events = path.join(state, EVENTS_FILE);
  const rec = path.join(root, 'rec');
  const base = Math.floor(Date.now() / 1000);
  const abs = (file: string): string => (path.isAbsolute(file) ? file : path.join(root, file));
  const timeouts: string[] = [];
  let main: Proc | undefined;
  let second: Proc | undefined;
  let wrote: { readonly kind: LockKind; readonly content: string } | undefined;

  for (const next of steps) {
    switch (next.kind) {
      case 'put':
        write(abs(next.to), next.from !== undefined ? fs.readFileSync(next.from) : unescapeHost(next.text ?? ''));
        break;
      case 'mkdir':
        fs.mkdirSync(abs(next.path), { recursive: true });
        break;
      case 'rename':
        fs.renameSync(abs(next.from), abs(next.to));
        break;
      case 'remove':
        fs.rmSync(abs(next.path), { recursive: true, force: true });
        break;
      case 'truncate':
        fs.truncateSync(abs(next.path), 0);
        break;
      case 'symlink': {
        const link = abs(next.link);
        fs.mkdirSync(path.dirname(link), { recursive: true });
        const temporary = `${link}.${process.pid}.tmp`;
        fs.rmSync(temporary, { force: true });
        fs.symlinkSync(next.target, temporary);
        fs.renameSync(temporary, link);
        break;
      }
      case 'lock': {
        const file = path.join(state, 'notify.lock');
        fs.mkdirSync(state, { recursive: true });
        wrote = { kind: next.as, content: lockContent(next.as) };
        fs.writeFileSync(file, wrote.content);
        if (next.as === 'bare-old') fs.utimesSync(file, OLD, OLD);
        break;
      }
      case 'row': {
        const f = next.fields;
        const at = base + Number(f['at'] ?? '0');
        const line = [String(at), f['state'] ?? 'done', f['sid'] ?? `sid-${next.key}`, f['cwd'] ?? '/work/project', f['transcript'] ?? '', f['detail'] ?? '', f['config'] ?? ''].join('\t');
        write(path.join(state, `${next.key}.tsv`), `${line}\n`);
        break;
      }
      case 'ev':
        fs.appendFileSync(events, eventLine(next.fields, base, root));
        break;
      case 'raw':
        fs.appendFileSync(events, next.text.replaceAll('@now@', String(base)));
        break;
      case 'burst': {
        const lines: string[] = [];
        for (let n = 1; n <= next.count; n += 1) {
          const line = eventLine(numbered(next.fields, n, next.pad), base, root);
          if (next.one) lines.push(line);
          else fs.appendFileSync(events, line);
        }
        if (next.one) fs.appendFileSync(events, lines.join(''));
        break;
      }
      case 'start':
        main = launch(daemon, root);
        if (next.wait === 'exit') {
          if (!(await leave(main))) timeouts.push('start: the daemon did not leave');
        } else {
          const said = (): boolean => main !== undefined && (hasStarted(main) || main.status !== undefined);
          const settled = await until(said, WAIT_MS);
          if (!settled) timeouts.push('start: neither a started line nor an exit');
          else if (next.wait === 'started' && !hasStarted(main)) timeouts.push('start: the daemon left without a started line');
        }
        break;
      case 'second': {
        second = launch(other, root);
        if (!(await leave(second))) timeouts.push('second: the daemon did not leave');
        break;
      }
      case 'expect':
        if (main === undefined) throw new Error('expect before start');
        if (!(await until(() => main !== undefined && main.err.count(next.text) >= next.n, next.ms))) timeouts.push(`expect ${next.n} x ${next.text}`);
        break;
      case 'exited':
        if (main === undefined) throw new Error('exited before start');
        if (!(await leave(main))) timeouts.push('exited: the daemon did not leave');
        break;
      case 'file':
        if (!(await until(() => fs.existsSync(abs(next.path)), WAIT_MS))) timeouts.push(`file ${next.path}`);
        break;
      case 'gone':
        if (!(await until(() => !fs.existsSync(abs(next.path)), WAIT_MS))) timeouts.push(`gone ${next.path}`);
        break;
      case 'signal':
        if (main === undefined) throw new Error('signal before start');
        main.child.kill(next.name);
        break;
      case 'quiet':
        await sleep(next.ms);
        break;
    }
  }

  // A script that did not stop the daemon leaves it to this: the stop every scenario ends with.
  if (main !== undefined && main.status === undefined) {
    main.child.kill('SIGTERM');
    if (!(await leave(main))) timeouts.push('end: the daemon did not leave on SIGTERM');
  }

  const out: string[] = [];
  if (main !== undefined) {
    out.push(...lined('stderr', main.err), ...lined('stdout', main.out), `exit ${main.status ?? 'killed'}`);
  }
  if (second !== undefined) {
    out.push(...lined('second-stderr', second.err), ...lined('second-stdout', second.out), `second-exit ${second.status ?? 'killed'}`);
  }
  out.push(...helperCalls(rec), ...tmuxCalls(rec));
  let names: string[];
  try {
    names = fs.readdirSync(state).sort();
  } catch {
    names = [];
  }
  out.push(`state ${names.join(' ')}`);
  for (const name of [EVENTS_FILE, `${EVENTS_FILE}.1`]) {
    const size = sizeOf(path.join(state, name));
    if (size !== undefined) out.push(`size ${name} ${size}`);
  }
  out.push(`lock ${describeLock(path.join(state, 'notify.lock'), wrote, main?.child.pid, second?.child.pid)}`);
  for (const timeout of timeouts) out.push(`timeout ${timeout}`);
  process.stdout.write(`${out.join('\n')}\n`);
}

/** The first check of the shell: what process is this command, once it says it has started? */
async function probe(root: string, daemon: readonly string[]): Promise<void> {
  const proc = launch(daemon, root);
  const came = await until(() => hasStarted(proc) || proc.status !== undefined, WAIT_MS);
  const line = proc.err.all.find((one) => STARTED_LINE.test(one));
  const claimed = line === undefined ? undefined : STARTED_LINE.exec(line)?.[1];
  let image = 'gone';
  if (proc.child.pid !== undefined && proc.status === undefined) {
    const ps = spawnSync('/bin/ps', ['-o', 'comm=', '-p', String(proc.child.pid)], { encoding: 'utf8' });
    const comm = ps.stdout.trim();
    if (ps.status === 0 && comm !== '') image = path.basename(comm);
  }
  const report = [
    `started ${line === undefined ? 'no' : 'yes'}`,
    `pid ${proc.child.pid ?? 'none'}`,
    `claimed ${claimed ?? 'none'}`,
    `image ${image}`,
    `exit ${proc.status ?? 'running'}`,
    `said ${[...proc.err.all, ...proc.out.all].slice(0, 6).join(' | ').slice(0, 600)}`,
  ];
  if (!came) report.push('timeout the process neither started nor left');
  proc.child.kill('SIGTERM');
  if (!(await leave(proc))) report.push('timeout the process did not leave on SIGTERM');
  process.stdout.write(`${report.join('\n')}\n`);
}

function commands(rest: readonly string[]): { daemon: readonly string[]; other: readonly string[] } {
  const at = rest.indexOf('--other');
  return at < 0 ? { daemon: rest, other: rest } : { daemon: rest.slice(0, at), other: rest.slice(at + 1) };
}

const [verb, ...rest] = process.argv.slice(2);
if (verb === 'run' && rest[0] !== undefined && rest[1] !== undefined && rest[2] === '--') {
  const { daemon, other } = commands(rest.slice(3));
  await run(rest[0], rest[1], daemon, other);
} else if (verb === 'probe' && rest[0] !== undefined && rest[1] === '--') {
  await probe(rest[0], commands(rest.slice(2)).daemon);
} else {
  process.stderr.write('usage: rust-notify-parity-driver.mts run <script.json> <root> -- <daemon command...> [--other <command...>] | probe <root> -- <daemon command...>\n');
  process.exitCode = 2;
}
