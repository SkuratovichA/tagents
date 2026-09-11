// What was I working on, across every Claude project on this machine?
//
// A port of orchestrator/src/sessions.mjs. It reads the session transcripts
// every Claude account keeps on disk (~/.claude/projects/<slug>/<id>.jsonl,
// plus ~/.claude-<name>/projects/ for each additional account or
// client-specific config dir) and answers the three questions callers ask:
//
//   recent [N]        latest sessions, newest first (default 15)
//   search <words…>   find sessions by opening prompt / project
//   show <id-prefix>  one session: opening prompt + last replies
//
// READING STRATEGY MATTERS: transcripts run to megabytes, so this never reads
// one whole. The opening human prompt lives in the first ~64 KB; the latest
// assistant text lives in the last ~48 KB. Head + tail covers both questions,
// and the windows are part of the contract — widening them turns a listing of
// 400 sessions into hundreds of megabytes of reads.
//
// The rendered text is ALSO a contract: an agent reads it out of a shell and
// paraphrases it, so column widths, the `~`-folded project path, the
// `01-02 03:04` timestamp shape and the trailer line are pinned by fixtures
// carried over from the orchestrator (test/fixtures/sessions/*). That is why
// the trailer still names sessions.mjs: parity is the point of this port, and
// the day the wording changes both sides change together.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/** The name the rendered text refers callers to. Part of the pinned output. */
export const SESSIONS_PROGRAM = 'sessions.mjs';

export const HEAD_WINDOW_BYTES = 65536;
export const TAIL_WINDOW_BYTES = 49152;
/** Empty shells and aborted starts: not worth listing. */
export const MIN_TRANSCRIPT_BYTES = 2000;
/** How deep `search` looks before giving up. */
export const SEARCH_SCAN = 400;
export const SEARCH_HITS = 12;

export interface Account {
  readonly name: string;
  /** The projects/ directory, not the config dir itself. */
  readonly dir: string;
}

export interface SessionRow {
  readonly id: string;
  readonly account: string;
  readonly project: string;
  readonly file: string;
  readonly mtime: Date;
  readonly size: number;
}

/**
 * Every Claude config dir on this machine: ~/.claude and any ~/.claude-<name>.
 * CLAUDE_HOMES=dir1,dir2 overrides the discovery (and is how the tests stay
 * hermetic). Re-read on every call rather than frozen at import time, because
 * a library is loaded once and asked many times, under changing environments.
 */
export function discoverAccounts(): Account[] {
  const home = os.homedir();
  const homes = process.env.CLAUDE_HOMES;
  let dirs: string[];
  if (homes) {
    dirs = homes.split(',').map((d) => d.trim()).filter(Boolean);
  } else {
    try {
      dirs = fs
        .readdirSync(home)
        .filter((d) => /^\.claude(-[\w.-]+)?$/.test(d))
        .map((d) => path.join(home, d));
    } catch {
      dirs = [];
    }
  }
  return dirs
    .map((dir) => ({
      name: path.basename(dir) === '.claude' ? 'personal' : path.basename(dir).replace(/^\.claude-/, ''),
      dir: path.join(dir, 'projects'),
    }))
    .filter((a) => fs.existsSync(a.dir));
}

/** Read one window of a file without loading the rest of it. */
function slice(file: string, from: 'head' | 'tail', len: number): string {
  const size = fs.statSync(file).size;
  const start = from === 'head' ? 0 : Math.max(0, size - len);
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.alloc(Math.min(len, size));
  let n: number;
  try {
    n = fs.readSync(fd, buf, 0, buf.length, start);
  } finally {
    fs.closeSync(fd);
  }
  const s = buf.subarray(0, n).toString('utf8');
  // A tail window starts mid-line: drop the fragment.
  return start ? s.slice(s.indexOf('\n') + 1) : s;
}

/** The first real human prompt: what the session was opened to do. */
export function firstPrompt(file: string): string {
  for (const line of slice(file, 'head', HEAD_WINDOW_BYTES).split('\n')) {
    if (!line || line.indexOf('"user"') === -1) continue;
    let d: unknown;
    try {
      d = JSON.parse(line);
    } catch {
      continue;
    }
    const rec = asRecord(d);
    if (!rec || rec['type'] !== 'user' || rec['isMeta']) continue;
    const c = messageContent(rec);
    if (typeof c === 'string' && c.trim() && !c.startsWith('<')) return c.trim();
  }
  return '';
}

/** The last assistant text block inside the tail window ('' when there is none). */
export function lastAssistantText(file: string): string {
  let text = '';
  for (const line of slice(file, 'tail', TAIL_WINDOW_BYTES).split('\n')) {
    if (!line || line.indexOf('"assistant"') === -1) continue;
    let d: unknown;
    try {
      d = JSON.parse(line);
    } catch {
      continue;
    }
    const rec = asRecord(d);
    if (!rec || rec['type'] !== 'assistant') continue;
    const c = messageContent(rec);
    if (!Array.isArray(c)) continue;
    for (const b of c) {
      const block = asRecord(b);
      const t = block?.['text'];
      if (block?.['type'] === 'text' && typeof t === 'string' && t.trim()) text = t.trim();
    }
  }
  return text;
}

