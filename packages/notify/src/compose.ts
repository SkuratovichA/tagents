// What a notice says: whose it is, what happened, and the one line that tells
// you whether to go and look.
import path from 'node:path';
import { lastAssistantText, type AgentEvent } from '@tagents/core';
import type { NoticeKind } from './kinds.ts';
import { currentPhrases, type Phrases } from './phrases.ts';

const BODY_CLIP = 200;

/**
 * The pane title without the status glyph Claude Code puts in front of it: the
 * TypeScript copy of `untitle_of` (lib/tagents/names.sh:41). A glyph is exactly
 * one code point that is no ASCII letter or digit and is followed by a space;
 * anything else is left alone, so `Data service architecture` keeps all three
 * words. The test runs the shell function on the same inputs and compares.
 */
export function untitle(title: string): string {
  const space = title.indexOf(' ');
  if (space < 1) return title;
  const first = title.slice(0, space);
  if ([...first].length !== 1 || /^[0-9A-Za-z]$/.test(first)) return title;
  return title.replace(/^[^ ]+ +/, '');
}

/**
 * The name the dashboard shows for this agent, in the dashboard's order
 * (`nameof`, lib/tagents/list.sh:351): the name typed on ctrl-r for the session,
 * else for the pane, else the pane title without its glyph; a headless session
 * has no title, so its TA_LABEL; and the directory's name when that is still
 * empty or is only the machine's hostname, which is what a terminal that was
 * never given a title shows.
 */
export function agentName(o: {
  readonly sessionId: string;
  readonly pane: string;
  readonly paneTitle: string;
  readonly label: string;
  readonly cwd: string;
  readonly hostname: string;
  readonly labels: ReadonlyMap<string, string>;
}): string {
  const bySession = o.sessionId === '' ? undefined : o.labels.get(o.sessionId);
  const byPane = o.pane === '' ? undefined : o.labels.get(o.pane);
  let name = bySession ?? byPane ?? untitle(o.paneTitle);
  if (name === '') name = o.label;
  // The dashboard compares with `hostname -s`.
  if (name === '' || name === o.hostname || name === o.hostname.split('.')[0]) name = path.basename(o.cwd);
  return name;
}

function clip(text: string, max: number): string {
  const chars = [...text];
  return chars.length <= max ? text : `${chars.slice(0, max - 1).join('')}…`;
}

// core's lastAssistantText gives '' for a transcript with no answer in its tail,
// but stats the file first and throws when there is no file at all. A transcript
// that was deleted or moved while a notice was being composed is an ordinary
// event, and the notice is worth posting without its first line.
function lastAnswer(file: string): string {
  try {
    return lastAssistantText(file);
  } catch {
    return '';
  }
}

function firstLine(text: string): string {
  for (const line of text.split('\n')) if (line.trim() !== '') return line.trim();
  return '';
}

function subtitleFor(kind: NoticeKind, plan: boolean, p: Phrases): string {
  switch (kind) {
    case 'question':
      return plan ? p.kindPlan : p.kindQuestion;
    case 'permission':
      return p.kindPermission;
    case 'turn_done':
      return p.kindTurnDone;
    case 'cache_expiring':
      return p.kindCacheExpiring;
    case 'subagent_done':
      return p.kindSubagentDone;
    case 'session_end':
      return p.kindSessionEnd;
  }
}

function bodyFor(
  kind: NoticeKind,
  e: AgentEvent,
  extra: { readonly idleMin?: number; readonly leftMin?: number },
  p: Phrases
): string {
  switch (kind) {
    case 'question':
      return e.text !== '' ? e.text : p.questionBody;
    case 'permission':
      return e.text !== '' ? e.text : p.permissionBody;
    case 'turn_done': {
      // The event's own text comes first: Claude Code runs the Stop hook before it
      // writes the final assistant record, so the transcript's last answer at that
      // moment can be an older one.
      if (e.text !== '') return clip(e.text, BODY_CLIP);
      const line = e.transcript === '' ? '' : firstLine(lastAnswer(e.transcript));
      return line === '' ? p.turnDoneBody : clip(line, BODY_CLIP);
    }
    case 'cache_expiring':
      return p.cacheBody(extra.idleMin ?? 0, extra.leftMin ?? 0);
    case 'subagent_done':
      // SubagentStop's `sub` is the agent type; a hook that did not report one
      // would otherwise read "finished finished", and the subtitle already says
      // "Subagent finished".
      return e.sub === '' ? p.subagentUnnamedBody : p.subagentBody(e.sub);
    case 'session_end':
      return e.sub !== '' ? e.sub : p.sessionEndBody;
  }
}

/**
 * Title, subtitle and body of one notice. `name` is already resolved (see
 * `agentName`); the subtitle names the project too unless the name already is it.
 */
export function compose(
  kind: NoticeKind,
  e: AgentEvent,
  name: string,
  extra: { readonly plan?: boolean; readonly idleMin?: number; readonly leftMin?: number },
  p: Phrases = currentPhrases()
): { title: string; subtitle: string; body: string } {
  const project = e.cwd === '' ? '' : path.basename(e.cwd);
  const phrase = subtitleFor(kind, extra.plan === true, p);
  return {
    title: name,
    subtitle: project !== '' && project !== name ? `${phrase} · ${project}` : phrase,
    body: bodyFor(kind, e, extra, p),
  };
}
