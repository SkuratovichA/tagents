// The LaunchAgent that keeps `tagents-notify run` alive, managed with launchctl.
//
// What launchctl prints and returns for the cases below was captured on a real
// Mac (see test/fixtures/launchctl-*.txt): `bootout` of a label that is not
// loaded exits 3 with "Boot-out failed: 3: No such process", and `print` of one
// exits 113 with "Could not find service". A bootstrap right after a bootout can
// fail with "5: Input/output error" while the old process is still exiting, so
// it is retried; the timers outside `clock.ts` are this retry delay and the settle wait of `install` in `plugin.ts`.
// The three launchctl-print-disabled*.txt fixtures are not captures: they use the
// format `print-disabled` prints on macOS 13+ (and, in the legacy one, the `=> true`
// spelling of older systems) with made-up labels.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { writeAtomic } from '@tagents/core';
import { execText, type Exec } from '../../exec.ts';
import type { RunSpec, ServiceManager, ServiceStatus } from '../../notifier.ts';
import { BUNDLE_ID, plistPath as defaultPlistPath } from '../../paths.ts';

const LAUNCHCTL = '/bin/launchctl';
const PLUTIL = '/usr/bin/plutil';
const TIMEOUT_MS = 15_000;
const BOOTSTRAP_ATTEMPTS = 3;
const BOOTSTRAP_RETRY_MS = 1000;

function esc(s: string): string {
  return s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

// ThrottleInterval is the least time launchd leaves between two starts of the job, counted from the last start: a crash
// after a long run restarts at once, a crash loop at most every 5 minutes. `run` exits 1 only when it fails to start,
// and 0 when it deliberately does not run, which `SuccessfulExit: false` never restarts.
export function renderPlist(run: RunSpec, label: string = BUNDLE_ID, associatedId: string = BUNDLE_ID): string {
  const env = Object.entries(run.env)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([k, v]) => `    <key>${esc(k)}</key>\n    <string>${esc(v)}</string>`)
    .join('\n');
  const argv = [run.program, ...run.args].map((a) => `    <string>${esc(a)}</string>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${esc(label)}</string>
  <key>ProgramArguments</key>
  <array>
${argv}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
${env}
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>300</integer>
  <key>StandardOutPath</key>
  <string>${esc(run.logFile)}</string>
  <key>StandardErrorPath</key>
  <string>${esc(run.logFile)}</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>${esc(associatedId)}</string>
  </array>
</dict>
</plist>
`;
}

/** The top-level fields of `launchctl print gui/<uid>/<label>`: they sit one tab deep, nested ones deeper. */
export function parsePrint(out: string): {
  readonly running: boolean;
  readonly pid?: number;
  readonly state?: string;
  readonly lastExit?: string;
} {
  const field = (name: string): string | undefined => {
    const m = new RegExp(`^\\t${name} = (.*)$`, 'm').exec(out);
    return m?.[1]?.trim();
  };
  const state = field('state');
  const pidText = field('pid');
  const pid = pidText !== undefined && /^\d+$/.test(pidText) ? Number(pidText) : undefined;
  const lastExit = field('last exit code');
  return {
    running: state === 'running',
    ...(pid !== undefined ? { pid } : {}),
    ...(state !== undefined ? { state } : {}),
    ...(lastExit !== undefined ? { lastExit } : {}),
  };
}

/**
 * Whether `launchctl print-disabled gui/<uid>` lists the label as switched off: `"<label>" => disabled`, or
 * `=> true` on older systems. A label that is not listed is on.
 */
function listedDisabled(out: string, label: string): boolean {
  for (const line of out.split('\n')) {
    const m = /^\s*"([^"]+)"\s*=>\s*(\S+)\s*$/.exec(line);
    if (m?.[1] === label) return m[2] === 'disabled' || m[2] === 'true';
  }
  return false;
}

function notLoaded(r: { code: number | null; stdout: string; stderr: string }): boolean {
  return r.code === 3 || /No such process|Could not find service/.test(r.stderr + r.stdout);
}

