import fs from 'node:fs';
import path from 'node:path';

/** Whether `file` is a regular file the caller may execute. Answered by looking, never by running it. */
export function isExecutableFile(file: string): boolean {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

/**
 * The first `name` on `pathVar` that is an executable file, the one the shell
 * would pick; null when there is none. Answered by looking, never by running it.
 */
export function findOnPath(name: string, pathVar: string | undefined = process.env['PATH']): string | null {
  for (const dir of (pathVar ?? '').split(path.delimiter)) {
    if (dir === '') continue;
    const file = path.join(dir, name);
    if (isExecutableFile(file)) return file;
  }
  return null;
}
