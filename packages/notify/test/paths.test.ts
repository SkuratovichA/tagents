// node --test paths.test.ts
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { isExecutableFile, tmpDir } from '@tagents/core';
import {
  appPath,
  BUILD_SCRIPT,
  BUNDLE_ID,
  logPath,
  PACKAGE_DIR,
  plistPath,
  resolveIcon,
  tagentsScript,
} from '../src/paths.ts';

test('PACKAGE_DIR is the notify package', () => {
  const pkg: unknown = JSON.parse(fs.readFileSync(path.join(PACKAGE_DIR, 'package.json'), 'utf8'));
  assert.ok(typeof pkg === 'object' && pkg !== null && 'name' in pkg);
  assert.equal(pkg.name, '@tagents/notify');
  assert.ok(!PACKAGE_DIR.endsWith('/'));
  assert.ok(fs.existsSync(BUILD_SCRIPT));
});

test('the default tagents script exists and is executable', () => {
  fs.accessSync(tagentsScript({}), fs.constants.X_OK);
});

test('overrides win when non-empty and are ignored when empty', () => {
  assert.equal(tagentsScript({ TA_NOTIFY_TAGENTS: '/x/tagents' }), '/x/tagents');
  assert.equal(appPath({ TA_NOTIFY_APP: '/x/A.app' }, '/h'), '/x/A.app');
  assert.equal(tagentsScript({ TA_NOTIFY_TAGENTS: '' }), tagentsScript({}));
  assert.equal(
    appPath({ TA_NOTIFY_APP: '' }, '/h'),
    '/h/Library/Application Support/tagents/TagentsNotify.app'
  );
});

test('home-relative paths', () => {
  assert.equal(plistPath('/h'), `/h/Library/LaunchAgents/${BUNDLE_ID}.plist`);
  assert.equal(logPath('/h'), '/h/Library/Logs/tagents/notify.log');
});

function iconDir(): { readonly dir: string; readonly png: string } {
  const dir = tmpDir('notify-paths-icon');
  const png = path.join(dir, 'pic.png');
  fs.writeFileSync(png, 'png');
  return { dir, png };
}

test('a configured icon is an absolute path, a ~/ path, or relative to the options file', () => {
  const { dir, png } = iconDir();
  const home = tmpDir('notify-paths-home');
  fs.mkdirSync(path.join(home, 'pics'));
  fs.writeFileSync(path.join(home, 'pics', 'home.png'), 'png');
  fs.mkdirSync(path.join(dir, 'plugins'));
  fs.writeFileSync(path.join(dir, 'plugins', 'beside.png'), 'png');
  const options = path.join(dir, 'plugins', 'notify.yaml');
  assert.deepEqual(resolveIcon(png, options, {}, home), { file: png });
  assert.deepEqual(resolveIcon('~/pics/home.png', options, {}, home), { file: path.join(home, 'pics', 'home.png') });
  assert.deepEqual(resolveIcon('beside.png', options, {}, home), { file: path.join(dir, 'plugins', 'beside.png') });
  assert.deepEqual(resolveIcon('../pic.png', options, {}, home), { file: png }, 'relative means relative to the file, not to the cwd');
});

test('a configured icon that is not a file gives no icon and a problem naming the path', () => {
  const { dir } = iconDir();
  const options = path.join(dir, 'notify.yaml');
  const missing = resolveIcon('nope.png', options, {}, '/h');
  assert.equal(missing.file, null);
  assert.match(missing.problem ?? '', new RegExp(`icon ${path.join(dir, 'nope.png')} does not exist`));
  const folder = resolveIcon(dir, options, {}, '/h');
  assert.equal(folder.file, null);
  assert.match(folder.problem ?? '', /is not a file/);
  assert.match(missing.problem ?? '', /built without an icon/);
});

