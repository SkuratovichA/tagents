// A notice made from an event, and the click that goes with it: what the `send` and `test` verbs show. The service that followed the event stream is the Rust binary's (`tagents-core notify run`).
import { readLabels, type AgentEvent, type AgentStateRow } from '@tagents/core';
import { describe } from './errors.ts';
import { agentName, compose } from './compose.ts';
import type { NoticeKind } from './kinds.ts';
import type { ClickAction, Notice } from './notifier.ts';
import type { NotifyOptions } from './options.ts';
import { NO_SUCH_PANE, type Screen, type ScreenProbe } from './screen.ts';

// What a click needs to find the same tmux server, state and config the service
// was started with: a click runs under the notification center, not under this
// process, so it inherits none of it. Nothing else is passed on. The locale is
// on the list because tmux renders non-ASCII as `_` outside a UTF-8 one, and an
// agent's name is often not ASCII. The config is three variables because
// lib/tagents/config.sh looks for it in TA_CONFIG, then XDG_CONFIG_HOME, and
// the dashboard has the same ones.
const CLICK_ENV = [
  'PATH',
  'HOME',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'TMUX_TMPDIR',
  'TA_STATE_DIR',
  'TAGENTS_CONFIG_DIR',
  'XDG_CONFIG_HOME',
  'TA_CONFIG',
] as const;

function clickEnv(env: NodeJS.ProcessEnv): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of CLICK_ENV) {
    const v = env[k];
    if (v !== undefined && v !== '') out[k] = v;
  }
  return out;
}

export function clickFor(e: AgentEvent, mode: NotifyOptions['click'], tagents: string, env: NodeJS.ProcessEnv): ClickAction {
  const clickEnvOf = clickEnv(env);
  // No pane, nothing to dock or go to: the click only raises the terminal.
  if (e.pane === '' || mode === 'focus') return { argv: [], env: clickEnvOf };
  if (mode === 'goto') return { argv: [tagents, '--goto', e.pane], env: clickEnvOf };
  return { argv: [tagents, '--act', 'open', e.pane, 'live', e.sessionId, e.cwd], env: clickEnvOf };
}

export interface NoticeDeps {
  readonly screen: ScreenProbe;
  /** Where the session labels live: the feed's directory. */
  readonly labelsDir: string;
  readonly tagents: string;
  readonly hostname: () => string;
  readonly env: NodeJS.ProcessEnv;
  readonly log: (...parts: string[]) => void;
}

async function probe(pane: string, d: NoticeDeps): Promise<Screen | null | typeof NO_SUCH_PANE> {
  if (pane === '') return null;
  try {
    return await d.screen(pane);
  } catch (err) {
    // Losing the click's terminal is cheaper than losing the notice.
    d.log('screen probe failed', pane, describe(err));
    return null;
  }
}

/**
 * The id a notice goes up under; a notice with the same id replaces the one on
 * screen, so an agent has one notice at a time, saying the latest thing.
 */
export function noticeId(key: string): string {
  return `tagents-${key}`;
}

function assemble(
  kind: NoticeKind,
  e: AgentEvent,
  extra: { readonly plan?: boolean; readonly idleMin?: number; readonly leftMin?: number },
  o: { readonly skipVisible: boolean; readonly click: NotifyOptions['click'] },
  d: NoticeDeps,
  screen: Screen | null
): Notice {
  const name = agentName({
    sessionId: e.sessionId,
    pane: e.pane,
    paneTitle: screen?.paneTitle ?? '',
    label: e.label,
    cwd: e.cwd,
    hostname: d.hostname(),
    labels: readLabels(d.labelsDir),
  });
  return {
    id: noticeId(e.key),
    thread: e.sessionId,
    kind,
    ...compose(kind, e, name, extra),
    click: clickFor(e, o.click, d.tagents, d.env),
    ...(screen?.clientPid !== undefined ? { terminalPid: screen.clientPid } : {}),
    ...(o.skipVisible && screen?.visible === true ? { skipIfFrontmost: true } : {}),
  };
}

/** The one place a Notice is assembled: the `send` and `test` verbs show it. */
export async function buildNotice(
  kind: NoticeKind,
  e: AgentEvent,
  extra: { readonly plan?: boolean; readonly idleMin?: number; readonly leftMin?: number },
  o: { readonly skipVisible: boolean; readonly click: NotifyOptions['click'] },
  d: NoticeDeps
): Promise<Notice> {
  const seen = await probe(e.pane, d);
  return assemble(kind, e, extra, o, d, seen === NO_SUCH_PANE ? null : seen);
}

// The state row carries what an event would: enough to compose the notice and
// to click through to the right pane. Its `at` is epoch seconds, while an
// event's is milliseconds (the hook writes seconds and the parser multiplies).
export function eventFromRow(row: AgentStateRow, labels: ReadonlyMap<string, string>): AgentEvent {
  return {
    at: row.at * 1000,
    event: row.state === 'blocked' ? 'Notification' : 'Stop',
    key: row.key,
    sessionId: row.sessionId,
    agentId: '',
    pane: /^\d+$/.test(row.key) ? `%${row.key}` : '',
    cwd: row.cwd,
    transcript: row.transcript,
    configDir: row.configDir ?? '',
    tool: '',
    sub: '',
    text: row.detail,
    label: labels.get(row.sessionId) ?? '',
  };
}