/** The last assistant reply plus when the transcript was last written. */
export function lastAssistant(file: string): { text: string; at: number } | null {
  let at: number;
  try {
    at = fs.statSync(file).mtimeMs;
  } catch {
    return null;
  }
  const text = lastAssistantText(file);
  return text ? { text, at } : null;
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null ? (v as Record<string, unknown>) : null;
}

function messageContent(rec: Record<string, unknown>): unknown {
  const message = asRecord(rec['message']);
  return message ? message['content'] : undefined;
}

/**
 * Claude names a project dir after the absolute cwd with '/' → '-':
 * '<home encoded>-git-work-x' → '~/git/work/x'. Lossy (a '-' inside a segment
 * also becomes '/'), which is fine for a listing and is what the fixtures pin.
 */
export function decodeProjectSlug(slug: string, home = os.homedir()): string {
  const enc = home.replace(/\//g, '-');
  return slug.startsWith(enc) ? '~' + slug.slice(enc.length).replace(/-/g, '/') : slug.replace(/-/g, '/');
}

/** Every transcript worth listing, newest first. */
export function collect(): SessionRow[] {
  const rows: SessionRow[] = [];
  const home = os.homedir();
  for (const acct of discoverAccounts()) {
    let projects: string[];
    try {
      projects = fs.readdirSync(acct.dir);
    } catch {
      continue;
    }
    for (const proj of projects) {
      const dir = path.join(acct.dir, proj);
      let entries: fs.Dirent[];
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        continue;
      }
      for (const e of entries) {
        if (!e.isFile() || !e.name.endsWith('.jsonl')) continue;
        const file = path.join(dir, e.name);
        let st: fs.Stats;
        try {
          st = fs.statSync(file);
        } catch {
          continue; // a session that ended between readdir and stat
        }
        if (st.size < MIN_TRANSCRIPT_BYTES) continue;
        rows.push({
          id: e.name.slice(0, -6),
          account: acct.name,
          project: decodeProjectSlug(proj, home),
          file,
          mtime: st.mtime,
          size: st.size,
        });
      }
    }
  }
  return rows.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
}

/** Find one session by id prefix, newest first. */
export function findByPrefix(prefix: string): SessionRow | undefined {
  return collect().find((x) => x.id.startsWith(prefix));
}

const fmtWhen = (d: Date): string =>
  d.toISOString().slice(5, 16).replace('T', ' ') +
  (Date.now() - d.getTime() < 86400e3 ? ' (today/yday)' : '');

const oneLine = (s: string, n: number): string => s.replace(/\s+/g, ' ').slice(0, n);

const twoLines = (r: SessionRow, prompt: string): string =>
  `${r.id.slice(0, 8)}  ${fmtWhen(r.mtime).padEnd(18)} ${r.account.padEnd(8)} ${r.project}\n` +
  `          ${oneLine(prompt, 150)}\n`;

/** `recent [N]` — exactly what sessions.mjs prints on stdout. */
export function renderRecent(n = 15): string {
  let out = '';
  for (const r of collect().slice(0, n)) out += twoLines(r, firstPrompt(r.file) || '(no opening prompt)');
  return `${out}\nfull text of one: ${SESSIONS_PROGRAM} show <id-prefix>\n`;
}

/** `search <words…>` — all words must appear in project path + opening prompt. */
export function renderSearch(words: readonly string[]): string {
  const q = words.join(' ').toLowerCase();
  const needles = q.split(/\s+/);
  let out = '';
  let hits = 0;
  for (const r of collect().slice(0, SEARCH_SCAN)) {
    const prompt = firstPrompt(r.file);
    const hay = (r.project + ' ' + prompt).toLowerCase();
    if (!needles.every((w) => hay.includes(w))) continue;
    hits++;
    out += twoLines(r, prompt);
    if (hits >= SEARCH_HITS) break;
  }
  if (!hits) return `nothing matches "${q}" in the last ${SEARCH_SCAN} sessions' opening prompts\n`;
  return out;
}

/** `show <id-prefix>` — null when no session starts with that prefix. */
export function renderShow(prefix: string): string | null {
  const r = findByPrefix(prefix);
  if (!r) return null;
  return (
    `session ${r.id}\naccount ${r.account} · project ${r.project} · last activity ${r.mtime.toISOString()}\n\n` +
    `── opening prompt ──\n` +
    `${oneLine(firstPrompt(r.file) || '(none)', 1500)}\n` +
    `\n── last assistant reply (tail) ──\n` +
    `${oneLine(lastAssistantText(r.file) || '(none in tail window)', 1500)}\n`
  );
}
