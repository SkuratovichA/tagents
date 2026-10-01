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
  TurnInput,
} from './driver.ts';
import { readAgentState, labelsBySession, stateDir } from './agent-state.ts';
import { StreamReader } from './stream.ts';
import { holdAwake, keepAwakeWanted, type KeepAwake } from './keep-awake.ts';
import { clipDetail, type TurnOutcome } from './turn-outcome.ts';
import { lastAssistant } from './transcripts.ts';
import { realClock, TurnScope, type TurnClock } from './turn-scope.ts';

/** 50 minutes, the orchestrator's DEFAULT_CLAUDE_TIMEOUT_MS. */
export const DEFAULT_TIMEOUT_MS = 50 * 60 * 1000;
/** The caller hears about a long turn this much before it is killed. */
export const TIMEOUT_WARN_BEFORE_MS = 5 * 60 * 1000;
/**
 * How often a turn adds up the time it was awake. A gap of more than two ticks
 * is the machine asleep, and only two ticks of it count towards the timeout.
 */
export const AWAKE_TICK_MS = 10 * 1000;
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
 *
 * `--disallowedTools <tools...>` and `--mcp-config <configs...>` are VARIADIC:
 * the CLI keeps eating argv words until the next option. So they must never be
 * the last option before the prompt — on a fresh session (no --resume) the
 * prompt would become one more "permission deny rule" and the CLI would exit 1
 * with "Input must be provided either through stdin or as a prompt argument"
 * (the busano ticket agent, 15.09.2026, every batch after the port). They go
 * in front of --output-format, the one option that is always there to
 * terminate them; the test pins that no variadic option ever touches the prompt.
 *
 * `viaStdin` is the input mode of PromptOptions.input: the prompt is not in
 * argv at all but the first stdin line, and the CLI echoes every line it reads.
 */
export function buildArgs(spec: SessionSpec, text: string, resume: string | null, viaStdin = false): string[] {
  const args = ['-p'];
  if (spec.model) args.push('--model', spec.model);
  if (spec.effort) args.push('--effort', spec.effort);
  if (spec.disallowedTools?.length) args.push('--disallowedTools', spec.disallowedTools.join(','));
  if (spec.mcpConfig) args.push('--strict-mcp-config', '--mcp-config', spec.mcpConfig);
  args.push('--output-format', 'stream-json', '--verbose');
  if (viaStdin) args.push('--input-format', 'stream-json', '--replay-user-messages');
  if (spec.skipPermissions) args.push('--dangerously-skip-permissions');
  if (spec.systemPromptFile) args.push('--append-system-prompt-file', spec.systemPromptFile);
  if (resume) args.push('--resume', resume);
  if (!viaStdin) args.push(text);
  return args;
}

/** One stdin line of `--input-format stream-json`: a user message, as the CLI's own SDK writes it. */
export function stdinLine(text: string): string {
  const message = { role: 'user', content: [{ type: 'text', text }] };
  return `${JSON.stringify({ type: 'user', message, parent_tool_use_id: null, session_id: '' })}\n`;
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
  /** Where turns get their time: the real clock by default, a fake one in a lifecycle test. */
  readonly clock?: TurnClock;
  /**
   * What holds the machine awake while a turn's child lives: caffeinate on
   * macOS unless TA_KEEP_AWAKE=0, nothing elsewhere (keep-awake.ts). null
   * turns it off; a test passes a recorder.
   */
  readonly keepAwake?: KeepAwake | null;
}

/** "60 min", or seconds when it was less than a minute. */
const sleptFor = (ms: number): string => (ms >= 60 * 1000 ? `${Math.round(ms / 60000)} min` : `${Math.round(ms / 1000)} s`);

/** What the child left behind when it went. */
interface Exit {
  readonly code: number | null;
  readonly signal: string | null;
}

/**
 * Where one turn stands. `running` has no result yet; `resulted` has one and
 * waits for the process to leave; `exited` has lost the process and waits for
 * the pipes. The turn's disposed scope is the terminal state after all three.
 */
