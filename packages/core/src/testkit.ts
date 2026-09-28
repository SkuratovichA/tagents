// Fakes for anybody who tests against this package — ours and a plugin's.
//
// fakeClaude() writes a REAL executable named `claude` into a temp directory
// and hands back its path. A test puts that directory on the child's PATH (or
// passes the file as spec.bin) and the driver then does exactly what it does in
// production: spawn, read a pipe, watch a process die. Nothing about the turn
// lifecycle is stubbed, which is the only way a test can pin "killed after the
// result is still a success".
//
// The fake is SINGLE-SHOT by construction: one script, no per-call state, and
// `countFile` records every invocation. A fake that quietly answers twice hides
// exactly the bug this package exists to prevent (a re-run that duplicates the
// work), so a test asserts the count instead of trusting it.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export interface FakeToolCall {
  readonly name: string;
  readonly input?: Record<string, unknown>;
}

export interface FakeResult {
  readonly isError?: boolean;
  readonly text?: string;
  readonly costUsd?: number;
  readonly numTurns?: number;
  readonly durationMs?: number;
}

export interface FakeScript {
  readonly sessionId?: string;
  /** Lines that are not JSON at all: banners, warnings, a half-written line. */
  readonly noise?: readonly string[];
  readonly tools?: readonly (string | FakeToolCall)[];
  readonly text?: string;
  /** Pause before printing the result — what a slow turn looks like. */
  readonly sleepMs?: number;
  /** null prints no result at all (a turn that dies mid-flight). */
  readonly result?: FakeResult | null;
  /** Print one plain `--output-format json` payload instead of stream-json. */
  readonly plain?: boolean;
  /** Stay alive after the result, the way a stuck MCP server does. */
  readonly hangAfterResult?: boolean;
  /** Stay alive once the script is done, with or without a result. */
  readonly hang?: boolean;
  /** Print nothing at all and stay alive: a turn that never got going. */
  readonly silent?: boolean;
  readonly exitCode?: number;
  readonly stderr?: string;
  /** One line appended per invocation. */
  readonly countFile?: string;
  /** argv and env of the invocation, as JSON. */
  readonly argvFile?: string;
  /** Split every line across two writes, to prove the reader reassembles them. */
  readonly chunked?: boolean;
  /**
   * Behave like `--input-format stream-json --replay-user-messages`: ignore
   * the argv prompt, read user lines from stdin, echo each one back, and answer
   * with `result` (plus `text`/`tools`) after `sleepMs`. A line that arrives
   * while a turn works is absorbed into it; a line that arrives while idle
   * starts a turn of its own. The process leaves when stdin ends and it is idle.
   */
  readonly stdin?: FakeStdin;
}

export interface FakeStdin {
  /** Every raw line read from stdin is appended here. */
  readonly linesFile?: string;
  /** Hold the echo of a line that arrives mid-turn until that turn's result: the model had no tool boundary left. */
  readonly replayAfterResult?: boolean;
  /** Echo only the first line (the prompt); later lines are read and never reach the "model". */
  readonly replayOnlyFirst?: boolean;
  /** The result of the Nth turn (0-based) — `result` is the fallback for a turn not listed. */
  readonly results?: readonly FakeResult[];
}

export interface FakeClaude {
  /** Put this on PATH and `claude` resolves to the fake. */
  readonly dir: string;
  /** Full path of the executable, for spec.bin. */
  readonly bin: string;
  cleanup(): void;
}

