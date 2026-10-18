// node --test app.test.ts
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import zlib from 'node:zlib';
import { tmpDir } from '@tagents/core';
import { execText, type Exec, type ExecResult } from '../src/exec.ts';
import { BUILD_SCRIPT } from '../src/paths.ts';
import { appState, buildApp } from '../src/platform/macos/app.ts';

function fake(rs: Partial<ExecResult>[]): { exec: Exec; calls: (readonly string[])[] } {
  const calls: (readonly string[])[] = [];
  const exec: Exec = async (file, args) => {
    calls.push([file, ...args]);
    return { code: 0, stdout: '', stderr: '', timedOut: false, ...(rs.shift() ?? {}) };
  };
  return { exec, calls };
}

test('appState maps the three outputs and runs the script through /bin/sh', async () => {
  for (const s of ['up to date', 'stale', 'missing'] as const) {
    const f = fake([{ stdout: `${s}\n`, code: s === 'up to date' ? 0 : 1 }]);
    assert.equal(await appState('/A.app', undefined, f.exec), s);
    assert.deepEqual(f.calls[0], ['/bin/sh', BUILD_SCRIPT, '--check', '/A.app']);
  }
  await assert.rejects(appState('/A.app', undefined, fake([{ stdout: 'huh', code: 2 }]).exec));
});

test('the real script says missing, exit 1, for an app that is not there', async () => {
  const r = await execText('/bin/sh', [BUILD_SCRIPT, '--check', '/nonexistent/X.app'], { timeoutMs: 10_000 });
  assert.equal(r.stdout.trim(), 'missing');
  assert.equal(r.code, 1);
});

test('buildApp logs first and succeeds on exit 0', async () => {
  const lines: string[] = [];
  const f = fake([{}]);
  await buildApp('/A.app', undefined, (...p) => lines.push(p.join(' ')), f.exec);
  assert.equal(lines.length, 1);
  assert.deepEqual(f.calls[0], ['/bin/sh', BUILD_SCRIPT, '/A.app']);
});

test('buildApp rejects with the last 20 lines of stderr and a swiftc hint', async () => {
  const stderr = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join('\n');
  const f = fake([{ code: 1, stderr }, { code: 1 }]);
  await assert.rejects(buildApp('/A.app', undefined, () => {}, f.exec), (e: Error) => {
    assert.ok(e.message.includes('line 30') && e.message.includes('line 11'));
    assert.ok(!e.message.includes('line 10\n'));
    assert.ok(e.message.includes('xcode-select --install'));
    return true;
  });
  assert.deepEqual(f.calls[1], ['/usr/bin/xcrun', '--find', 'swiftc']);
});

test('buildApp gives no swiftc hint when swiftc exists', async () => {
  const f = fake([{ code: 1, stderr: 'oops' }, { code: 0 }]);
  await assert.rejects(buildApp('/A.app', undefined, () => {}, f.exec), (e: Error) => !e.message.includes('xcode-select'));
});

test('an icon is passed to the script as --icon <png>, before the app, in both modes', async () => {
  const f = fake([{ stdout: 'stale\n', code: 1 }, {}]);
  assert.equal(await appState('/A.app', '/i/icon.png', f.exec), 'stale');
  await buildApp('/A.app', '/i/icon.png', () => {}, f.exec);
  assert.deepEqual(f.calls[0], ['/bin/sh', BUILD_SCRIPT, '--check', '--icon', '/i/icon.png', '/A.app']);
  assert.deepEqual(f.calls[1], ['/bin/sh', BUILD_SCRIPT, '--icon', '/i/icon.png', '/A.app']);
});

test('the real script refuses an icon it cannot read, in --check mode too', async () => {
  const r = await execText('/bin/sh', [BUILD_SCRIPT, '--check', '--icon', '/nonexistent/i.png', '/nonexistent/X.app'], {
    timeoutMs: 10_000,
  });
  assert.equal(r.code, 2);
  assert.ok(r.stderr.includes('cannot read the icon'));
});

// The real builds below compile the helper (a few seconds each) into a scratch directory. The bundle id of that
// copy is the real app's, so the script is told not to register it with LaunchServices.
const canBuild = process.platform === 'darwin' && spawnSync('/usr/bin/xcrun', ['--find', 'swiftc']).status === 0;
const skipBuild = canBuild ? false : 'needs macOS with swiftc (xcode-select --install)';
const buildEnv = { ...process.env, TA_NOTIFY_NO_LSREGISTER: '1' };

