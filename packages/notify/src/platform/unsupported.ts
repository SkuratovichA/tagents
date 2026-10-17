// The platform of a machine whose notifier is not written yet: it refuses to
// post and says why, instead of the engine silently dropping notices.
import type { Platform } from '../notifier.ts';

export function createUnsupportedPlatform(os: string): Platform {
  const refuse = (): Promise<never> => Promise.reject(new Error(`no notification backend for ${os} yet`));
  return {
    name: 'unsupported',
    notifier: { name: 'unsupported', post: refuse, withdraw: refuse },
    service: null,
  };
}
