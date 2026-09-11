// Is that process still there?
//
// `kill(pid, 0)` sends no signal, it only asks the kernel. EPERM means the
// process exists and belongs to somebody else — still alive, which is the
// question. Anything else (ESRCH, a nonsense pid) is dead.
export function isAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'EPERM';
  }
}
