// node --test i18n.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { generatedFiles } from '../src/plan.ts';
import { en } from '../src/i18n/en.ts';
import { createT } from '../src/i18n/index.ts';
import { ru } from '../src/i18n/ru.ts';
import { sampleSources } from './sample.ts';

const slots = (s: string): string[] => [...s.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1] ?? '').sort();

const isKey = (key: string): key is keyof typeof en => key in en;

test('en and ru hold the same keys and the same {{slots}}', () => {
  assert.deepEqual(Object.keys(ru).sort(), Object.keys(en).sort());
  for (const key of Object.keys(en)) {
    assert.ok(isKey(key), key);
    assert.deepEqual(slots(ru[key]), slots(en[key]), key);
  }
});

test('t() interpolates, speaks Russian on request and falls back to English', () => {
  assert.equal(createT('en')('wrote', { path: 'a.md' }), 'wrote a.md');
  assert.equal(createT('ru')('wrote', { path: 'a.md' }), 'записан a.md');
  assert.equal(createT('fr')('wrote', { path: 'a.md' }), 'wrote a.md');
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
