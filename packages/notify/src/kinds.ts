// What an agent event means to a person: which kind of notice it asks for, and
// what else it does to the session's notice and cache deadline.
import type { AgentEvent } from '@tagents/core';

export type NoticeKind =
  | 'question'
  | 'permission'
  | 'turn_done'
  | 'cache_expiring'
  | 'subagent_done'
  | 'session_end';

export interface Verdict {
  /** The notice this event asks for, before the options decide whether it is wanted. */
  readonly kind: NoticeKind | null;
  /** A question that is a plan waiting for approval, which has a subtitle of its own. */
  readonly plan: boolean;
  /** The session is waiting on the person now: the prompt cache's clock started. */
  readonly arms: boolean;
  /** The notice this session has up is stale. */
  readonly withdraw: boolean;
  /** The session is working again or gone: no cache deadline applies. */
  readonly cancel: boolean;
}

// An idle prompt and "waiting for your input" are what Claude Code says about
// 60 seconds after a Stop, and Stop already told the person.
const WAITING = /waiting for your input/i;

const NOTHING: Verdict = { kind: null, plan: false, arms: false, withdraw: false, cancel: false };

const asks = (kind: NoticeKind, over: Partial<Verdict> = {}): Verdict => ({ ...NOTHING, kind, ...over });

/** The tools whose PreToolUse is a question put to the person, and whose PostToolUse is the answer. */
export const QUESTION_TOOLS = ['AskUserQuestion', 'ExitPlanMode'] as const;

const isQuestionTool = (tool: string): boolean => (QUESTION_TOOLS as readonly string[]).includes(tool);

/** A session with no tmux pane (`s-<id>`: `claude -p` from a daemon, an IDE) is only counted when asked for. */
export function countsSession(key: string, headless: boolean): boolean {
  return headless || !key.startsWith('s-');
}

function fromNotification(e: AgentEvent): Verdict | null {
  if (e.sub === 'elicitation_dialog') return asks('question', { arms: true });
  if (e.sub === 'permission_prompt') return asks('permission', { arms: true });
  if (e.sub === 'idle_prompt' || e.sub === 'auth_success' || WAITING.test(e.text)) return null;
  // A subtype this code has not met, with words to show: Claude Code adds
  // notification types over time, and a prompt for the person is the likelier
  // reading than silence.
  return e.text.trim() === '' ? null : asks('permission', { arms: true });
}

/** The verdict on one event, or null when it is nothing to notify and nothing to track. */
export function classify(e: AgentEvent, o: { readonly headless: boolean }): Verdict | null {
  if (!countsSession(e.key, o.headless)) return null;
  switch (e.event) {
    case 'PreToolUse':
      return isQuestionTool(e.tool) ? asks('question', { arms: true, plan: e.tool === 'ExitPlanMode' }) : null;
    case 'PostToolUse':
      // The person answered the question or the plan: the session works again.
      return isQuestionTool(e.tool) ? { ...NOTHING, withdraw: true, cancel: true } : null;
    case 'Notification':
      return fromNotification(e);
    case 'Stop':
      // A Stop with an agent id is a subagent's own turn ending, which
      // SubagentStop reports separately.
      return e.agentId === '' ? asks('turn_done', { arms: true }) : null;
    case 'SubagentStop':
      return asks('subagent_done');
    case 'SessionEnd':
      return asks('session_end', { withdraw: true, cancel: true });
    case 'UserPromptSubmit':
      return { ...NOTHING, withdraw: true, cancel: true };
    case 'SessionStart':
      // A new session in the pane makes whatever the old one asked moot.
      return { ...NOTHING, withdraw: true, cancel: true };
  }
}
