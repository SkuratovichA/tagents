// node --test needs-binary.test.ts
//
// The needs-binary line is typed in the core table and in the knowledge table, and exported to spec/cli/messages.json for the Rust binary. Notify prints the core one through createT. This keeps the copies byte-equal.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { createT } from '@tagents/core';
import { en } from '../src/i18n/en.ts';

const MESSAGES = fileURLToPath(new URL('../../../spec/cli/messages.json', import.meta.url));

test('every copy of the needs-binary text is the same string', () => {
  const exported = (JSON.parse(fs.readFileSync(MESSAGES, 'utf8')) as { en: Record<string, string> }).en['needsBinary'];
  const core = createT('en')('needsBinary', { verb: '{{verb}}', interpolation: { escapeValue: false } });
  assert.equal(en.needsBinary, exported);
  assert.equal(core, exported);
});