const sh = (args: readonly string[], env: NodeJS.ProcessEnv = buildEnv) =>
  execText('/bin/sh', [BUILD_SCRIPT, ...args], { timeoutMs: 120_000, env });
const plistValue = (app: string, key: string) =>
  spawnSync('/usr/bin/plutil', ['-extract', key, 'raw', path.join(app, 'Contents', 'Info.plist')], { encoding: 'utf8' });

// A solid-colour RGBA PNG, so a test needs no picture on disk.
function solidPng(width: number, height: number, [r, g, b]: readonly [number, number, number]): Buffer {
  const chunk = (type: string, data: Buffer): Buffer => {
    const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: width }, () => [r, g, b, 255]).flat())]);
  const raw = Buffer.concat(Array.from({ length: height }, () => row));
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Decodes an 8-bit RGBA PNG (what the helper writes) into a pixel reader.
function readPng(file: string): { width: number; height: number; at: (x: number, y: number) => readonly number[] } {
  const buf = fs.readFileSync(file);
  const idat: Buffer[] = [];
  let width = 0;
  let height = 0;
  for (let off = 8; off < buf.length; ) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('latin1', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.deepEqual([data[8], data[9], data[12]], [8, 6, 0], 'expected 8-bit RGBA, not interlaced');
    }
    if (type === 'IDAT') idat.push(data);
    off += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * 4;
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let i = 0; i < stride; i++) {
      const v = raw[y * (stride + 1) + 1 + i] ?? 0;
      const left = i >= 4 ? (pixels[y * stride + i - 4] ?? 0) : 0;
      const up = y > 0 ? (pixels[(y - 1) * stride + i] ?? 0) : 0;
      const upLeft = y > 0 && i >= 4 ? (pixels[(y - 1) * stride + i - 4] ?? 0) : 0;
      const p = left + up - upLeft;
      const paeth = Math.abs(p - left) <= Math.abs(p - up) && Math.abs(p - left) <= Math.abs(p - upLeft) ? left : Math.abs(p - up) <= Math.abs(p - upLeft) ? up : upLeft;
      const predicted = [0, left, up, (left + up) >> 1, paeth][filter ?? 0] ?? 0;
      pixels[y * stride + i] = (v + predicted) & 255;
    }
  }
  return { width, height, at: (x, y) => [...pixels.subarray(y * stride + x * 4, y * stride + x * 4 + 4)] };
}

// Every file under `root` with its size and mtime, to tell whether anything was written.
function snapshot(root: string): string[] {
  const rows: string[] = [];
  const walk = (dir: string): void => {
    for (const name of fs.readdirSync(dir).sort()) {
      const full = path.join(dir, name);
      const st = fs.lstatSync(full);
      rows.push(`${full} ${st.size} ${st.mtimeMs}`);
      if (st.isDirectory()) walk(full);
    }
  };
  walk(root);
  return rows;
}

const ICONSET = [16, 32, 128, 256, 512].flatMap((n) => [`icon_${n}x${n}.png`, `icon_${n}x${n}@2x.png`]).sort();

/** A parsed helper line, narrowed from `unknown`. */
function helperLine(stdout: string): { readonly ok?: unknown; readonly error?: unknown } {
  const parsed: unknown = JSON.parse(stdout);
  assert.ok(typeof parsed === 'object' && parsed !== null, `not an object: ${stdout}`);
  return parsed;
}

