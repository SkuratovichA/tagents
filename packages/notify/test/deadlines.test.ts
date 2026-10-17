// node --test deadlines.test.ts
//
// The scheduler on its own, against the fake clock. The engine's use of it
// (state rows, drop rules, the notice itself) is in engine.test.ts.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createDeadlines } from '../src/deadlines.ts';
import { MIN, T0, fakeClock } from './fakes.ts';

function rig() {
  const clock = fakeClock();
  const fired: Array<[string, number]> = [];
  const d = createDeadlines({ clock, onDue: (key, idleSince) => fired.push([key, idleSince]) });
  return { clock, fired, d };
}

test('nothing is pending until something is armed, and again once it is cancelled', () => {
  const { clock, d } = rig();
  assert.equal(clock.pending(), 0);
  d.arm('12', T0, T0 + 50 * MIN);
  assert.equal(clock.pending(), 1);
  assert.equal(d.armed(), 1);
  d.cancel('12');
  assert.equal(clock.pending(), 0);
  assert.equal(d.armed(), 0);
});

test('one timer serves every key, set for the earliest, and never longer than 5 minutes', () => {
  const { clock, d } = rig();
  d.arm('a', T0, T0 + 50 * MIN);
  d.arm('b', T0, T0 + 2 * MIN);
  d.arm('c', T0, T0 + 30 * MIN);
  assert.equal(clock.pending(), 1);
  assert.equal(clock.nextDelay(), 2 * MIN);
  d.cancel('b');
  assert.equal(clock.nextDelay(), 5 * MIN);
});

test('a key fires once, at its time, with the idle-since it was armed with', () => {
  const { clock, fired, d } = rig();
  d.arm('12', T0 - MIN, T0 + 12 * MIN);
  clock.advance(11 * MIN);
  assert.deepEqual(fired, []);
  clock.advance(MIN);
  assert.deepEqual(fired, [['12', T0 - MIN]]);
  clock.advance(60 * MIN);
  assert.equal(fired.length, 1);
  assert.equal(clock.pending(), 0);
  assert.equal(d.armed(), 0);
});

test('several keys due together each fire once', () => {
  const { clock, fired, d } = rig();
  d.arm('a', T0, T0 + 6 * MIN);
  d.arm('b', T0, T0 + 6 * MIN);
  clock.advance(7 * MIN);
  assert.deepEqual(fired.map(([k]) => k).sort(), ['a', 'b']);
});

test('arming a key again replaces its deadline', () => {
  const { clock, fired, d } = rig();
  d.arm('12', T0, T0 + 10 * MIN);
  d.arm('12', T0 + 5 * MIN, T0 + 20 * MIN);
  assert.equal(d.armed(), 1);
  clock.advance(15 * MIN);
  assert.deepEqual(fired, []);
  clock.advance(6 * MIN);
  assert.deepEqual(fired, [['12', T0 + 5 * MIN]]);
});

test('a cancelled key never fires', () => {
  const { clock, fired, d } = rig();
  d.arm('12', T0, T0 + 10 * MIN);
  d.cancel('12');
  clock.advance(60 * MIN);
  assert.deepEqual(fired, []);
});

test('the wall clock jumping over the deadline (a sleep) fires it on the next wake', () => {
  const { clock, fired, d } = rig();
  d.arm('12', T0, T0 + 50 * MIN);
  clock.advance(4 * MIN);
  clock.jump(49 * MIN);
  assert.deepEqual(fired, [], 'a sleeping Mac runs no timer');
  clock.advance(0);
  assert.deepEqual(fired, [['12', T0]]);
});

test('the sleep ends before the deadline: the next wake only shortens the wait', () => {
  const { clock, fired, d } = rig();
  d.arm('12', T0, T0 + 50 * MIN);
  clock.jump(46 * MIN);
  clock.advance(0);
  assert.deepEqual(fired, []);
  assert.equal(clock.nextDelay(), 4 * MIN);
  clock.advance(4 * MIN);
  assert.equal(fired.length, 1);
});

test('close stops everything: no timer, nothing fires, arming again does nothing', () => {
  const { clock, fired, d } = rig();
  d.arm('12', T0, T0 + 10 * MIN);
  d.close();
  assert.equal(clock.pending(), 0);
  d.arm('13', T0, T0 + 10 * MIN);
  assert.equal(clock.pending(), 0);
  clock.advance(60 * MIN);
  assert.deepEqual(fired, []);
  d.close();
});

test('closing from inside a callback stops the keys still waiting in the same wake', () => {
  const clock = fakeClock();
  const fired: string[] = [];
  const d = createDeadlines({
    clock,
    onDue: (key) => {
      fired.push(key);
      d.close();
    },
  });
  d.arm('a', T0, T0 + 6 * MIN);
  d.arm('b', T0, T0 + 6 * MIN);
  clock.advance(7 * MIN);
  assert.equal(fired.length, 1);
  assert.equal(clock.pending(), 0);
});

test('cancelling a key from inside another key\'s callback keeps it from firing', () => {
  const clock = fakeClock();
  const fired: string[] = [];
  const d = createDeadlines({
    clock,
    onDue: (key) => {
      fired.push(key);
      d.cancel(key === 'a' ? 'b' : 'a');
    },
  });
  d.arm('a', T0, T0 + 6 * MIN);
  d.arm('b', T0, T0 + 6 * MIN);
  clock.advance(7 * MIN);
  assert.equal(fired.length, 1);
});
