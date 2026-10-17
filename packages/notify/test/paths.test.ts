// node --test paths.test.ts
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import {
  appPath,
  BUILD_SCRIPT,
  LAUNCHD_LABEL,
  logPath,
  PACKAGE_DIR,
  plistPath,
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
  assert.equal(plistPath('/h'), `/h/Library/LaunchAgents/${LAUNCHD_LABEL}.plist`);
  assert.equal(logPath('/h'), '/h/Library/Logs/tagents/notify.log');
});
