// The inputs of tests/rust-knowledge-parity.sh that a shell cannot write well: documents with characters in them, and the script of one request per code point of a sweep. It runs no server: tests/rust-mcp-parity-driver.mts does, for both programs.
//
//   node tests/rust-knowledge-parity-driver.mts extras <docs dir>
//   node tests/rust-knowledge-parity-driver.mts sweep <docs dir> <script out> <map out>
//   node tests/rust-knowledge-parity-driver.mts locate <map> <request id>
//   node tests/rust-knowledge-parity-driver.mts client <socket> [connected file]
//
// `extras` adds the documents the fixtures lack: diacritics, two documents that rank alike, a deprecated one, a type in capitals and the legacy `kind`.
// `sweep` writes one document that holds `a<c>b` for each code point c of a list of ranges, and a script, in the steps of the MCP driver, that searches for each of them; the map says which request stands for which code point, so that a difference is named by its code point.
// `locate` prints the code point of a request of the map.
// `client` is a client of a unix socket that behaves the same on macOS and Linux, where `nc -U` does not (the Linux one stays connected past the end of its input unless it is given -N, which the macOS one does not have): what comes in goes to the socket and the end of the input ends the writing side only, what the socket says goes out, and the end of the socket ends the client. The optional file appears when the connection is made. The exit is 1 when it cannot connect or the socket fails.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';

const [command, ...args] = process.argv.slice(2);

const document = (front: Record<string, string>, body: string): string => `---\n${Object.entries(front).map(([key, value]) => `${key}: ${value}`).join('\n')}\n---\n\n${body}\n`;

function extras(dir: string): void {
  const write = (name: string, text: string): void => fs.writeFileSync(path.join(dir, name), text);
  write('cafe-notes.md', document({ id: 'cafe-notes', title: 'Café notes', kind: 'note', tags: '[food, café]', updated: '2026-09-12' }, 'Crème brûlée at the café, naïve résumé of Zoë and a São Paulo façade.\n\n## Ünïcode heading\n\nÅngström, Łódź, İstanbul and straße all live here.'));
  write('tie-one.md', document({ id: 'tie-one', title: 'Tie', kind: 'note', tags: '[tie]', updated: '2026-09-12' }, 'The word marmalade appears once here.'));
  write('tie-two.md', document({ id: 'tie-two', title: 'Tie', kind: 'note', tags: '[tie]', updated: '2026-09-12' }, 'The word marmalade appears once here.'));
  write('tie-three.md', document({ id: 'tie-three', title: 'Tie', kind: 'note', tags: '[tie]', updated: '2026-09-12' }, 'The word marmalade appears once here.'));
  write('old-marmalade.md', document({ id: 'old-marmalade', title: 'Old marmalade', kind: 'note', tags: '[tie]', status: 'deprecated', updated: '2026-01-01' }, 'Marmalade marmalade marmalade, retired.'));
  write('capital-type.md', document({ id: 'capital-type', title: 'Capital type', type: 'Runbook', tags: '[ops]', updated: '2026-09-12' }, 'A runbook whose type is written in capitals.'));
  write('legacy-kind.md', document({ id: 'legacy-kind', title: 'Legacy kind', kind: 'runbook', tags: '[ops]', updated: '2026-09-12' }, 'A runbook with the legacy kind field.'));
}

const RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x21, 0x7e],
  [0xa0, 0x24f],
  [0x2b0, 0x36f],
  [0x370, 0x3ff],
  [0x400, 0x52f],
  [0x1e00, 0x1eff],
  [0x2000, 0x206f],
  [0x3040, 0x3060],
  [0x4e00, 0x4e20],
  [0xff10, 0xff5a],
  [0x1f600, 0x1f610],
];

function sweep(dir: string, scriptOut: string, mapOut: string): void {
  const lines: string[] = [];
  const steps: string[] = [];
  const map: Record<number, string> = {};
  let id = 100;
  for (const [from, to] of RANGES) {
    for (let cp = from; cp <= to; cp++) {
      const word = `a${String.fromCodePoint(cp)}b`;
      lines.push(word);
      id += 1;
      map[id] = `U+${cp.toString(16).toUpperCase().padStart(4, '0')}`;
      const message = { jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'knowledge_search', arguments: { query: word, limit: 50 } } };
      steps.push(JSON.stringify({ send: message }), JSON.stringify({ answered: [id] }));
    }
  }
  fs.writeFileSync(path.join(dir, 'sweep.md'), document({ id: 'sweep', title: 'Sweep', kind: 'note', tags: '[sweep]', updated: '2026-09-12' }, lines.map((word) => `${word} ${word}`).join('\n\n')));
  fs.writeFileSync(scriptOut, steps.join(',\n'));
  fs.writeFileSync(mapOut, JSON.stringify(map));
}

function locate(mapFile: string, id: string): void {
  const parsed: unknown = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
  const found = typeof parsed === 'object' && parsed !== null ? Object.entries(parsed).find(([key]) => key === id) : undefined;
  process.stdout.write(`${found === undefined ? 'unknown request' : String(found[1])}\n`);
}

function client(socketPath: string, connectedFile: string | undefined): void {
  const socket = net.createConnection({ path: socketPath }, () => {
    if (connectedFile !== undefined) fs.writeFileSync(connectedFile, '');
  });
  process.stdin.pipe(socket);
  socket.pipe(process.stdout);
  socket.on('end', () => process.exit(0));
  socket.on('error', () => process.exit(1));
}

if (command === 'extras' && args.length === 1 && args[0] !== undefined) extras(args[0]);
else if (command === 'sweep' && args.length === 3 && args[0] !== undefined && args[1] !== undefined && args[2] !== undefined) sweep(args[0], args[1], args[2]);
else if (command === 'locate' && args.length === 2 && args[0] !== undefined && args[1] !== undefined) locate(args[0], args[1]);
else if (command === 'client' && args.length <= 2 && args[0] !== undefined) client(args[0], args[1]);
else {
  process.stderr.write('usage: rust-knowledge-parity-driver.mts extras <docs dir> | sweep <docs dir> <script out> <map out> | locate <map> <id> | client <socket> [connected file]\n');
  process.exit(2);
}
