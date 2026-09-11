// The headless Claude backend: `claude -p`, stream-json out, one turn per call.
//
// Ported from orchestrator/src/turn.mjs (the lifecycle) and
// orchestrator/src/runner.mjs + sdano-bot/src/claude.ts (argv and env). The
// incident it exists to prevent is written down in turn-outcome.ts; the short
// version is that a turn ends when its `result` event arrives, NOT when the
// process does.
//
// open() starts nothing. A session here is a transcript plus a claude session
// id; the only thing that runs is a prompt.
import { spawn, type ChildProcess } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import type {
  PromptOptions,
  SessionDriver,
  SessionRef,
  SessionSpec,
  SessionState,
  StreamEvent,
} from './driver.ts';
import { readAgentState, labelsBySession, stateDir } from './agent-state.ts';
import { StreamReader } from './stream.ts';
import { clipDetail, type TurnOutcome } from './turn-outcome.ts';
import { lastAssistant } from './transcripts.ts';

/** 50 minutes, the orchestrator's DEFAULT_CLAUDE_TIMEOUT_MS. */
export const DEFAULT_TIMEOUT_MS = 50 * 60 * 1000;
/** The caller hears about a long turn this much before it is killed. */
export const TIMEOUT_WARN_BEFORE_MS = 5 * 60 * 1000;
/**
 * A turn whose `result` event has arrived is OVER. If the process is still
 * around after this, something is stuck on the way out (an MCP server, a
 * grandchild holding the pipe) — kill it and KEEP the result.
 */
export const RESULT_EXIT_GRACE_MS = 60 * 1000;
/**
 * After `exit`, how long to wait for the stdio pipes before giving up on them:
 * a nohup'd grandchild can hold stdout open for hours, and `close` never fires.
 */
export const PIPE_DRAIN_MS = 5 * 1000;

/**
 * Everything that touches the machine or the web, for a session that should
 * only talk to its MCP server. `--tools ""` looks like the same thing and is
 * not: it drops the MCP tools as well (verified 10.09.2026).
 */
export const DISALLOWED_TOOLS = [
  'Bash',
  'Edit',
  'Write',
  'MultiEdit',
  'NotebookEdit',
  'Read',
  'Glob',
  'Grep',
  'LS',
  'Agent',
  'Task',
  'WebFetch',
  'WebSearch',
  'TodoWrite',
  'Skill',
] as const;

/**
 * The argv, in the order runner.mjs and sdano-bot build it — the orchestrator's
 * contract test asserts that -p, --output-format stream-json and
 * --append-system-prompt-file are all present and in front of the prompt.
 * stream-json without --verbose is refused by the CLI in -p mode.
 */
export function buildArgs(spec: SessionSpec, text: string, resume: string | null): string[] {
  const args = ['-p'];
  if (spec.model) args.push('--model', spec.model);
  if (spec.effort) args.push('--effort', spec.effort);
  args.push('--output-format', 'stream-json', '--verbose');
  if (spec.skipPermissions) args.push('--dangerously-skip-permissions');
  if (spec.systemPromptFile) args.push('--append-system-prompt-file', spec.systemPromptFile);
  if (spec.mcpConfig) args.push('--strict-mcp-config', '--mcp-config', spec.mcpConfig);
  if (spec.disallowedTools?.length) args.push('--disallowedTools', spec.disallowedTools.join(','));
  if (resume) args.push('--resume', resume);
  args.push(text);
  return args;
}

/**
 * The child's environment.
 *
 * Every CLAUDE* variable is dropped first: this process may have been started
 * from a shell carrying another account's CLAUDE_CONFIG_DIR, and that is a
 * whole login — resuming the conversation on the wrong one finds nothing. Then
 * spec.configDir decides: undefined keeps whatever the parent had, null means
 * the default account, a string picks one.
 *
 * PATH is a configuration choice, not an inheritance. A daemon's PATH lacks
 * ~/.local/bin, where the `claude` symlink lives (orchestrator/LEARNING.md:
 * "spawn claude ENOENT from a daemon"), and the MCP servers are started as bare
 * `node`, which must be THIS node and not a 2021 one from /usr/local/bin.
 */
