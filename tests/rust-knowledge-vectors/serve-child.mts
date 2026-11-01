// Runs in a child process: `main` of the node CLI with the arguments of the case, its exit code and what it wrote on standard error, as JSON on stdout. The case names a socket under a regular file, so a valid argument list fails at once with the line `serveFailed` and no server is started.
import { main } from '../../packages/knowledge/src/cli/main.ts';

const args: unknown = JSON.parse(process.argv[2] ?? '[]');
if (!Array.isArray(args) || !args.every((a): a is string => typeof a === 'string')) throw new Error('the arguments are a list of strings');
let out = '';
let err = '';
const code = await main(args, {
  out: (s) => {
    out += s;
  },
  err: (s) => {
    err += s;
  },
});
process.stdout.write(JSON.stringify({ exit: code, stdout: out, stderr: err }));
process.exit(0);
