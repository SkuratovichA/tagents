// Not a *.test.ts file: a daemon for shared-server.test.ts to start as a child, whose servers fail on purpose.
//
//   connection 1  the server cannot be made at all (a throw while the connection is being set up)
//   connection 2  an exception that nothing catches, thrown from a timer after the server was made
//   connection 3  a promise that rejects with nobody listening
//   after that    a server like any other
//
// The test opens one connection after another and expects the daemon to have survived all of them.
import { runDaemon } from '../src/mcp/daemon.ts';
import { createServer } from '../src/mcp/server.ts';

const socket = process.argv[2];
if (socket === undefined) throw new Error('usage: daemon-faulty.ts <socket>');

let connections = 0;
await runDaemon({
  socket,
  idleMs: 60000,
  makeServer: (env) => {
    connections += 1;
    if (connections === 1) throw new Error('no server for this connection');
    if (connections === 2) setTimeout(() => { throw new Error('thrown from a timer'); }, 0);
    if (connections === 3) void Promise.reject(new Error('rejected, and nobody asked'));
    return createServer(env);
  },
});
