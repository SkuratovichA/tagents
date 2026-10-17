import fs from 'node:fs';
import path from 'node:path';

/**
 * The first `name` on `pathVar` that is an executable file, the one the shell
 * would pick; null when there is none. Answered by looking, never by running it.
 */
export function findOnPath(name: string, pathVar: string | undefined = process.env['PATH']): string | null {
  for (const dir of (pathVar ?? '').split(path.delimiter)) {
    if (dir === '') continue;
    const file = path.join(dir, name);
    try {
      fs.accessSync(file, fs.constants.X_OK);
      if (fs.statSync(file).isFile()) return file;
    } catch {
      // not in this directory
    }
  }
  return null;
}