type Phase =
  | { readonly tag: 'running' }
  | { readonly tag: 'resulted'; readonly resultAt: number }
  | { readonly tag: 'exited'; readonly resultAt: number | null; readonly exit: Exit };

function resultAtOf(phase: Phase): number | null {
  switch (phase.tag) {
    case 'running':
      return null;
    case 'resulted':
    case 'exited':
      return phase.resultAt;
  }
}

export class ClaudeHeadlessDriver implements SessionDriver {
  readonly name = 'claude-headless' as const;

  private readonly dir: string;
  private readonly log: (...parts: string[]) => void;
  /** ref.id → the child of the turn running right now, for abort(). */
  private readonly running = new Map<string, ChildProcess>();
  /** ref.id → the claude session id learned from the last turn. */
  private readonly learned = new Map<string, string>();
  private readonly clock: TurnClock;
  private readonly keepAwake: KeepAwake | null;

  constructor(o: ClaudeDriverOptions = {}) {
    this.dir = o.stateDir ?? stateDir();
    this.log = o.log ?? (() => undefined);
    this.clock = o.clock ?? realClock;
    // Not `??`: an explicit null is the off switch, not a missing option.
    this.keepAwake = o.keepAwake !== undefined ? o.keepAwake : keepAwakeWanted() ? holdAwake : null;
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
    const input = o.input;

    return new Promise<TurnOutcome>((resolve) => {
      const clock = this.clock;
      const startedAt = clock.now();
      const child = spawn(spec.bin ?? 'claude', buildArgs(spec, text, resume, input !== undefined), {
        cwd: spec.cwd,
        env: childEnv(spec),
        stdio: [input ? 'pipe' : 'ignore', 'pipe', 'pipe'],
      });
      this.running.set(ref.id, child);

      // Every timer of this turn and its abort listener. finish() disposes it,
      // and a disposed scope schedules nothing: that is the whole cleanup.
      const scope = new TurnScope(clock);
      // Released with the scope. No pid means the spawn failed, and `error` ends the turn.
      if (this.keepAwake && child.pid !== undefined) scope.own(this.keepAwake(child.pid, turnLog));
      let phase: Phase = { tag: 'running' };
      // The killer fired. Not a phase of its own: a result can still come out
      // of the pipe after the SIGKILL, and the exit follows either way.
      let timedOut = false;
      let err = '';

      const kill = (why: string): void => {
        turnLog(why);
        try {
          child.kill('SIGKILL');
        } catch {
          // Already gone: nothing to kill and nothing to report.
        }
      };

      // The limit counts AWAKE time. A MacBook on battery sleeps under a running
      // turn and the timers count the sleep: on 01.10.2026 a 90-minute turn was
      // killed after about five awake minutes, its 85-minute warning arriving 85.5
      // wall minutes in. So a tick adds the time since the last one, capped at two
      // ticks — a longer gap is the machine asleep, and is not counted.
      const warnAt = o.onWarn && timeoutMs > warnBeforeMs ? timeoutMs - warnBeforeMs : null;
      let awakeMs = 0;
      let lastTick = startedAt;
      let warned = false;
      let cancelTick = (): void => undefined;
      const tick = (): void => {
        const now = clock.now();
        const gap = Math.max(0, now - lastTick);
        const counted = Math.min(gap, 2 * AWAKE_TICK_MS);
        lastTick = now;
        awakeMs += counted;
        if (gap > counted) turnLog(`turn: machine slept ~${sleptFor(gap - counted)}, not counted`);
        if (awakeMs >= timeoutMs) {
          timedOut = true;
          kill(`claude timed out after ${Math.round(timeoutMs / 60000)} min — killing`);
          return;
        }
        if (warnAt !== null && !warned && awakeMs >= warnAt && phase.tag === 'running') {
          warned = true;
          turnLog(`claude running ${Math.round(awakeMs / 60000)} min — warning the caller`);
          try {
            o.onWarn?.({ elapsedMs: awakeMs, leftMs: timeoutMs - awakeMs });
          } catch (e) {
            turnLog(`timeout warning failed: ${(e as Error).message}`);
          }
        }
        schedule();
      };
      // The next tick never lands past the warning or the kill, so on a clock
      // that does not sleep both fire to the millisecond.
      const schedule = (): void => {
        const toWarn = warnAt !== null && !warned && warnAt > awakeMs ? warnAt - awakeMs : Infinity;
        cancelTick = scope.after(Math.min(AWAKE_TICK_MS, timeoutMs - awakeMs, toWarn), tick);
      };
      schedule();
      const cancelKiller = (): void => cancelTick();

      scope.onAbort(o.signal, () => kill('aborted by the caller — killing'));

      // Input mode only (o.input present). `delivered` is every item pulled, in
      // order; `unread` is the lines written to stdin and not yet echoed back,
      // oldest first, the prompt line (null) at its head. The CLI echoes in
      // write order, so an echo always belongs to the head.
      const delivered: { id: string; replayed: boolean }[] = [];
      const unread: ({ id: string; replayed: boolean } | null)[] = [];
      let stdinOpen = false;
      let iterator: AsyncIterator<TurnInput> | null = null;
      // When the LAST result arrived. In input mode a result that leaves lines
      // unread keeps the phase `running`, so the phase alone cannot say it.
      let lastResultAt: number | null = null;
      // num_turns summed over every result: unlike the cost it is per result.
      let resultTurns: number | null = null;
      // The outcome is out; the pump must not report into a resolved turn.
      let settled = false;

      const stopPulling = (): void => {
        const it = iterator;
        iterator = null;
        try {
          it?.return?.()?.catch(() => undefined);
        } catch {
          // The iterable's own shutdown failing is not this turn's failure.
        }
      };

      const closeInput = (): void => {
        stopPulling();
        if (!stdinOpen) return;
        stdinOpen = false;
        child.stdin?.end();
      };

      const writeLine = (line: string): boolean => {
        const stdin = child.stdin;
        if (!stdinOpen || !stdin || !stdin.writable) return false;
        stdin.write(line);
        return true;
      };

      const onReplay = (): void => {
        const head = unread.shift();
        if (head === undefined) {
          turnLog('claude echoed a stdin line nobody is waiting for — ignoring it');
          return;
        }
        if (head === null) return; // the prompt line
        head.replayed = true;
        try {
          o.onEvent?.({ kind: 'replay', id: head.id });
        } catch {
          // A listener must not be able to fail the turn it is only watching.
        }
      };

      const onResult = (): void => {
        lastResultAt = clock.now();
        if (input && phase.tag === 'running') {
          // A result proves the prompt was read, echoed or not.
          if (unread[0] === null) unread.shift();
          if (unread.length > 0) {
            // Written after the model's last tool boundary: the CLI answers it
            // as a turn of its own in this same process (E3a, 28.09.2026).
            turnLog(`claude printed a result with ${unread.length} input line(s) unread — waiting for their turn`);
            return;
          }
          closeInput();
        }
        switch (phase.tag) {
          case 'running':
            // The work is done; from here on only the shutdown can go wrong.
            phase = { tag: 'resulted', resultAt: clock.now() };
            cancelKiller();
            scope.after(exitGraceMs, () => {
              if (phase.tag === 'resulted') kill(`claude printed its result but did not exit within ${exitGraceMs} ms — killing`);
            });
            return;
          case 'exited':
            // The process is already gone, so there is no exit left to wait for.
            if (phase.resultAt === null) phase = { ...phase, resultAt: clock.now() };
            cancelKiller();
            return;
          case 'resulted':
            return;
          default:
            phase satisfies never;
        }
      };

      const reader = new StreamReader(
        (e: StreamEvent) => {
          if (e.kind === 'result') {
            if (input) resultTurns = (resultTurns ?? 0) + (e.payload.num_turns ?? 0);
            onResult();
          }
          o.onEvent?.(e);
        },
        input ? onReplay : undefined
      );
      child.stdout?.on('data', (d: Buffer) => reader.push(d.toString()));
      child.stderr?.on('data', (d: Buffer) => {
        err += d.toString();
      });

      const finish = (spawnError: string | null = null): void => {
        if (!scope.dispose()) return;
        this.running.delete(ref.id);
        // May flush the result line itself, which moves the phase: read it after.
        reader.end();
        // Nothing is written from here on; an item pulled late is not delivered.
        settled = true;
        stdinOpen = false;
        stopPulling();
        const extra = input ? { delivered: delivered.map((d) => ({ ...d })) } : {};

        // In input mode `p` is the LAST result. Its total_cost_usd counts the
        // whole process (0.068 → 0.072 → 0.075 over three results in E3a,
        // 28.09.2026), so it is the turn's cost and summing would count twice;
        // num_turns and usage are per result, so the turns are summed instead.
        const p = reader.payload;
        const resultAt = resultAtOf(phase) ?? (input ? lastResultAt : null);
        const exit = phase.tag === 'exited' ? phase.exit : null;
        const code = exit?.code ?? null;
        const signal = exit?.signal ?? null;
        const sessionId = p?.session_id ?? reader.sessionId ?? null;
        if (sessionId) this.learned.set(ref.id, sessionId);
        const durationMs = clock.now() - startedAt;
        const detail = clipDetail(String(p?.result ?? err ?? ''));
        // What the turn managed to do before it ended, for a caller deciding
        // whether re-running it is safe. `reader.text` only ever grows from an
        // assistant TEXT block, so non-empty IS "at least one text event".
        const saw = { sawText: reader.text.length > 0, sawResult: reader.sawResult };

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
            numTurns: input && resultTurns !== null ? resultTurns : (p.num_turns ?? null),
            durationMs,
            ...extra,
          };
          // The exit code is about the shutdown, not the work.
          resolve(resultAt !== null && code !== 0 ? { kind: 'killed-after-result', ...base, code } : { kind: 'ok', ...base });
          return;
        }
        if (timedOut) {
          resolve({ kind: 'timeout', sessionId, toolUses: reader.toolUses, limitMs: timeoutMs, detail, ...saw, ...extra });
          return;
        }
        resolve({ kind: 'exited', sessionId, toolUses: reader.toolUses, code, signal, detail, ...saw, ...extra });
      };

      // Pull input items for as long as stdin is open, writing each at once.
      const pump = async (it: AsyncIterator<TurnInput>): Promise<void> => {
        for (;;) {
          let next: IteratorResult<TurnInput>;
          try {
            next = await it.next();
          } catch (e) {
            turnLog(`turn input failed: ${(e as Error).message}`);
            return;
          }
          if (next.done) return;
          if (settled) {
            turnLog(`input ${next.value.id} arrived after the turn ended — not delivered`);
            return;
          }
          const item = { id: next.value.id, replayed: false };
          delivered.push(item);
          if (writeLine(stdinLine(next.value.text))) unread.push(item);
          else turnLog(`input ${item.id} arrived after stdin closed — not written`);
          // An iterator that ignores return() must still not be read forever.
          if (iterator === null && !stdinOpen) return;
        }
      };

      if (input) {
        stdinOpen = true;
        // EPIPE and friends: the process died under us. What was written and
        // never echoed stays `replayed: false`, which is the whole report.
        child.stdin?.on('error', (e) => {
          stdinOpen = false;
          turnLog(`claude stdin: ${e.message}`);
        });
        unread.push(null);
        writeLine(stdinLine(text));
        iterator = input[Symbol.asyncIterator]();
        void pump(iterator);
      }

      child.on('error', (e) => finish(e.message));
      child.on('exit', (code, signal) => {
        phase = { tag: 'exited', resultAt: resultAtOf(phase), exit: { code, signal } };
        stdinOpen = false;
        stopPulling();
        scope.after(pipeDrainMs, () => finish()); // in case `close` never comes
      });
      child.on('close', () => finish());
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
