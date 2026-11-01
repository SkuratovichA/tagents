// node --test messages-export.test.ts
//
// spec/cli/messages.json is what the Rust binary prints its lines from. `pnpm messages:check` is the CI gate for the file; these tests pin what the generator refuses and that the file is the catalogues' export.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { messagesText, unsupported } from '../src/i18n/export.ts';

const FILE = fileURLToPath(new URL('../../../spec/cli/messages.json', import.meta.url));

test('the committed file is the export of the two catalogues', () => {
  assert.equal(fs.readFileSync(FILE, 'utf8'), messagesText());
});

test('a text that uses more of i18next than {{name}} is refused', () => {
  for (const text of ['see $t(pluginNone)', '{{- file}}', '{{file, uppercase}}', '{{ file }}', '{{a b}}', '{{{x}}']) {
    assert.notEqual(unsupported(text), null, text);
  }
  for (const text of ['', 'plain', '{{file}} and {{name}}', '{{}}', 'a { b } {', '{{a_1}}']) {
    assert.equal(unsupported(text), null, text);
  }
});

test('the exporter names the key it refuses', () => {
  assert.throws(() => messagesText({ en: { a: 'x $t(b)' } }), /en\.a cannot be exported to Rust: it nests another key/);
  assert.throws(() => messagesText({ en: { a: 'x' }, ru: { b: 7 } }), /ru\.b is not a string/);
});