export function childEnv(spec: SessionSpec, parent: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const e: NodeJS.ProcessEnv = { ...parent };
  const inheritedConfigDir = e['CLAUDE_CONFIG_DIR'];
  for (const k of Object.keys(e)) if (k.startsWith('CLAUDE')) delete e[k];
  const configDir = spec.configDir === undefined ? inheritedConfigDir : spec.configDir;
  if (configDir) e['CLAUDE_CONFIG_DIR'] = configDir;

  const inherited = (e['PATH'] ?? '').split(':').filter(Boolean);
  const first = [path.dirname(process.execPath), path.join(os.homedir(), '.local', 'bin')];
  e['PATH'] = [...first, ...inherited].filter((p, i, a) => a.indexOf(p) === i).join(':');

  if (spec.label) e['TA_LABEL'] = spec.label;
  if (spec.logFile) e['TA_LOG'] = spec.logFile;
  if (spec.env) for (const [k, v] of Object.entries(spec.env)) e[k] = v;
  return e;
}

export interface ClaudeDriverOptions {
  /** Where the hook publishes its records; $TA_STATE_DIR by default. */
  readonly stateDir?: string;
  /** Called with one line of diagnostics per interesting moment. */
  readonly log?: (...parts: string[]) => void;
}

export class ClaudeHeadlessDriver implements SessionDriver {
  readonly name = 'claude-headless' as const;

  private readonly dir: string;
  private readonly log: (...parts: string[]) => void;
  /** ref.id → the child of the turn running right now, for abort(). */
  private readonly running = new Map<string, ChildProcess>();
  /** ref.id → the claude session id learned from the last turn. */
  private readonly learned = new Map<string, string>();

  constructor(o: ClaudeDriverOptions = {}) {
    this.dir = o.stateDir ?? stateDir();
    this.log = o.log ?? (() => undefined);
  }

  /** No process is started. `resume` is the claude session id to continue. */
  async open(spec: SessionSpec, resume?: string | null): Promise<SessionRef> {
    const claudeSessionId = resume ?? null;
    const transcript = claudeSessionId ? this.transcriptOf(claudeSessionId) : null;
    const ref: SessionRef = { id: randomUUID(), claudeSessionId, transcript, spec };
    if (claudeSessionId) this.learned.set(ref.id, claudeSessionId);
    return ref;
  }

