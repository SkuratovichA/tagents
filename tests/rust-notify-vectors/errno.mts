// The errno section of the notify vectors: node's text for each error the Rust daemon names (`util.getSystemErrorMap()`, which `fs` and `child_process` errors take their `code` and message from). The names and texts are libuv's and do not depend on the system the file is written on.
import { getSystemErrorMap } from 'node:util';

// The codes of `ERRNOS` in `crates/tagents-core/src/node.rs`, whose numbers are the same on Linux and macOS. The Rust test fails when the table and this list differ in either direction.
const CODES = ['ENOENT', 'EIO', 'E2BIG', 'ENOEXEC', 'ENOMEM', 'EACCES', 'ENOTDIR', 'EISDIR', 'EMFILE', 'ETXTBSY'];

export async function errnoVectors(): Promise<unknown> {
  const byCode = new Map([...getSystemErrorMap()].map(([, [code, message]]) => [code, message]));
  return CODES.map((code) => {
    const message = byCode.get(code);
    if (message === undefined) throw new Error(`node has no error named ${code}`);
    return { code, message };
  });
}
