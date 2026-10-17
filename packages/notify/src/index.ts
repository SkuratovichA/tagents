// The public surface of @tagents/notify: the plugin itself, and the types a new
// notification backend is written against. The host does not come through
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
export type { NotifyOptions } from './options.ts';
