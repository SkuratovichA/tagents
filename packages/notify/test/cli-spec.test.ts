// node --test cli-spec.test.ts
//
// The spec in src/cli/spec.ts is what the contract generator reads, and through it the tools a client is offered. The verbs themselves are defined in plugin.ts with their own argument schemas. This file keeps the two from drifting: a verb with no line in the spec, a line for a verb that is gone, an option or a required flag that differs, and the exit codes the spec names against the ones the bin returns.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { z } from 'zod';
import { POSITIONALS, runPluginBin, tmpDir } from '@tagents/core';
import { NOTIFY_COMMANDS, notifyCliContract } from '../src/cli/spec.ts';
import { createNotifyPlugin } from '../src/plugin.ts';

const plugin = createNotifyPlugin({ os: 'linux', env: { TAGENTS_CONFIG_DIR: tmpDir('notify-spec-cfg'), TA_STATE_DIR: tmpDir('notify-spec-state'), PATH: '/nonexistent' }, out: () => undefined });

const verbs = plugin.commands ?? [];

test('the spec has a line for every verb the plugin defines, and none for a verb it does not', () => {
  assert.deepEqual(NOTIFY_COMMANDS.map((c) => c.path.join(' ')).sort(), verbs.map((c) => c.name).sort());
});

test('for each verb the options, the required ones and the positionals are the ones its argument schema takes', () => {
  for (const command of verbs) {
    const spec = NOTIFY_COMMANDS.find((c) => c.path.join(' ') === command.name);
    assert.ok(spec !== undefined, command.name);
    const shape: Readonly<Record<string, z.ZodType>> = command.args instanceof z.ZodObject ? command.args.shape : {};
    const flags = Object.keys(shape).filter((key) => key !== POSITIONALS);
    assert.deepEqual(Object.keys(spec.options).sort(), flags.sort(), `${command.name}: options`);
    assert.deepEqual([...spec.required].sort(), flags.filter((key) => !shape[key]?.safeParse(undefined).success).sort(), `${command.name}: required`);
    for (const [key, option] of Object.entries(spec.options)) {
      const takesBoolean = shape[key]?.safeParse(true).success === true;
      assert.equal(option.type, takesBoolean ? 'boolean' : 'string', `${command.name}: --${key}`);
    }
    assert.equal(spec.positionals.length > 0, POSITIONALS in shape, `${command.name}: positionals`);
  }
});

test('the contract names the exit codes the bin returns for a bad call and for a failed one', async () => {
  const { exit } = notifyCliContract();
  const err: string[] = [];
  assert.equal(await runPluginBin(plugin, ['send'], { out: () => undefined, err: (s) => err.push(s) }), exit.usage, err.join(''));
  assert.equal(await runPluginBin(plugin, ['test'], { out: () => undefined, err: () => undefined }), exit.error);
  assert.equal(exit.ok, 0);
});

test('every verb says what it does to the machine, and the one that serves until it is stopped is the only one a tool cannot answer', () => {
  const { commands } = notifyCliContract();
  assert.deepEqual(commands.filter((c) => c.effect === undefined).map((c) => c.path.join(' ')), []);
  assert.deepEqual(commands.filter((c) => c.effect === 'serve').map((c) => c.path.join(' ')), ['run']);
});
