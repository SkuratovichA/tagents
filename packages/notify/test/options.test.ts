// node --test options.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as api from '../src/index.ts';
import { NotifyOptionsSchema, parseDuration } from '../src/options.ts';

const MIN = 60_000;

test('every default is the one the documentation shows', () => {
  assert.deepEqual(NotifyOptionsSchema.parse({}), {
    backend: 'auto',
    click: 'dock',
    sessions: { headless: false },
    events: {
      question: { enabled: true, skip_visible: true },
      permission: { enabled: true, skip_visible: true },
      turn_done: { enabled: true, skip_visible: true },
      cache_expiring: { enabled: true, skip_visible: false, after: 3_000_000, ttl: 3_600_000 },
      subagent_done: { enabled: false, skip_visible: true },
      session_end: { enabled: false, skip_visible: true },
    },
  });
});

test('a partial file keeps every other default, one level down as well', () => {
  const o = NotifyOptionsSchema.parse({ events: { question: { enabled: false } }, click: 'goto' });
  assert.equal(o.events.question.enabled, false);
  assert.equal(o.events.question.skip_visible, true);
  assert.equal(o.click, 'goto');
  assert.equal(o.backend, 'auto');
  assert.equal(o.events.turn_done.enabled, true);
  assert.equal(o.events.cache_expiring.ttl, 60 * MIN);
});

test('durations in the file become milliseconds, 1h30m among them', () => {
  const o = NotifyOptionsSchema.parse({ events: { cache_expiring: { after: '1h30m', ttl: '2h' } } });
  assert.equal(o.events.cache_expiring.after, 5_400_000);
  assert.equal(o.events.cache_expiring.ttl, 7_200_000);
  assert.equal(NotifyOptionsSchema.parse({ events: { cache_expiring: { after: 90 } } }).events.cache_expiring.after, 90_000);
});

test('parseDuration: units combine, a bare number is seconds, anything looser is null', () => {
  assert.equal(parseDuration(90), 90_000);
  assert.equal(parseDuration('90'), 90_000);
  assert.equal(parseDuration('1h30m'), 5_400_000);
  assert.equal(parseDuration('50m'), 3_000_000);
  assert.equal(parseDuration('45s'), 45_000);
  assert.equal(parseDuration('1h2m3s'), 3_723_000);
  for (const bad of ['', '5x', 'm', '1.5h', '30m1h', '1h 30m', ' 5m', '5m ']) {
    assert.equal(parseDuration(bad), null, JSON.stringify(bad));
  }
  assert.equal(parseDuration(-1), null);
  assert.equal(parseDuration(1.5), null);
  assert.equal(parseDuration(Number.NaN), null);
});

test('after at or above ttl is a problem located at after', () => {
  for (const [after, ttl] of [['60m', '60m'], ['2h', '1h']] as const) {
    const r = NotifyOptionsSchema.safeParse({ events: { cache_expiring: { after, ttl } } });
    assert.equal(r.success, false);
    if (r.success) continue;
    assert.deepEqual(
      r.error.issues.map((i) => i.path.join('.')),
      ['events.cache_expiring.after']
    );
  }
  // Only one of the two given: the other keeps its default and is held to the same rule.
  const lone = NotifyOptionsSchema.safeParse({ events: { cache_expiring: { after: '2h' } } });
  assert.equal(lone.success, false);
});

test('a bad duration is a problem located at that key', () => {
  const r = NotifyOptionsSchema.safeParse({ events: { cache_expiring: { ttl: '1.5h' } } });
  assert.equal(r.success, false);
  if (!r.success) assert.deepEqual(r.error.issues.map((i) => i.path.join('.')), ['events.cache_expiring.ttl']);
});

test('an unknown key is a problem at the top, in sessions, in events and inside an event', () => {
  for (const raw of [
    { bogus: 1 },
    { sessions: { headles: true } },
    { events: { question_asked: { enabled: true } } },
    { events: { question: { enabld: true } } },
    { events: { cache_expiring: { afterr: '5m' } } },
  ]) {
    assert.equal(NotifyOptionsSchema.safeParse(raw).success, false, JSON.stringify(raw));
  }
});

test('the enums reject a value they do not list', () => {
  assert.equal(NotifyOptionsSchema.safeParse({ backend: 'smtp' }).success, false);
  assert.equal(NotifyOptionsSchema.safeParse({ click: 'bounce' }).success, false);
  for (const backend of ['auto', 'macos', 'log', 'none']) {
    assert.equal(NotifyOptionsSchema.parse({ backend }).backend, backend);
  }
});

test('icon is an optional non-empty string and has no default', () => {
  assert.equal(NotifyOptionsSchema.parse({}).icon, undefined);
  assert.equal(NotifyOptionsSchema.parse({ icon: '~/pics/tagents.png' }).icon, '~/pics/tagents.png');
  assert.equal(NotifyOptionsSchema.safeParse({ icon: '' }).success, false);
  assert.equal(NotifyOptionsSchema.safeParse({ icon: 3 }).success, false);
});

test('the package exports the schema beside the type derived from it', () => {
  assert.equal(api.NotifyOptionsSchema, NotifyOptionsSchema);
  const o: api.NotifyOptions = api.NotifyOptionsSchema.parse({ click: 'goto' });
  assert.equal(o.click, 'goto');
});
