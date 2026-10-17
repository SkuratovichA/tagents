// The one place that knows which platforms exist. Adding Linux is a
// `platform/linux/` directory and one line in `pickPlatform`; the engine only
// ever sees a `Notifier`.
import type { Exec } from '../exec.ts';
import type { Platform } from '../notifier.ts';
import type { NotifyOptions } from '../options.ts';
import { appPath } from '../paths.ts';
import { createLogNotifier } from './log.ts';
import { appState, buildApp } from './macos/app.ts';
import { createHelperNotifier, helperAuthorize, helperStatus } from './macos/helper.ts';
import { createLaunchd } from './macos/launchd.ts';
import { createUnsupportedPlatform } from './unsupported.ts';

export interface PlatformDeps {
  readonly log: (...parts: string[]) => void;
  readonly exec?: Exec;
  readonly env?: NodeJS.ProcessEnv;
  readonly uid?: number;
  readonly home?: string;
}

function launchd(deps: PlatformDeps) {
  return createLaunchd({
    ...(deps.uid !== undefined ? { uid: deps.uid } : {}),
    ...(deps.home !== undefined ? { home: deps.home } : {}),
    ...(deps.exec !== undefined ? { exec: deps.exec } : {}),
  });
}

function macos(deps: PlatformDeps): Platform {
  const app = appPath(deps.env, deps.home);
  return {
    name: 'macos',
    notifier: createHelperNotifier({ app, ...(deps.exec !== undefined ? { exec: deps.exec } : {}) }),
    service: launchd(deps),
    async setup(log) {
      if ((await appState(app, deps.exec)) !== 'up to date') await buildApp(app, log, deps.exec);
      return helperAuthorize(app, deps.exec);
    },
    async permission() {
      return (await helperStatus(app, deps.exec)).status;
    },
  };
}

/** null when the backend is `none`: nothing posts. */
export function pickPlatform(
  os: NodeJS.Platform,
  backend: NotifyOptions['backend'],
  deps: PlatformDeps
): Platform | null {
  switch (backend) {
    case 'none':
      return null;
    case 'log':
      return {
        name: 'log',
        notifier: createLogNotifier(deps.log),
        service: os === 'darwin' ? launchd(deps) : null,
      };
    case 'auto':
    case 'macos':
      return os === 'darwin' ? macos(deps) : createUnsupportedPlatform(os);
  }
}
