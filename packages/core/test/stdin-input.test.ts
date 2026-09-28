// PromptOptions.input: messages delivered into a running turn through stdin.
// Absent, nothing about the turn may change — argv ends with the prompt and
// the child has no stdin. Present, the prompt is the first stdin line, every
// item is written at once, and `delivered` says which of them the CLI echoed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { buildArgs, ClaudeHeadlessDriver, stdinLine } from '../src/claude-driver.ts';
import type { SessionSpec, StreamEvent, TurnInput } from '../src/driver.ts';
import { fakeClaude, tmpDir, type FakeScript } from '../src/testkit.ts';

let tmp = '';
before(() => {
  tmp = tmpDir('stdin-input');
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/**
 * An input the test feeds by hand. By default it honours return() the way the
 * orchestrator's port does (refuses and ends); `ignoreReturn` is an iterable
 * that keeps yielding after it, to reach the driver's own after-close guard.
 */
function feed(o: { ignoreReturn?: boolean } = {}): {
  readonly input: AsyncIterable<TurnInput>;
  push(item: TurnInput): void;
  returned(): boolean;
} {
  const queue: TurnInput[] = [];
  let waiter: ((r: IteratorResult<TurnInput>) => void) | null = null;
  let returned = false;
  const done = (): IteratorResult<TurnInput> => ({ done: true, value: undefined });
  const iterator: AsyncIterator<TurnInput> = {
    next: () => {
      const item = queue.shift();
      if (item) return Promise.resolve({ done: false, value: item });
      if (returned && !o.ignoreReturn) return Promise.resolve(done());
      return new Promise((r) => {
        waiter = r;
      });
    },
    return: () => {
      returned = true;
      if (!o.ignoreReturn) {
        const w = waiter;
        waiter = null;
        w?.(done());
      }
      return Promise.resolve(done());
    },
  };
  return {
    input: { [Symbol.asyncIterator]: () => iterator },
    push(item) {
      const w = waiter;
      waiter = null;
      if (w) w({ done: false, value: item });
      else queue.push(item);
    },
    returned: () => returned,
  };
}

function setup(script: FakeScript): { spec: SessionSpec; driver: ClaudeHeadlessDriver } {
  const fake = fakeClaude(script, fs.mkdtempSync(path.join(tmp, 'fake-')));
  const spec: SessionSpec = { kind: 'claude', cwd: tmp, skipPermissions: true, bin: fake.bin };
  return { spec, driver: new ClaudeHeadlessDriver({ stateDir: path.join(tmp, 'state') }) };
}

const readLines = (file: string): string[] =>
  fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean) : [];

interface Call {
  argv: string[];
  stdin: string;
}
const readCall = (file: string): Call => {
  const seen: unknown = JSON.parse(fs.readFileSync(file, 'utf8'));
  return seen as Call;
};

test('without input: the prompt ends argv and the child gets no stdin pipe', async () => {
  const argvFile = path.join(tmp, 'argv-plain.json');
  const { spec, driver } = setup({ argvFile, result: { text: 'ok' } });
  const ref = await driver.open(spec);
  const o = await driver.prompt(ref, 'hello there', { timeoutMs: 5000 });
  assert.equal(o.kind, 'ok');
  const call = readCall(argvFile);
  assert.deepEqual(call.argv, buildArgs(spec, 'hello there', null));
  assert.equal(call.argv.at(-1), 'hello there');
  assert.ok(!call.argv.includes('--input-format'));
  assert.equal(call.stdin, 'null');
  assert.ok(!('delivered' in o), 'an outcome without input carries no delivered list');
});

test('with input: stream-json input flags, no prompt in argv, the prompt is the first stdin line', async () => {
  const argvFile = path.join(tmp, 'argv-input.json');
  const linesFile = path.join(tmp, 'lines-input.txt');
  const { spec, driver } = setup({ argvFile, stdin: { linesFile }, result: { text: 'ok' } });
  const ref = await driver.open(spec);
  const f = feed();
  const o = await driver.prompt(ref, 'hello there', { timeoutMs: 5000, input: f.input });
  assert.equal(o.kind, 'ok');
  const call = readCall(argvFile);
  assert.deepEqual(call.argv, buildArgs(spec, 'hello there', null, true));
  const at = call.argv.indexOf('--input-format');
  assert.deepEqual(call.argv.slice(at, at + 3), ['--input-format', 'stream-json', '--replay-user-messages']);
  assert.ok(!call.argv.includes('hello there'));
  assert.equal(call.stdin, 'pipe');
  const lines = readLines(linesFile);
  assert.equal(lines.length, 1);
  assert.equal(`${lines[0]}\n`, stdinLine('hello there'));
  assert.deepEqual(o.delivered, []);
  assert.ok(f.returned(), 'the driver stops pulling once the turn is over');
});

test('an item offered mid-turn is written, echoed as a replay, and the turn ends on one result', async () => {
  const linesFile = path.join(tmp, 'lines-mid.txt');
  const { spec, driver } = setup({ stdin: { linesFile }, sleepMs: 400, result: { text: 'first', costUsd: 0.2 } });
  const ref = await driver.open(spec);
  const f = feed();
  const events: StreamEvent[] = [];
  const turn = driver.prompt(ref, 'work', { timeoutMs: 5000, input: f.input, onEvent: (e) => events.push(e) });
  f.push({ id: 'm1', text: 'what is 17+25?' });
  const o = await turn;
  assert.equal(o.kind, 'ok');
  assert.deepEqual(o.delivered, [{ id: 'm1', replayed: true }]);
  assert.deepEqual(
    events.filter((e) => e.kind === 'replay'),
    [{ kind: 'replay', id: 'm1' }]
  );
  assert.equal(events.filter((e) => e.kind === 'result').length, 1);
  const lines = readLines(linesFile);
  assert.equal(lines.length, 2);
  assert.equal(`${lines[1]}\n`, stdinLine('what is 17+25?'));
});

test('an item echoed only after the first result becomes a second result, and the outcome is the last one', async () => {
  const linesFile = path.join(tmp, 'lines-late.txt');
  const { spec, driver } = setup({
    sleepMs: 300,
    stdin: {
      linesFile,
      replayAfterResult: true,
      results: [
        { text: 'first', costUsd: 0.1, numTurns: 4 },
        { text: 'second', costUsd: 0.15, numTurns: 1 },
      ],
    },
  });
  const ref = await driver.open(spec);
  const f = feed();
  const events: StreamEvent[] = [];
  const turn = driver.prompt(ref, 'work', { timeoutMs: 5000, input: f.input, onEvent: (e) => events.push(e) });
  f.push({ id: 'm2', text: 'what is 30+3?' });
  const o = await turn;
  assert.equal(o.kind, 'ok');
  const kinds = events.filter((e) => e.kind === 'result' || e.kind === 'replay').map((e) => e.kind);
  assert.deepEqual(kinds, ['result', 'replay', 'result']);
  assert.deepEqual(o.delivered, [{ id: 'm2', replayed: true }]);
  if (o.kind !== 'ok') return;
  // The CLI's total_cost_usd is cumulative per process: the last one, never a sum.
  assert.equal(o.costUsd, 0.15);
  // num_turns is per result: summed.
  assert.equal(o.numTurns, 5);
});

test('a turn killed with a written but unechoed item reports it not replayed', async () => {
  const linesFile = path.join(tmp, 'lines-kill.txt');
  const { spec, driver } = setup({ sleepMs: 20_000, stdin: { linesFile, replayOnlyFirst: true }, result: { text: 'never' } });
  const ref = await driver.open(spec);
  const f = feed();
  const turn = driver.prompt(ref, 'work', { timeoutMs: 800, pipeDrainMs: 200, input: f.input });
  f.push({ id: 'm3', text: 'are you there?' });
  const o = await turn;
  assert.equal(o.kind, 'timeout');
  assert.deepEqual(o.delivered, [{ id: 'm3', replayed: false }]);
});

test('an item that arrives after stdin was closed is not written and is reported not replayed', async () => {
  const linesFile = path.join(tmp, 'lines-closed.txt');
  const { spec, driver } = setup({ sleepMs: 100, stdin: { linesFile }, result: { text: 'done' } });
  const ref = await driver.open(spec);
  const f = feed({ ignoreReturn: true });
  const o = await driver.prompt(ref, 'work', {
    timeoutMs: 5000,
    input: f.input,
    onEvent: (e) => {
      // The driver has closed stdin by the time a listener hears the result.
      if (e.kind === 'result') f.push({ id: 'late', text: 'too late' });
    },
  });
  assert.equal(o.kind, 'ok');
  assert.deepEqual(o.delivered, [{ id: 'late', replayed: false }]);
  assert.equal(readLines(linesFile).length, 1, 'only the prompt line reached stdin');
});
