// Atomic file replace, same as orchestrator/src/atomic.ts.
//
// A reader in another process (the bash dashboard, another CLI invocation) must
// see either the old file or the new one, never a truncated or half-written
// file. Write to a temp name in the SAME directory — rename() is atomic only
// within one filesystem — and move it into place.
import fs from 'node:fs';

export function writeAtomic(file: string, data: string): void {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}
