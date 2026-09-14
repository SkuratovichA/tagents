// Reader for what hooks/tmux-agent-state.sh publishes.
//
// The hook runs INSIDE Claude's own process on every hook event and writes one
// record per pane into $TA_STATE_DIR (default ~/.claude/agent-state):
//
//   <key>.tsv     one line, tab separated:
//                   1 at         epoch seconds
//                   2 state      new | working | blocked | done | subdone
//                   3 sessionId  Claude's session id
//                   4 cwd
//                   5 transcript path of the .jsonl
//                   6 detail     what it is doing, already clipped to 90 chars
//                   7 configDir  CLAUDE_CONFIG_DIR of the session ('' = default)
//                   8 pid        the claude process, for a row with no pane
//                   9 logFile    $TA_LOG, where that session's output went
//                  10 label      $TA_LABEL, the name it was started under
//                  11 parentKey  the record key of the agent that started it
//                  12 parentSid  the session id of that agent
//   history.tsv   append-only: at, kind (start|turn|end), sessionId, pane,
//                 label (TA_LABEL), cwd — plus, for a child and nobody else, a
//                 seventh column with the parent's session id
//   sub/<key>.<agent_id>   one subagent, at + detail
//
// Two field-count subtleties, both deliberate in the hook and both preserved
// here. A record with only SIX fields was written before the account column
// existed and says NOTHING about the account, which is not the same as an
// empty seventh field (that one means "the default account") — hence
// `hasConfigDir`. The eighth field is newer still: the pid of a headless child,
// written only for rows that have one.
//
// A `.tsv` key is either a tmux pane id without its '%' (digits) or 's-<sid>'
// for a session that had no pane of its own. Anything else in the directory —
// history.tsv, the sub/ dir, a half-written '.<key>.<pid>' temp file — is not a
// record and is skipped.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { SessionState } from './driver.ts';

const TAB = '\t';

export interface AgentStateRow {
  /** The file's basename without .tsv: a pane number, or 's-<session id>'. */
  readonly key: string;
  readonly at: number;
  readonly state: SessionState | 'subdone';
  readonly sessionId: string;
  readonly cwd: string;
  readonly transcript: string;
  readonly detail: string;
  /** '' means the default account; null means the row predates the column. */
  readonly configDir: string | null;
  readonly hasConfigDir: boolean;
  /** The pid of the session's own claude, for a row with no pane to check. */
  readonly pid: number | null;
  /** $TA_LOG as the hook saw it; null when the row is too short to say. */
  readonly logFile: string | null;
  /** $TA_LABEL, the name the session was started under; null when absent. */
  readonly label: string | null;
  /** The record key of the agent that started this one — a child only. */
  readonly parentKey: string | null;
  /** The session id of that agent, which is the same answer joined on ids. */
  readonly parentSid: string | null;
}

export interface HistoryRow {
  readonly at: number;
  readonly kind: 'start' | 'turn' | 'end';
  readonly sessionId: string;
  readonly pane: string;
  readonly label: string;
  readonly cwd: string;
  /** The session that started this one; '' for everybody but a child. */
  readonly parentSid: string;
}

/** $TA_STATE_DIR wins, exactly as the hook and the dashboard read it. */
export function stateDir(env: NodeJS.ProcessEnv = process.env): string {
  const fromEnv = env['TA_STATE_DIR'];
  return fromEnv && fromEnv.trim() ? fromEnv : path.join(os.homedir(), '.claude', 'agent-state');
}

const KEY_RE = /^(?:\d+|s-[\w.-]+)$/;

export function parseStateLine(key: string, line: string): AgentStateRow | null {
  const f = line.replace(/\n$/, '').split(TAB);
  if (f.length < 6) return null;
  const at = Number(f[0]);
  const state = f[1] ?? '';
  if (!Number.isFinite(at) || !isState(state)) return null;
  const pid = f.length >= 8 ? Number(f[7]) : Number.NaN;
  return {
    key,
    at,
    state,
    sessionId: f[2] ?? '',
    cwd: f[3] ?? '',
    transcript: f[4] ?? '',
    detail: f[5] ?? '',
    configDir: f.length >= 7 ? (f[6] ?? '') : null,
    hasConfigDir: f.length >= 7,
    pid: Number.isInteger(pid) && pid > 0 ? pid : null,
    logFile: f.length >= 9 ? (f[8] ?? '') : null,
    label: f.length >= 10 ? (f[9] ?? '') : null,
    parentKey: f.length >= 11 ? (f[10] ?? '') : null,
    parentSid: f.length >= 12 ? (f[11] ?? '') : null,
  };
}

function isState(s: string): s is SessionState | 'subdone' {
  return s === 'new' || s === 'working' || s === 'blocked' || s === 'done' || s === 'gone' || s === 'subdone';
}

/** Every current record, newest first. Missing directory = no agents. */
export function readAgentState(dir = stateDir()): AgentStateRow[] {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const rows: AgentStateRow[] = [];
  for (const name of names) {
    if (!name.endsWith('.tsv')) continue;
    const key = name.slice(0, -4);
    if (!KEY_RE.test(key)) continue;
    let first: string;
    try {
      first = fs.readFileSync(path.join(dir, name), 'utf8').split('\n')[0] ?? '';
    } catch {
      continue;
    }
    const row = parseStateLine(key, first);
    if (row) rows.push(row);
  }
  return rows.sort((a, b) => b.at - a.at);
}

/** The append-only timeline. TA_LABEL only ever reaches disk through this file. */
export function readHistory(dir = stateDir()): HistoryRow[] {
  let text: string;
  try {
    text = fs.readFileSync(path.join(dir, 'history.tsv'), 'utf8');
  } catch {
    return [];
  }
  const rows: HistoryRow[] = [];
  for (const line of text.split('\n')) {
    if (!line) continue;
    const f = line.split(TAB);
    if (f.length < 6) continue;
    const at = Number(f[0]);
    const kind = f[1] ?? '';
    if (!Number.isFinite(at) || (kind !== 'start' && kind !== 'turn' && kind !== 'end')) continue;
    rows.push({
      at,
      kind,
      sessionId: f[2] ?? '',
      pane: f[3] ?? '',
      label: f[4] ?? '',
      cwd: f[5] ?? '',
      parentSid: f[6] ?? '',
    });
  }
  return rows;
}

/** session id → the label it was started with, latest wins. */
export function labelsBySession(dir = stateDir()): Map<string, string> {
  const m = new Map<string, string>();
  for (const h of readHistory(dir)) if (h.sessionId && h.label) m.set(h.sessionId, h.label);
  return m;
}
