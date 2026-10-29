// Every verb of `tagents-notify` as data, in English, for the contract generator: a line here is a tool in the plugin. test/cli-spec.test.ts pins it to the verbs plugin.ts defines, so a verb added there without a line here fails a test.
import type { CliContract } from '@tagents/core';

export const NOTIFY_COMMANDS = [
  {
    path: ['run'],
    positionals: [],
    options: {},
    required: [],
    summary: 'runs the notification service in the foreground until it is stopped',
    effect: 'serve',
  },
  {
    path: ['install'],
    positionals: [],
    options: {},
    required: [],
    summary: 'installs and starts the notification service as a login item, builds its helper app and asks macOS for permission to notify',
    effect: 'spawn',
  },
  {
    path: ['uninstall'],
    positionals: [],
    options: { purge: { type: 'boolean' } },
    required: [],
    summary: 'stops and removes the notification service; with purge it also deletes the helper app',
    effect: 'destructive',
  },
  {
    path: ['status'],
    positionals: [],
    options: {},
    required: [],
    summary: 'prints whether notifications will arrive: the service, the permission, the options and the click script',
    effect: 'read',
  },
  {
    path: ['test'],
    positionals: [],
    options: { kind: { type: 'string' } },
    required: [],
    summary: 'posts one sample notice of the given kind through the configured backend, which shows it on the screen',
    effect: 'write',
  },
  {
    path: ['send'],
    positionals: ['<message>'],
    options: { title: { type: 'string' } },
    required: [],
    summary: 'posts a desktop notification with this message through the configured backend, which shows it on the screen; a click docks the pane the command runs in',
    effect: 'write',
  },
] as const satisfies CliContract['commands'];

/** The exit codes `runPluginBin` gives these verbs: 0 done, 1 failed, 2 not understood. */
export const NOTIFY_EXIT = { ok: 0, error: 1, usage: 2 } as const;

export function notifyCliContract(): CliContract {
  return { program: 'tagents-notify', exit: NOTIFY_EXIT, commands: NOTIFY_COMMANDS };
}
