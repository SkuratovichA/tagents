// Is the agent's pane on someone's screen right now, and whose?
//
// One tmux process answers both questions, so the answer is one consistent
// snapshot and the cost is one fork. The notification skips a pane that is
// already in front of the person (`skip_visible`) and a click raises the right
// terminal window, which is what the client pid is for.
import { execText, type Exec } from './exec.ts';

export interface Screen {
  /** Some client's current window is the pane's window. */
  readonly visible: boolean;
  /** The terminal behind the client that shows the pane, else the most recently active client. */
  readonly clientPid?: number;
  readonly paneTitle: string;
}

/** tmux answered, and the pane is not there: a pane closed without a SessionEnd. */
export const NO_SUCH_PANE = 'no-such-pane';

/** null: tmux did not answer (or answered with nothing to read), so nothing is known about the pane. */
export type ScreenProbe = (pane: string) => Promise<Screen | null | typeof NO_SUCH_PANE>;

// The fields are joined with this and never with a tab: a literal tab in a tmux
// format renders as "_" outside a UTF-8 locale, and the LaunchAgent that runs
// this has none, so every field would merge into one (lib/tagents/names.sh:181).
// The title goes last because it is the one field that carries arbitrary text,
// and is rejoined from everything after the second separator.
const SEP = '|@|';
const DIGITS = /^\d+$/;
const NO_PANE_MESSAGE = /can't find pane/;

interface Client {
  readonly activity: number;
  readonly pid: number;
  readonly windowId: string;
}

function mostActive(clients: readonly Client[]): Client | undefined {
  let best: Client | undefined;
  for (const c of clients) if (best === undefined || c.activity > best.activity) best = c;
  return best;
}

/**
 * Parses the output of the probe's tmux command; null when it holds no pane line.
 * tmux 3.7 answers for a pane that does not exist with exit 0 and a pane line
 * whose window id is empty, where older ones fail with "can't find pane": both
 * are NO_SUCH_PANE.
 */
export function parseScreen(out: string): Screen | null | typeof NO_SUCH_PANE {
  let pane: { windowId: string; title: string } | null = null;
  const clients: Client[] = [];
  for (const line of out.split('\n')) {
    const f = line.split(SEP);
    if (f[0] === 'P' && pane === null && f.length >= 3) {
      pane = { windowId: f[1] ?? '', title: f.slice(2).join(SEP) };
    } else if (f[0] === 'C' && f.length === 4) {
      const [, activity = '', pid = '', windowId = ''] = f;
      if (DIGITS.test(activity) && DIGITS.test(pid)) clients.push({ activity: Number(activity), pid: Number(pid), windowId });
    }
  }
  if (pane === null) return null;
  if (pane.windowId === '') return NO_SUCH_PANE;
  const showing = mostActive(clients.filter((c) => c.windowId === pane.windowId));
  const client = showing ?? mostActive(clients);
  return {
    visible: showing !== undefined,
    ...(client !== undefined ? { clientPid: client.pid } : {}),
    paneTitle: pane.title,
  };
}

/** The probe over a real tmux: the pane's window, its title and every client, in one call. */
export function tmuxScreen(exec: Exec = execText): ScreenProbe {
  return async (pane) => {
    try {
      const r = await exec(
        'tmux',
        [
          'display',
          '-p',
          '-t',
          pane,
          `P${SEP}#{window_id}${SEP}#{pane_title}`,
          ';',
          'list-clients',
          '-F',
          `C${SEP}#{client_activity}${SEP}#{client_pid}${SEP}#{window_id}`,
        ],
        { timeoutMs: 2000 }
      );
      if (r.timedOut) return null;
      if (r.code === 0) return parseScreen(r.stdout);
      // Only tmux saying so counts (older tmux): a missing server or a failed spawn says nothing about the pane.
      return NO_PANE_MESSAGE.test(r.stderr) ? NO_SUCH_PANE : null;
    } catch {
      // tmux is not installed or not on this service's PATH: the same as it not answering.
      return null;
    }
  };
}
