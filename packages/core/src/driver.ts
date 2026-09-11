// The contract every session backend implements. Today there is one backend
// (claude-driver.ts, headless `claude -p`); the names 'tmux-pane' and 'herdr'
// are reserved for the two the dashboard already knows how to look at, so that
// adding them later is an implementation and not an interface change.
//
// Nothing in this file runs. It is the vocabulary the CLI, the plugins and the
// orchestrator share.
import type { TurnOutcome } from './turn-outcome.ts';

/**
 * The coarse state the tmux hook publishes (hooks/tmux-agent-state.sh):
 * 'new' at SessionStart, 'working' while a turn runs, 'blocked' when Claude
 * asks for a decision, 'done' at Stop, 'gone' at SessionEnd.
 */
export type SessionState = 'new' | 'working' | 'blocked' | 'done' | 'gone';

/** Everything needed to start (or resume) a session, and nothing else. */
export interface SessionSpec {
  readonly kind: 'claude';
  /** Working directory of the child. Also what names the transcript project dir. */
  readonly cwd: string;
  /** Free-form name; reaches the child as TA_LABEL and the dashboard as a column. */
  readonly label?: string;
  /**
   * Which Claude account/config dir the session runs on — a whole login, not a
   * setting. Tri-state on purpose:
   *   undefined → inherit the parent's CLAUDE_CONFIG_DIR
   *   null      → unset it (land on the default account)
   *   string    → set it (this is how the tagents dashboard picks an account)
   */
  readonly configDir?: string | null;
  readonly model?: string;
  readonly effort?: string;
  /** --append-system-prompt-file: the persona/brief prepended to the system prompt. */
  readonly systemPromptFile?: string;
  /** --mcp-config, always with --strict-mcp-config so nothing else is loaded. */
  readonly mcpConfig?: string;
  /** --disallowedTools. Never `--tools ""` — that also drops the MCP tools. */
  readonly disallowedTools?: readonly string[];
  readonly skipPermissions: boolean;
  /** Extra environment, merged last — it wins over everything computed here. */
  readonly env?: Readonly<Record<string, string>>;
  /** The binary to run; 'claude' when absent. */
  readonly bin?: string;
  /** Reaches the child as TA_LOG so the dashboard can preview the session's log. */
  readonly logFile?: string;
}

/**
 * A handle on one session. A session is a TRANSCRIPT, not a process: between
 * two turns nothing of it is running, and `claudeSessionId` is the whole of
 * what carries the conversation from one turn to the next.
 */
export interface SessionRef {
  /** Ours: stable across turns, unique per driver. */
  readonly id: string;
  /** Claude's own session id, learned from the stream; null before the first turn. */
  readonly claudeSessionId: string | null;
  /** Path of the .jsonl transcript, when it is known. */
  readonly transcript: string | null;
  readonly spec: SessionSpec;
}

/** What the caller learns WHILE a turn runs. */
export type StreamEvent =
  | { kind: 'tool_use'; name: string; input: Record<string, unknown> }
  | { kind: 'text'; text: string }
  | { kind: 'result'; isError: boolean }
  | { kind: 'other'; type: string };

export interface PromptOptions {
  /** Hard limit. When it fires the child is killed and the turn is a 'timeout'. */
  readonly timeoutMs: number;
  /** Fire `onWarn` this long before the kill. */
  readonly warnBeforeMs?: number;
  readonly onWarn?: (info: { elapsedMs: number; leftMs: number }) => void;
  /** How long a child may take to leave AFTER printing its result. */
  readonly exitGraceMs?: number;
  /** How long to wait for the stdio pipes after `exit` before giving up on them. */
  readonly pipeDrainMs?: number;
  /** Must not throw: it is called from the stream reader. */
  readonly onEvent?: (e: StreamEvent) => void;
  /**
   * Where THIS turn's diagnostics go — the kill, abort and long-turn warning
   * lines the driver writes while the turn runs. Without it they go to the
   * driver's own `log`, which a process running turns in parallel has to share
   * between all of them; with it every turn can hand over its own sink (a
   * per-job log file, a request logger) and one driver serves the whole
   * process. Must not throw.
   */
  readonly log?: (line: string) => void;
  readonly signal?: AbortSignal;
}

export interface SessionDriver {
  readonly name: 'claude-headless' | 'tmux-pane' | 'herdr';
  /** Creates no process. `resume` carries a previous claude session id. */
  open(spec: SessionSpec, resume?: string | null): Promise<SessionRef>;
  /** One turn. Resolves with what it ended as — it does not throw for a failed turn. */
  prompt(ref: SessionRef, text: string, o: PromptOptions): Promise<TurnOutcome>;
  /** The last assistant text on record, read from the transcript. */
  last(ref: SessionRef): Promise<{ text: string; at: number } | null>;
  list(f?: { label?: string; state?: readonly SessionState[] }): Promise<readonly SessionRef[]>;
  /** Kill the in-flight turn of that ref, if there is one. */
  abort(ref: SessionRef): Promise<void>;
  wait?(ref: SessionRef, until: readonly SessionState[], timeoutMs: number): Promise<SessionState>;
}