test('build.sh --icon: AppIcon.icns, the key, the plate, and an icon that is part of the digest', { skip: skipBuild }, async (t) => {
  const dir = tmpDir('app-icon');
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const wide = path.join(dir, 'wide.png');
  const blue = path.join(dir, 'blue.png');
  fs.writeFileSync(wide, solidPng(64, 32, [220, 20, 20]));
  fs.writeFileSync(blue, solidPng(64, 32, [20, 20, 220]));
  const app = path.join(dir, 'with.app');
  // A TMPDIR of its own: the script's scratch space must be empty again when it is done.
  const scratch = path.join(dir, 'scratch');
  fs.mkdirSync(scratch);
  const env = { ...buildEnv, TMPDIR: scratch };

  const built = await sh(['--icon', wide, app], env);
  assert.equal(built.code, 0, built.stderr.slice(-400));
  assert.deepEqual(fs.readdirSync(scratch), [], 'a successful build leaves its TMPDIR empty');
  assert.deepEqual(fs.readdirSync(dir).filter((n) => n.includes('.build.')), []);
  assert.ok(fs.statSync(path.join(app, 'Contents', 'Resources', 'AppIcon.icns')).size > 1000);
  assert.equal(plistValue(app, 'CFBundleIconFile').stdout.trim(), 'AppIcon');
  assert.equal(plistValue(app, 'NSUserNotificationAlertStyle').stdout.trim(), 'alert');
  assert.equal(spawnSync('/usr/bin/plutil', ['-lint', path.join(app, 'Contents', 'Info.plist')]).status, 0);

  const unpacked = path.join(dir, 'unpacked.iconset');
  const unpack = spawnSync('/usr/bin/iconutil', ['-c', 'iconset', '-o', unpacked, path.join(app, 'Contents', 'Resources', 'AppIcon.icns')], { encoding: 'utf8' });
  assert.equal(unpack.status, 0, unpack.stderr);
  assert.deepEqual(fs.readdirSync(unpacked).sort(), ICONSET);

  // --check reads and writes nothing, whatever it answers.
  const before = snapshot(dir);
  assert.equal((await sh(['--check', '--icon', wide, app], env)).stdout.trim(), 'up to date');
  const changed = await sh(['--check', '--icon', blue, app], env);
  assert.deepEqual([changed.stdout.trim(), changed.code], ['stale', 1]);
  assert.equal((await sh(['--check', app], env)).stdout.trim(), 'stale', 'an icon taken away is a change');
  assert.equal((await sh(['--check', '--icon', wide, path.join(dir, 'absent.app')], env)).stdout.trim(), 'missing');
  assert.deepEqual(snapshot(dir), before);

  // The plate: 1024 square, transparent outside the rounded square, light inside, the picture in the middle at its own aspect ratio.
  const out = path.join(dir, 'plate.png');
  const bin = path.join(app, 'Contents', 'MacOS', 'tagents-notify');
  const drawn = spawnSync(bin, ['icon', wide, out], { encoding: 'utf8' });
  assert.equal(drawn.status, 0, drawn.stdout);
  assert.equal(helperLine(drawn.stdout).ok, true);
  assert.match(spawnSync('/usr/bin/sips', ['-g', 'profile', out], { encoding: 'utf8' }).stdout, /sRGB/, 'drawn in sRGB');
  const plate = readPng(out);
  assert.deepEqual([plate.width, plate.height], [1024, 1024]);
  assert.equal(plate.at(0, 0)[3], 0, 'the canvas corner is transparent');
  assert.equal(plate.at(1023, 1023)[3], 0);
  assert.equal(plate.at(110, 110)[3], 0, 'the plate has rounded corners');
  const light = plate.at(130, 512);
  assert.ok(light[3] === 255 && light.slice(0, 3).every((c) => (c ?? 0) > 220), `light plate, got ${light}`);
  const centre = plate.at(512, 512);
  assert.ok((centre[0] ?? 0) > 180 && (centre[1] ?? 255) < 80, `the picture is red at the centre, got ${centre}`);
  assert.ok((plate.at(512 + 280, 512)[1] ?? 255) < 80, 'the wide picture reaches 280 px to the side (a plate pixel there is light, green above 200)');
  assert.ok((plate.at(512, 512 + 200)[1] ?? 0) > 200, 'and 200 px up or down it is already plate: the aspect ratio is kept');

  const bad = spawnSync(bin, ['icon', path.join(dir, 'nope.png'), out], { encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.equal(helperLine(bad.stdout).ok, false);
  assert.equal(spawnSync(bin, ['icon', wide], { encoding: 'utf8' }).status, 2);

  // A picture the icon verb cannot read fails the build and leaves nothing behind: no scratch, no half-built app.
  const garbage = path.join(dir, 'garbage.png');
  fs.writeFileSync(garbage, 'not a png');
  const failed = await sh(['--icon', garbage, path.join(dir, 'broken.app')], env);
  assert.notEqual(failed.code, 0);
  assert.ok(failed.stderr.includes('cannot read an image'), failed.stderr.slice(-300));
  assert.deepEqual(fs.readdirSync(scratch), [], 'a failed build leaves its TMPDIR empty');
  assert.deepEqual(fs.readdirSync(dir).filter((n) => n.startsWith('broken')), [], 'and no <app>.build.* beside the app');

  // The scratch directory for the icon is made after the app's own, and a failure there must not strand the first.
  // A mktemp that refuses only that one template stands in for a full disk.
  const shims = path.join(dir, 'shims');
  fs.mkdirSync(shims);
  fs.writeFileSync(
    path.join(shims, 'mktemp'),
    '#!/bin/sh\ncase "$*" in *tagents-notify-icon*) echo "mktemp: simulated failure" >&2; exit 1 ;; esac\nexec /usr/bin/mktemp "$@"\n',
    { mode: 0o755 }
  );
  const lost = await sh(['--icon', wide, path.join(dir, 'lost.app')], { ...env, PATH: `${shims}:${process.env['PATH'] ?? ''}` });
  assert.notEqual(lost.code, 0);
  assert.ok(lost.stderr.includes('simulated failure'), `expected the icon scratch directory to be the failure: ${lost.stderr.slice(-300)}`);
  assert.deepEqual(fs.readdirSync(dir).filter((n) => n.startsWith('lost')), [], 'no <app>.build.* is left beside the app');
});

test('build.sh: the bundle id follows the icon, and stays the base without one', { skip: skipBuild }, async (t) => {
  const dir = tmpDir('app-iconid');
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const red = path.join(dir, 'red.png');
  const blue = path.join(dir, 'blue.png');
  fs.writeFileSync(red, solidPng(16, 16, [220, 20, 20]));
  fs.writeFileSync(blue, solidPng(16, 16, [20, 20, 220]));
  const idOf = (app: string): string => plistValue(app, 'CFBundleIdentifier').stdout.trim();
  const suffix = (png: string): string => `.i${createHash('sha256').update(fs.readFileSync(png)).digest('hex').slice(0, 8)}`;

  const plain = path.join(dir, 'plain.app');
  assert.equal((await sh([plain])).code, 0);
  const base = idOf(plain);
  assert.ok(base.length > 0 && !/\.i[0-9a-f]{8}$/.test(base), base);
  const a = path.join(dir, 'a.app');
  const b = path.join(dir, 'b.app');
  assert.equal((await sh(['--icon', red, a])).code, 0);
  assert.equal((await sh(['--icon', blue, b])).code, 0);
  assert.equal(idOf(a), `${base}${suffix(red)}`);
  assert.equal(idOf(b), `${base}${suffix(blue)}`);
  assert.notEqual(idOf(a), idOf(b));
});

test('build.sh refuses an icon that is not a readable file, before it builds anything', async (t) => {
  const dir = tmpDir('app-badicon');
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const r = await sh(['--icon', dir, path.join(dir, 'x.app')]);
  assert.equal(r.code, 2, 'a directory is readable, and is not a picture');
  assert.ok(r.stderr.includes('cannot read the icon'));
  assert.deepEqual(fs.readdirSync(dir), []);
});

test('build.sh without --icon: no icon file and no key, and an icon added later is a change', { skip: skipBuild }, async (t) => {
  const dir = tmpDir('app-noicon');
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const png = path.join(dir, 'i.png');
  fs.writeFileSync(png, solidPng(16, 16, [20, 200, 20]));
  const app = path.join(dir, 'plain.app');

  const built = await sh([app]);
  assert.equal(built.code, 0, built.stderr.slice(-400));
  assert.ok(!fs.existsSync(path.join(app, 'Contents', 'Resources', 'AppIcon.icns')));
  assert.notEqual(plistValue(app, 'CFBundleIconFile').status, 0);
  assert.equal(plistValue(app, 'NSUserNotificationAlertStyle').stdout.trim(), 'alert');
  assert.equal((await sh(['--check', app])).stdout.trim(), 'up to date');
  assert.equal((await sh(['--check', '--icon', png, app])).stdout.trim(), 'stale');
});
