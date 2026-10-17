// The boundary between the engine and whatever puts a banner on a screen.
//
// The engine depends on `Notifier`, the feed, the options, a clock and the
// screen probe, and on nothing platform-specific. Adding Linux is a
// `platform/linux/` directory and one line in `pickPlatform`.
import type { NoticeKind } from './kinds.ts';

export interface ClickAction {
  readonly argv: readonly string[];                 // absolute program first; empty = terminal only
  readonly env: Readonly<Record<string, string>>;
}
export interface Notice {
  readonly id: string;
  readonly thread: string;
  readonly kind: NoticeKind;
  readonly title: string;
  readonly subtitle: string;
  readonly body: string;
  readonly click: ClickAction;
  readonly terminalPid?: number;
  readonly skipIfFrontmost?: boolean;
}
export interface PostResult { readonly shown: boolean; readonly why?: string }
export interface Notifier {
  readonly name: string;
  post(n: Notice): Promise<PostResult>;
  withdraw(id: string): Promise<void>;
}
export interface RunSpec { readonly program: string; readonly args: readonly string[]; readonly env: Readonly<Record<string, string>>; readonly logFile: string }
export interface ServiceStatus { readonly installed: boolean; readonly running: boolean; readonly pid?: number; readonly detail: string }
export interface ServiceManager {
  install(run: RunSpec): Promise<void>;
  uninstall(): Promise<void>;
  status(): Promise<ServiceStatus>;
}
export interface Platform {
  readonly name: string;
  readonly notifier: Notifier;
  readonly service: ServiceManager | null;          // null: no supervisor support on this OS yet
  setup?(log: (...parts: string[]) => void): Promise<string>;   // macOS: build the app, ask for permission
  permission?(): Promise<string>;                   // authorized | denied | notDetermined | provisional | ephemeral
}
