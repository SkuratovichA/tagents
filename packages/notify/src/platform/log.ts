// The backend that posts nothing and says so: for `backend: log`, for a machine
// whose notifier is not written yet, and for seeing what the engine would have
// said before a real banner is involved.
import type { Notifier } from '../notifier.ts';

export function createLogNotifier(log: (...parts: string[]) => void): Notifier {
  return {
    name: 'log',
    async post(n) {
      // One line per notice, text as JSON so a multi-line body stays on it.
      log(
        'post',
        n.id,
        n.kind,
        JSON.stringify(n.title),
        JSON.stringify(n.subtitle),
        JSON.stringify(n.body),
        n.click.argv.length === 0 ? 'click=terminal' : `click=${n.click.argv.join(' ')}`,
        n.terminalPid === undefined ? 'pid=none' : `pid=${n.terminalPid}`,
        n.skipIfFrontmost === true ? 'skip-if-frontmost' : 'always'
      );
      return { shown: true };
    },
    async withdraw(id) {
      log('withdraw', id);
    },
  };
}