export function createLaunchd(
  o: {
    readonly uid?: number;
    readonly home?: string;
    readonly exec?: Exec;
    readonly label?: string;
    readonly plist?: string;
    /** The helper app's path: its built CFBundleIdentifier is what the plist associates the job with; unset: the base id. */
    readonly app?: string;
    /** The wait between bootstrap attempts; tests pass 0. */
    readonly retryDelayMs?: number;
  } = {}
): ServiceManager {
  const exec = o.exec ?? execText;
  const uid = o.uid ?? process.getuid?.() ?? 0;
  const label = o.label ?? BUNDLE_ID;
  const retryDelayMs = o.retryDelayMs ?? BOOTSTRAP_RETRY_MS;
  const plist = o.plist ?? defaultPlistPath(o.home ?? os.homedir());
  const domain = `gui/${uid}`;
  const target = `${domain}/${label}`;

  // build.sh gives an app built with an icon an id of its own, so the built Info.plist is the one source of it.
  async function appId(): Promise<string> {
    if (o.app === undefined) return BUNDLE_ID;
    try {
      const r = await exec(PLUTIL, ['-extract', 'CFBundleIdentifier', 'raw', path.join(o.app, 'Contents', 'Info.plist')], {
        timeoutMs: TIMEOUT_MS,
      });
      const id = r.stdout.trim();
      return r.code === 0 && id !== '' ? id : BUNDLE_ID;
    } catch {
      return BUNDLE_ID;
    }
  }

  async function bootout(): Promise<void> {
    const r = await exec(LAUNCHCTL, ['bootout', target], { timeoutMs: TIMEOUT_MS });
    if (r.code !== 0 && !notLoaded(r)) {
      throw new Error(`launchctl bootout failed: ${(r.stderr || r.stdout).trim()}`);
    }
  }

  // A label switched off with `launchctl disable` (or in Login Items) fails to bootstrap with the same
  // "5: Input/output error" as the transient failure, so the text cannot tell the two apart: ask launchd.
  // The question only picks the hint, so a failure to ask must not hide the bootstrap error.
  async function switchedOff(): Promise<boolean> {
    try {
      const r = await exec(LAUNCHCTL, ['print-disabled', domain], { timeoutMs: TIMEOUT_MS });
      return r.code === 0 && listedDisabled(r.stdout, label);
    } catch {
      return false;
    }
  }

  return {
    async install(run) {
      fs.mkdirSync(path.dirname(plist), { recursive: true });
      fs.mkdirSync(path.dirname(run.logFile), { recursive: true });
      await bootout();
      writeAtomic(plist, renderPlist(run, label, await appId()));
      let last = '';
      for (let attempt = 1; attempt <= BOOTSTRAP_ATTEMPTS; attempt++) {
        const r = await exec(LAUNCHCTL, ['bootstrap', domain, plist], { timeoutMs: TIMEOUT_MS });
        if (r.code === 0) return;
        last = (r.stderr || r.stdout).trim();
        const retryable = /Input\/output error/.test(last);
        if (!retryable || attempt === BOOTSTRAP_ATTEMPTS) break;
        await delay(retryDelayMs);
      }
      const hint = (await switchedOff())
        ? `The agent is switched off. Switch it on with: launchctl enable ${target} (or in System Settings, General, Login Items)`
        : `Check the file with: plutil -lint ${plist}`;
      throw new Error(`launchctl bootstrap failed: ${last}\n${hint}`);
    },

    async uninstall() {
      await bootout();
      try {
        fs.unlinkSync(plist);
      } catch (e) {
        if (!(e instanceof Error && 'code' in e && e.code === 'ENOENT')) throw e;
      }
    },

    async status(): Promise<ServiceStatus> {
      const installed = fs.existsSync(plist);
      const r = await exec(LAUNCHCTL, ['print', target], { timeoutMs: TIMEOUT_MS });
      if (r.code !== 0) {
        return { installed, running: false, detail: installed ? 'installed, not loaded' : 'not installed' };
      }
      const p = parsePrint(r.stdout);
      const detail = p.running
        ? `loaded, running${p.pid !== undefined ? `, pid ${p.pid}` : ''}`
        : `loaded, not running (last exit ${p.lastExit ?? 'unknown'})`;
      return { installed, running: p.running, ...(p.pid !== undefined ? { pid: p.pid } : {}), detail };
    },
  };
}
