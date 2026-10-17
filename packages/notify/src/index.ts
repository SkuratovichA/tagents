// The public surface of @tagents/notify: the plugin itself, the types a new
// notification backend is written against, and the options schema. The host does not come through
// here: it imports the plugin from the "tagents" entry in package.json.
export { default } from './plugin.ts';
export type { NoticeKind } from './kinds.ts';
export type {
  ClickAction,
  Notice,
  Notifier,
  Platform,
  PostResult,
  RunSpec,
  ServiceManager,
  ServiceStatus,
} from './notifier.ts';
// The schema beside its type: `NotifyOptions` is derived from it, so a reader follows it to see the keys, and a
// hand-written interface would be a second copy of them.
export { NotifyOptionsSchema, type NotifyOptions } from './options.ts';
