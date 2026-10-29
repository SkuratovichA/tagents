import { readdir } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'

/** Every file under `dir`, as sorted posix paths relative to it. */
export async function listFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { recursive: true, withFileTypes: true })
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => relative(dir, join(entry.parentPath, entry.name)).split(sep).join('/'))
    .sort()
}