test('without the option the icon is notify-icon.png next to the app, when that file exists', () => {
  const { dir } = iconDir();
  const app = path.join(dir, 'TagentsNotify.app');
  const options = path.join(dir, 'notify.yaml');
  assert.deepEqual(resolveIcon(undefined, options, { TA_NOTIFY_APP: app }, '/h'), { file: null }, 'no file, no icon, and nothing to complain about');
  fs.writeFileSync(path.join(dir, 'notify-icon.png'), 'png');
  assert.deepEqual(resolveIcon(undefined, options, { TA_NOTIFY_APP: app }, '/h'), { file: path.join(dir, 'notify-icon.png') });

  const home = tmpDir('notify-paths-home');
  const support = path.join(home, 'Library', 'Application Support', 'tagents');
  fs.mkdirSync(support, { recursive: true });
  assert.deepEqual(resolveIcon(undefined, options, {}, home), { file: null });
  fs.writeFileSync(path.join(support, 'notify-icon.png'), 'png');
  assert.deepEqual(resolveIcon(undefined, options, {}, home), { file: path.join(support, 'notify-icon.png') });
});

test('the script a click runs counts only as an executable regular file', () => {
  const { dir } = iconDir();
  const script = path.join(dir, 'tagents');
  assert.equal(isExecutableFile(script), false, 'missing');
  fs.writeFileSync(script, '#!/bin/sh\n');
  assert.equal(isExecutableFile(script), false, 'present, not executable');
  fs.chmodSync(script, 0o755);
  assert.equal(isExecutableFile(script), true);
  assert.equal(isExecutableFile(dir), false, 'a directory');
});

test('an icon that is a dangling symlink, a directory or unreadable gives no icon and a problem', (t) => {
  const { dir } = iconDir();
  const options = path.join(dir, 'notify.yaml');
  fs.symlinkSync(path.join(dir, 'gone.png'), path.join(dir, 'dangling.png'));
  const dangling = resolveIcon('dangling.png', options, {}, '/h');
  assert.equal(dangling.file, null);
  assert.match(dangling.problem ?? '', /dangling\.png does not exist; the app is built without an icon/);

  fs.mkdirSync(path.join(dir, 'folder.png'));
  assert.match(resolveIcon('folder.png', options, {}, '/h').problem ?? '', /folder\.png is not a file/);

  if (process.getuid?.() === 0) {
    t.diagnostic('running as root: a file with no permissions is still readable, so that case is not checked');
    return;
  }
  const locked = path.join(dir, 'locked.png');
  fs.writeFileSync(locked, 'png');
  fs.chmodSync(locked, 0o000);
  const r = resolveIcon('locked.png', options, {}, '/h');
  assert.equal(r.file, null);
  assert.match(r.problem ?? '', /locked\.png is not readable; the app is built without an icon/);
});

test('BUNDLE_ID is the identifier the helper app is built with', () => {
  const plist = fs.readFileSync(path.join(PACKAGE_DIR, 'macos', 'Info.plist'), 'utf8');
  assert.match(plist, new RegExp(`<key>CFBundleIdentifier</key>\\s*<string>${BUNDLE_ID.replaceAll('.', '\\.')}</string>`));
});

function dirWithTagents(): string {
  const dir = tmpDir('notify-paths-bin');
  fs.writeFileSync(path.join(dir, 'real-tagents'), '#!/bin/sh\n');
  fs.chmodSync(path.join(dir, 'real-tagents'), 0o755);
  fs.symlinkSync(path.join(dir, 'real-tagents'), path.join(dir, 'tagents'));
  return dir;
}

test('the click script is the explicit one, else the first tagents on PATH as found, else the package\'s own', () => {
  const bin = dirWithTagents();
  const empty = tmpDir('notify-paths-empty');
  const own = tagentsScript({});
  assert.equal(tagentsScript({ PATH: [empty, bin].join(path.delimiter) }), path.join(bin, 'tagents'), 'the link, not its target: the dashboard runs the link');
  assert.equal(tagentsScript({ PATH: [empty, bin].join(path.delimiter), TA_NOTIFY_TAGENTS: '/x/tagents' }), '/x/tagents', 'explicit wins');
  assert.equal(tagentsScript({ PATH: empty }), own);
  assert.equal(tagentsScript({}), own, 'no PATH at all is not the process\'s PATH');
});