  prompt(ref: SessionRef, text: string, o: PromptOptions): Promise<TurnOutcome> {
    const spec = ref.spec;
    const timeoutMs = o.timeoutMs;
    const warnBeforeMs = o.warnBeforeMs ?? TIMEOUT_WARN_BEFORE_MS;
    const exitGraceMs = o.exitGraceMs ?? RESULT_EXIT_GRACE_MS;
    const pipeDrainMs = o.pipeDrainMs ?? PIPE_DRAIN_MS;
    const resume = ref.claudeSessionId ?? this.learned.get(ref.id) ?? null;
    // This turn's diagnostics sink. A driver serves one process; a turn serves
    // one job, and the job is what has a log to write into — so o.log wins.
    const turnLog = o.log ?? ((line: string): void => this.log(line));

    return new Promise<TurnOutcome>((resolve) => {
      const startedAt = Date.now();
      const child = spawn(spec.bin ?? 'claude', buildArgs(spec, text, resume), {
        cwd: spec.cwd,
        env: childEnv(spec),
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      this.running.set(ref.id, child);

      const reader = new StreamReader((e: StreamEvent) => {
        if (e.kind === 'result' && !resultAt) {
          // The work is done; from here on only the shutdown can go wrong.
          resultAt = Date.now();
          clearTimeout(killer);
          later(() => {
            if (!exit) kill(`claude printed its result but did not exit within ${exitGraceMs} ms — killing`);
          }, exitGraceMs);
        }
        o.onEvent?.(e);
      });

      let err = '';
      let timedOut = false;
      let resultAt: number | null = null;
      let exit: { code: number | null; signal: string | null } | null = null;
      let spawnError: string | null = null;
      let done = false;
      const timers: NodeJS.Timeout[] = [];
      const later = (fn: () => void, ms: number): NodeJS.Timeout => {
        const t = setTimeout(fn, ms);
        timers.push(t);
        return t;
      };
      const kill = (why: string): void => {
        turnLog(why);
        try {
          child.kill('SIGKILL');
        } catch {
          // Already gone: nothing to kill and nothing to report.
        }
      };

      const killer = later(() => {
        timedOut = true;
        kill(`claude timed out after ${Math.round(timeoutMs / 60000)} min — killing`);
      }, timeoutMs);

      if (o.onWarn && timeoutMs > warnBeforeMs)
        later(() => {
          if (resultAt || exit) return;
          turnLog(`claude running ${Math.round((Date.now() - startedAt) / 60000)} min — warning the caller`);
          try {
            o.onWarn?.({ elapsedMs: Date.now() - startedAt, leftMs: warnBeforeMs });
          } catch (e) {
            turnLog(`timeout warning failed: ${(e as Error).message}`);
          }
        }, timeoutMs - warnBeforeMs);

      const onAbort = (): void => kill('aborted by the caller — killing');
      o.signal?.addEventListener('abort', onAbort, { once: true });

      child.stdout?.on('data', (d: Buffer) => reader.push(d.toString()));
      child.stderr?.on('data', (d: Buffer) => {
        err += d.toString();
      });

      const finish = (): void => {
        if (done) return;
        done = true;
        for (const t of timers) clearTimeout(t);
        o.signal?.removeEventListener('abort', onAbort);
        this.running.delete(ref.id);
        reader.end();

        const p = reader.payload;
        const code = exit?.code ?? null;
        const signal = exit?.signal ?? null;
        const sessionId = p?.session_id ?? reader.sessionId ?? null;
        if (sessionId) this.learned.set(ref.id, sessionId);
        const durationMs = Date.now() - startedAt;
        const detail = clipDetail(String(p?.result ?? err ?? ''));

        if (spawnError) {
          resolve({ kind: 'spawn-failed', detail: spawnError });
          return;
        }
        if (p && p.is_error === false) {
          const base = {
            text: reader.text,
            sessionId,
            toolUses: reader.toolUses,
            costUsd: p.total_cost_usd ?? null,
            numTurns: p.num_turns ?? null,
            durationMs,
          };
          // The exit code is about the shutdown, not the work.
          resolve(resultAt !== null && code !== 0 ? { kind: 'killed-after-result', ...base, code } : { kind: 'ok', ...base });
          return;
        }
        if (timedOut) {
          resolve({ kind: 'timeout', sessionId, toolUses: reader.toolUses, limitMs: timeoutMs, detail });
          return;
        }
        resolve({ kind: 'exited', sessionId, toolUses: reader.toolUses, code, signal, detail });
      };

      child.on('error', (e) => {
        spawnError = e.message;
        exit = { code: null, signal: null };
        finish();
      });
      child.on('exit', (code, signal) => {
        exit = { code, signal };
        later(finish, pipeDrainMs); // in case `close` never comes
      });
      child.on('close', finish);
    });
  }

  async last(ref: SessionRef): Promise<{ text: string; at: number } | null> {
    const file = ref.transcript ?? (ref.claudeSessionId ? this.transcriptOf(ref.claudeSessionId) : null);
    return file ? lastAssistant(file) : null;
  }

  /**
   * What the hook knows about. The dashboard and this driver see headless
   * sessions the same way: through hooks/tmux-agent-state.sh, never through a
   * process table — the driver that started a session is usually long gone by
   * the time somebody asks what is running.
   */
  async list(f?: { label?: string; state?: readonly SessionState[] }): Promise<readonly SessionRef[]> {
    const labels = labelsBySession(this.dir);
    const refs: SessionRef[] = [];
    for (const row of readAgentState(this.dir)) {
      if (row.state === 'subdone') continue;
      if (f?.state && !f.state.includes(row.state)) continue;
      const label = labels.get(row.sessionId) ?? '';
      if (f?.label !== undefined && label !== f.label) continue;
      const spec: SessionSpec = {
        kind: 'claude',
        cwd: row.cwd,
        skipPermissions: false,
        ...(label ? { label } : {}),
        // No seventh column at all means the row predates it and says nothing
        // about the account: inherit, rather than claim the default one.
        ...(row.hasConfigDir ? { configDir: row.configDir === '' ? null : row.configDir } : {}),
      };
      refs.push({
        id: row.key,
        claudeSessionId: row.sessionId || null,
        transcript: row.transcript || null,
        spec,
      });
    }
    return refs;
  }

  /** Kill the turn running for this ref, if one is. A no-op otherwise. */
  async abort(ref: SessionRef): Promise<void> {
    const child = this.running.get(ref.id);
    if (!child) return;
    try {
      child.kill('SIGKILL');
    } catch {
      // Already gone.
    }
  }

  private transcriptOf(claudeSessionId: string): string | null {
    for (const row of readAgentState(this.dir))
      if (row.sessionId === claudeSessionId && row.transcript) return row.transcript;
    return null;
  }
}
