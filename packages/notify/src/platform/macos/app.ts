// The helper app's build state, through the build script that owns the hash.
//
// Running the script through `/bin/sh` means its executable bit does not matter
// on a fresh checkout.
import { execText, type Exec } from '../../exec.ts';
import { BUILD_SCRIPT } from '../../paths.ts';

export type AppState = 'up to date' | 'stale' | 'missing';

const CHECK_TIMEOUT_MS = 10_000;
const BUILD_TIMEOUT_MS = 300_000;

// `icon` is the PNG the app's icon is made from, or undefined for none; the
// build script counts its bytes in the digest that `--check` compares.
const iconArgs = (icon: string | undefined): readonly string[] => (icon === undefined ? [] : ['--icon', icon]);

export async function appState(app: string, icon: string | undefined, exec: Exec = execText): Promise<AppState> {
  const r = await exec('/bin/sh', [BUILD_SCRIPT, '--check', ...iconArgs(icon), app], { timeoutMs: CHECK_TIMEOUT_MS });
  const out = r.stdout.trim();
  if (out === 'up to date' || out === 'stale' || out === 'missing') return out;
  throw new Error(`cannot tell whether the helper app is built: ${r.stderr.trim().slice(0, 200) || out}`);
}

export async function buildApp(
  app: string,
  icon: string | undefined,
  log: (...parts: string[]) => void,
  exec: Exec = execText
): Promise<void> {
  log('building the notification helper', app);
  const r = await exec('/bin/sh', [BUILD_SCRIPT, ...iconArgs(icon), app], { timeoutMs: BUILD_TIMEOUT_MS });
  if (!r.timedOut && r.code === 0) return;
  if (r.timedOut) throw new Error(`building the helper app timed out after ${BUILD_TIMEOUT_MS / 1000} s`);
  const tail = r.stderr.trimEnd().split('\n').slice(-20).join('\n');
  let hint = '';
  try {
    const x = await exec('/usr/bin/xcrun', ['--find', 'swiftc'], { timeoutMs: CHECK_TIMEOUT_MS });
    if (x.code !== 0) hint = '\nswiftc is missing: run `xcode-select --install`';
  } catch {
    hint = '\nswiftc is missing: run `xcode-select --install`';
  }
  throw new Error(`building the helper app failed:\n${tail}${hint}`);
}