const RUNNER = `#!NODE#
'use strict';
const fs = require('fs');
const plan = #PLAN#;
const stdinKind = () => {
  try {
    const st = fs.fstatSync(0);
    return st.isFIFO() || st.isSocket() ? 'pipe' : st.isCharacterDevice() ? 'null' : 'other';
  } catch { return 'none'; }
};
if (plan.argvFile) fs.writeFileSync(plan.argvFile, JSON.stringify({ argv: process.argv.slice(2), env: process.env, stdin: stdinKind() }));
if (plan.countFile) fs.appendFileSync(plan.countFile, 'run\\n');
const sid = plan.sessionId || 'sess-1';
const say = (o) => {
  const s = JSON.stringify(o) + '\\n';
  if (!plan.chunked) { process.stdout.write(s); return; }
  const cut = Math.max(1, Math.floor(s.length / 2));
  process.stdout.write(s.slice(0, cut));
  process.stdout.write(s.slice(cut));
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hang = () => setInterval(() => {}, 1000);
const resultLine = (r) => {
  const payload = {
    is_error: r.isError === true,
    result: r.text === undefined ? 'done' : r.text,
    session_id: sid,
    total_cost_usd: r.costUsd === undefined ? 0.1 : r.costUsd,
    num_turns: r.numTurns === undefined ? 3 : r.numTurns,
    duration_ms: r.durationMs === undefined ? 5 : r.durationMs,
  };
  return plan.plain ? payload : Object.assign({ type: 'result', subtype: 'success' }, payload);
};
if (plan.stdin) {
  const sp = plan.stdin;
  let busy = false;
  let ended = false;
  let turn = 0;
  let seen = 0;
  let buf = '';
  const held = [];
  const echo = (line) => say(Object.assign({}, JSON.parse(line), { session_id: sid, isReplay: true }));
  const leave = () => {
    if (!ended || busy) return;
    if (plan.stderr) process.stderr.write(plan.stderr);
    if (plan.hangAfterResult || plan.hang) { hang(); return; }
    process.exitCode = plan.exitCode || 0;
  };
  const work = async () => {
    busy = true;
    for (const t of plan.tools || []) {
      const tool = typeof t === 'string' ? { name: t, input: {} } : t;
      say({ type: 'assistant', session_id: sid, message: { content: [{ type: 'tool_use', name: tool.name, input: tool.input || {} }] } });
    }
    if (plan.text) say({ type: 'assistant', session_id: sid, message: { content: [{ type: 'text', text: plan.text }] } });
    if (plan.sleepMs) await sleep(plan.sleepMs);
    const r = (sp.results && sp.results[turn]) || plan.result;
    turn += 1;
    if (r) say(resultLine(r));
    busy = false;
    const next = held.splice(0);
    if (next.length) { for (const l of next) echo(l); await work(); return; }
    leave();
  };
  const onLine = (line) => {
    if (!line.trim()) return;
    seen += 1;
    if (sp.linesFile) fs.appendFileSync(sp.linesFile, line + '\\n');
    if (sp.replayOnlyFirst && seen > 1) return;
    if (busy) { if (sp.replayAfterResult) held.push(line); else echo(line); return; }
    echo(line);
    void work();
  };
  say({ type: 'system', subtype: 'init', session_id: sid });
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (d) => {
    buf += d;
    let nl = buf.indexOf('\\n');
    while (nl >= 0) { onLine(buf.slice(0, nl)); buf = buf.slice(nl + 1); nl = buf.indexOf('\\n'); }
  });
  process.stdin.on('end', () => { ended = true; leave(); });
} else (async () => {
  for (const line of plan.noise || []) process.stdout.write(line + '\\n');
  if (plan.silent) { hang(); return; }
  say({ type: 'system', subtype: 'init', session_id: sid });
  for (const t of plan.tools || []) {
    const tool = typeof t === 'string' ? { name: t, input: {} } : t;
    say({ type: 'assistant', session_id: sid, message: { content: [{ type: 'tool_use', name: tool.name, input: tool.input || {} }] } });
  }
  if (plan.text) say({ type: 'assistant', session_id: sid, message: { content: [{ type: 'text', text: plan.text }] } });
  if (plan.sleepMs) await sleep(plan.sleepMs);
  if (plan.result !== null && plan.result !== undefined) say(resultLine(plan.result));
  if (plan.stderr) process.stderr.write(plan.stderr);
  if (plan.hangAfterResult || plan.hang) { hang(); return; }
  process.exitCode = plan.exitCode || 0;
})();
`;

/** Write the fake into `dir` (a fresh temp dir by default) and return its path. */
export function fakeClaude(script: FakeScript = {}, dir = tmpDir('fake-claude')): FakeClaude {
  const bin = path.join(dir, 'claude');
  fs.writeFileSync(bin, RUNNER.replace('#!NODE#', `#!${process.execPath}`).replace('#PLAN#', () => JSON.stringify(script)));
  fs.chmodSync(bin, 0o755);
  return { dir, bin, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

/**
 * realpath: on macOS os.tmpdir() is a symlink (/var → /private/var) and a child
 * process may report either spelling. Resolving once up front keeps path
 * comparisons exact.
 */
export function tmpDir(prefix = 'tagents-core'): string {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`)));
}

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Wait until `check` is true, or fail saying what never happened. */
export async function drained(
  check: () => boolean | Promise<boolean>,
  { what = 'the condition', timeoutMs = 5000, everyMs = 10 }: { what?: string; timeoutMs?: number; everyMs?: number } = {}
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await check()) return;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(everyMs);
  }
}
