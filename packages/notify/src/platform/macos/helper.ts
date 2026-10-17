// The macOS helper app, driven one verb per process.
//
// The binary posts, withdraws and reports and then exits, so no helper process
// exists while idle. Every verb prints one JSON line; `runHelper` is the only
// place that parses it and the only place that turns a failure into an Error,
// so a caller sees `ok:true` as a parsed object and everything else as a
// rejection with a sentence a person can act on.
import path from 'node:path';
import { z } from 'zod';
import { execText, type Exec } from '../../exec.ts';
import type { Notice, Notifier, PostResult } from '../../notifier.ts';

export const HELPER_TIMEOUT_MS = 5000;
/** The helper waits 60 s for the person to answer the macOS prompt. */
export const AUTHORIZE_TIMEOUT_MS = 65_000;

export function helperBinary(app: string): string {
  return path.join(app, 'Contents', 'MacOS', 'tagents-notify');
}

const Line = z.looseObject({
  ok: z.boolean(),
  error: z.string().optional(),
  shown: z.boolean().optional(),
  why: z.string().optional(),
  status: z.string().optional(),
  alertStyle: z.string().optional(),
  ids: z.array(z.string()).optional(),
});
type HelperLine = z.infer<typeof Line>;

async function runHelper(
  app: string,
  args: readonly string[],
  o: { readonly input?: string; readonly timeoutMs: number },
  exec: Exec
): Promise<HelperLine> {
  const bin = helperBinary(app);
  let r;
  try {
    r = await exec(bin, args, o);
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    throw new Error(
      `cannot start the notification helper at ${app} (${why}); run \`tagents notify install\``
    );
  }
  if (r.timedOut) {
    throw new Error(`the notification helper timed out after ${o.timeoutMs / 1000} s`);
  }
  let parsed: HelperLine | null = null;
  try {
    const p = Line.safeParse(JSON.parse(r.stdout.trim()));
    parsed = p.success ? p.data : null;
  } catch {
    parsed = null;
  }
  if (parsed === null) {
    throw new Error(
      `unreadable output from the notification helper: stdout ${JSON.stringify(r.stdout.slice(0, 200))}, stderr ${JSON.stringify(r.stderr.slice(0, 200))}`
    );
  }
  if (!parsed.ok) throw new Error(parsed.error ?? 'the notification helper failed');
  return parsed;
}

export function createHelperNotifier(o: { readonly app: string; readonly exec?: Exec }): Notifier {
  const exec = o.exec ?? execText;
  return {
    name: 'macos',
    async post(n: Notice): Promise<PostResult> {
      const r = await runHelper(
        o.app,
        ['post'],
        { input: JSON.stringify(n), timeoutMs: HELPER_TIMEOUT_MS },
        exec
      );
      return { shown: r.shown ?? false, ...(r.why !== undefined ? { why: r.why } : {}) };
    },
    async withdraw(id) {
      await runHelper(o.app, ['withdraw', id], { timeoutMs: HELPER_TIMEOUT_MS }, exec);
    },
  };
}

export async function helperStatus(
  app: string,
  exec: Exec = execText
): Promise<{ readonly status: string; readonly alertStyle: string }> {
  const r = await runHelper(app, ['status'], { timeoutMs: HELPER_TIMEOUT_MS }, exec);
  return { status: r.status ?? 'unknown', alertStyle: r.alertStyle ?? 'unknown' };
}

/** Shows the macOS prompt when permission is undetermined; resolves with the status after the answer. */
export async function helperAuthorize(app: string, exec: Exec = execText): Promise<string> {
  const r = await runHelper(app, ['authorize'], { timeoutMs: AUTHORIZE_TIMEOUT_MS }, exec);
  return r.status ?? 'unknown';
}

export async function helperDelivered(
  app: string,
  exec: Exec = execText
): Promise<readonly string[]> {
  const r = await runHelper(app, ['delivered'], { timeoutMs: HELPER_TIMEOUT_MS }, exec);
  return r.ids ?? [];
}
