// node --test i18n.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { generatedFiles } from '../src/plan.ts';
import { createT } from '../src/i18n/index.ts';
import { sampleSources } from './sample.ts';

test('t() interpolates its slots', () => {
  assert.equal(createT()('wrote', { path: 'a.md' }), 'wrote a.md');
});

test('what is rendered into the repo is English whatever TAGENTS_LOCALE says', () => {
  const before = process.env['TAGENTS_LOCALE'];
  try {
    process.env['TAGENTS_LOCALE'] = 'en';
    const english = generatedFiles(sampleSources());
    process.env['TAGENTS_LOCALE'] = 'ru';
    assert.deepEqual([...generatedFiles(sampleSources())], [...english]);
  } finally {
    if (before === undefined) delete process.env['TAGENTS_LOCALE'];
    else process.env['TAGENTS_LOCALE'] = before;
  }
});
