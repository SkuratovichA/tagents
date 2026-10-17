// The LaunchAgent that keeps `tagents-notify run` alive, managed with launchctl.
//
// What launchctl prints and returns for the cases below was captured on a real
// Mac (see test/fixtures/launchctl-*.txt): `bootout` of a label that is not
// loaded exits 3 with "Boot-out failed: 3: No such process", and `print` of one
// exits 113 with "Could not find service". A bootstrap right after a bootout can
// fail with "5: Input/output error" while the old process is still exiting, so
// it is retried; this file is the one place besides `clock.ts` with a timer.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { writeAtomic } from '@tagents/core';
import { execText, type Exec } from '../../exec.ts';
import type { RunSpec, ServiceManager, ServiceStatus } from '../../notifier.ts';
import { LAUNCHD_LABEL, plistPath as defaultPlistPath } from '../../paths.ts';

const LAUNCHCTL = '/bin/launchctl';
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

export function renderPlist(run: RunSpec, label: string = LAUNCHD_LABEL): string {
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
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>${esc(run.logFile)}</string>
  <key>StandardErrorPath</key>
  <string>${esc(run.logFile)}</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>io.github.skuratovicha.tagents-notify</string>
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
  } = {}
): ServiceManager {
  const exec = o.exec ?? execText;
  const uid = o.uid ?? process.getuid?.() ?? 0;
  const label = o.label ?? LAUNCHD_LABEL;
  const plist = o.plist ?? defaultPlistPath(o.home ?? os.homedir());
  const domain = `gui/${uid}`;
  const target = `${domain}/${label}`;

  async function bootout(): Promise<void> {
    const r = await exec(LAUNCHCTL, ['bootout', target], { timeoutMs: TIMEOUT_MS });
    if (r.code !== 0 && !notLoaded(r)) {
      throw new Error(`launchctl bootout failed: ${(r.stderr || r.stdout).trim()}`);
    }
  }

  return {
    async install(run) {
      fs.mkdirSync(path.dirname(plist), { recursive: true });
      fs.mkdirSync(path.dirname(run.logFile), { recursive: true });
      await bootout();
      writeAtomic(plist, renderPlist(run, label));
      let last = '';
      for (let attempt = 1; attempt <= BOOTSTRAP_ATTEMPTS; attempt++) {
        const r = await exec(LAUNCHCTL, ['bootstrap', domain, plist], { timeoutMs: TIMEOUT_MS });
        if (r.code === 0) return;
        last = (r.stderr || r.stdout).trim();
        const retryable = /Input\/output error/.test(last);
        if (!retryable || attempt === BOOTSTRAP_ATTEMPTS) break;
        await delay(BOOTSTRAP_RETRY_MS);
      }
      throw new Error(`launchctl bootstrap failed: ${last}\nCheck the file with: plutil -lint ${plist}`);
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
