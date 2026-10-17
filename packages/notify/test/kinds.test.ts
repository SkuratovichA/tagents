// node --test kinds.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { QUESTION_TOOLS, classify, countsSession } from '../src/kinds.ts';
import { event } from './fakes.ts';

const off = { headless: false };

test('AskUserQuestion is a question that arms the cache deadline', () => {
  const v = classify(event({ event: 'PreToolUse', tool: 'AskUserQuestion', text: 'Which one?' }), off);
  assert.deepEqual(v, { kind: 'question', plan: false, arms: true, withdraw: false, cancel: false });
});

test('ExitPlanMode is a question that carries the plan subtitle flag', () => {
  const v = classify(event({ event: 'PreToolUse', tool: 'ExitPlanMode' }), off);
  assert.equal(v?.kind, 'question');
  assert.equal(v?.plan, true);
});

test('any other tool before it runs is nothing', () => {
  assert.equal(classify(event({ event: 'PreToolUse', tool: 'Bash' }), off), null);
});

test('PostToolUse of the two question tools is the answer: it withdraws and cancels, with no notice', () => {
  for (const tool of ['AskUserQuestion', 'ExitPlanMode']) {
    const v = classify(event({ event: 'PostToolUse', tool }), off);
    assert.deepEqual(v, { kind: null, plan: false, arms: false, withdraw: true, cancel: true }, tool);
  }
  assert.equal(classify(event({ event: 'PostToolUse', tool: 'Bash' }), off), null);
});

test('Notification: the subtype decides, and a text with an unknown subtype is a permission', () => {
  const n = (sub: string, text: string) => classify(event({ event: 'Notification', sub, text }), off);
  assert.equal(n('elicitation_dialog', 'Pick')?.kind, 'question');
  assert.equal(n('permission_prompt', 'Allow Bash?')?.kind, 'permission');
  assert.equal(n('permission_prompt', 'Allow Bash?')?.arms, true);
  assert.equal(n('something_new', 'Needs you')?.kind, 'permission');
  assert.equal(n('', 'Claude needs your permission')?.kind, 'permission');
});

test('Notification: idle_prompt, "waiting for your input", auth_success and a text-less one are ignored', () => {
  const n = (sub: string, text: string) => classify(event({ event: 'Notification', sub, text }), off);
  assert.equal(n('idle_prompt', 'anything'), null);
  assert.equal(n('', 'Claude is Waiting For Your Input'), null);
  assert.equal(n('something_new', 'waiting for your input'), null);
  assert.equal(n('auth_success', 'Signed in'), null);
  assert.equal(n('something_new', ''), null);
});

test('Stop of the main agent is turn_done; Stop with an agent id is ignored', () => {
  const v = classify(event({ event: 'Stop' }), off);
  assert.deepEqual(v, { kind: 'turn_done', plan: false, arms: true, withdraw: false, cancel: false });
  assert.equal(classify(event({ event: 'Stop', agentId: 'agent-7' }), off), null);
});

test('SubagentStop is subagent_done and does not arm', () => {
  const v = classify(event({ event: 'SubagentStop', agentId: 'agent-7', sub: 'Explore' }), off);
  assert.deepEqual(v, { kind: 'subagent_done', plan: false, arms: false, withdraw: false, cancel: false });
});

test('SessionEnd is session_end and also withdraws and cancels', () => {
  const v = classify(event({ event: 'SessionEnd', sub: 'logout' }), off);
  assert.deepEqual(v, { kind: 'session_end', plan: false, arms: false, withdraw: true, cancel: true });
});

test('UserPromptSubmit withdraws and cancels without a notice of its own', () => {
  const v = classify(event({ event: 'UserPromptSubmit' }), off);
  assert.deepEqual(v, { kind: null, plan: false, arms: false, withdraw: true, cancel: true });
});

test('SessionStart withdraws and cancels without a notice of its own: the old session\'s question is moot', () => {
  const v = classify(event({ event: 'SessionStart' }), off);
  assert.deepEqual(v, { kind: null, plan: false, arms: false, withdraw: true, cancel: true });
});

test('QUESTION_TOOLS is the list both ends of a question go by', () => {
  assert.deepEqual([...QUESTION_TOOLS], ['AskUserQuestion', 'ExitPlanMode']);
  for (const tool of QUESTION_TOOLS) {
    assert.equal(classify(event({ event: 'PreToolUse', tool }), off)?.kind, 'question', tool);
    assert.equal(classify(event({ event: 'PostToolUse', tool }), off)?.cancel, true, tool);
  }
});

test('a session without a pane counts only with sessions.headless', () => {
  const e = event({ event: 'Stop', key: 's-abc', pane: '' });
  assert.equal(classify(e, off), null);
  assert.equal(classify(e, { headless: true })?.kind, 'turn_done');
  assert.equal(classify(event({ event: 'UserPromptSubmit', key: 's-abc', pane: '' }), off), null);
  assert.equal(countsSession('s-abc', false), false);
  assert.equal(countsSession('s-abc', true), true);
  assert.equal(countsSession('12', false), true);
});
