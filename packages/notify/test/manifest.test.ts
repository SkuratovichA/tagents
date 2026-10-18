// node --test manifest.test.ts
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { resolvePluginPackage } from '@tagents/core';

const PKG = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// `tagents plugin add` checks the manifest with its own schema (core's plugin-config.ts), stricter than the loader's:
// it wants tagents.apiVersion as well as tagents.entry. A missing dist is a build question, not a manifest one.
test('`tagents plugin add` takes this package: its manifest carries the apiVersion the add check asks for', () => {
  const result = resolvePluginPackage(PKG, PKG);
  assert.notEqual(result.ok ? 'ok' : result.problem, 'bad-manifest', result.ok ? '' : result.detail);
});
