// What tests/rust-session-parity.sh needs node for: the stub `claude` (the `fakeClaude` of packages/core/src/testkit.ts, a real executable that records what it was started with), the tree both programs work on, the form a stub's record is compared in, and the clock of the scenarios that are about time.
//
// Run: node tests/rust-session-parity-driver.mts stub <dir> <script> [<rec>]   writes <dir>/claude; <script> is the JSON text of a FakeScript, and <rec> the directory the stub records into
//      node tests/rust-session-parity-driver.mts tree <dir>                    writes the tree of the scenarios into <dir>
//      node tests/rust-session-parity-driver.mts record <file> <node-dir>      rewrites a stub's record so that two runs can be compared
//      node tests/rust-session-parity-driver.mts stamp <file>                  copies stdin to stdout and writes when each line of it arrived into <file>
import fs from 'node:fs';
import path from 'node:path';
import { fakeClaude, type FakeScript } from '../packages/core/src/testkit.ts';

const [what, dir, script, rec] = process.argv.slice(2);
const wellFormed =
  dir !== undefined && (what === 'tree' || what === 'stamp' || ((what === 'stub' || what === 'record') && script !== undefined));
if (!wellFormed) {
  process.stderr.write('usage: rust-session-parity-driver.mts stub <dir> <script> [<rec>] | tree <dir> | record <file> <node-dir> | stamp <file>\n');
  process.exit(2);
}

/** An assistant record whose content is these blocks. */
const assistant = (...blocks: unknown[]): string => JSON.stringify({ type: 'assistant', message: { content: blocks } });
const text = (t: string): unknown => ({ type: 'text', text: t });
const user = JSON.stringify({ type: 'user', message: { role: 'user', content: 'hello' } });
const tool = { type: 'tool_use', id: 't1', name: 'Bash', input: {} };

/** A transcript: its bytes, and the modification time in seconds with a fraction, so that `mtimeMs` is a double that has to be printed exactly. */
interface Transcript {
  readonly bytes: string | Buffer;
  readonly mtime: number;
}

const FILLER = `${JSON.stringify({ type: 'system', note: 'x'.repeat(1000) })}\n`;

const TRANSCRIPTS: Record<string, Transcript> = {
  'plain.jsonl': { bytes: [user, assistant(text('first')), assistant(tool), assistant(text('  the last reply  \n'))].join('\n') + '\n', mtime: 1700000000.123456 },
  'ru.jsonl': { bytes: [user, assistant(text('ответ: привет, мир 😀'))].join('\n') + '\n', mtime: 1700000001.5 },
  'no-newline.jsonl': { bytes: [user, assistant(text('no final newline'))].join('\n'), mtime: 1700000002.25 },
  'two-blocks.jsonl': { bytes: assistant(text('one'), text('two'), text('   ')) + '\n', mtime: 1700000003.000001 },
  'blank-text.jsonl': { bytes: [user, assistant(text('   '), text(''))].join('\n') + '\n', mtime: 1700000004 },
  'no-assistant.jsonl': { bytes: `${user}\n${JSON.stringify({ type: 'system' })}\n`, mtime: 1700000005 },
  'junk.jsonl': { bytes: `not json "assistant"\n{"type":"assistant"\n${assistant(text('after junk'))}\n[1,2,3] "assistant"\n`, mtime: 1700000006 },
  'empty.jsonl': { bytes: '', mtime: 1700000007 },
  // The escapes of lone and paired surrogates, written as text: `JSON.parse` turns each into the string it names.
  'lone-high.jsonl': { bytes: '{"type":"assistant","message":{"content":[{"type":"text","text":"a\\ud83dz"}]}}\n', mtime: 1700000008.5 },
  'lone-low.jsonl': { bytes: '{"type":"assistant","message":{"content":[{"type":"text","text":"\\ude00 end"}]}}\n', mtime: 1700000009.5 },
  'pair.jsonl': { bytes: '{"type":"assistant","message":{"content":[{"type":"text","text":"\\ud83d\\ude00 pair \\u00e9 \\u0000 \\u2028"}]}}\n', mtime: 1700000010.5 },
  'lone-and-trim.jsonl': { bytes: '{"type":"assistant","message":{"content":[{"type":"text","text":" \\ud83d "}]}}\n', mtime: 1700000011.5 },
  'controls.jsonl': { bytes: assistant(text('tab\there\nnewline "quoted" back\\slash \u0007 bell \u007f del')) + '\n', mtime: 1700000012 },
  // The tail window is the last 49152 bytes, cut at a byte and then at the first newline: a reply before it is not seen.
  'before-window.jsonl': { bytes: `${assistant(text('too early'))}\n${FILLER.repeat(60)}`, mtime: 1700000013 },
  'at-window.jsonl': { bytes: `${FILLER.repeat(60)}${assistant(text('inside the window'))}\n`, mtime: 1700000014 },
  // Invalid UTF-8 inside the window: one U+FFFD for each maximal bad sequence, and so for a cut in the middle of a character.
  'bad-utf8.jsonl': {
    bytes: Buffer.concat([Buffer.from('{"type":"assistant","message":{"content":[{"type":"text","text":"a'), Buffer.from([0xff, 0xc3]), Buffer.from('b"}]}}\n')]),
    mtime: 1700000015,
  },
  'cut-char.jsonl': { bytes: `${'é'.repeat(30000)}\n${assistant(text('after a cut'))}\n`, mtime: 1700000016 },
};

function materialise(root: string): void {
  for (const sub of ['home', 'tmp', 'rec', 'st', 'work', 'tr']) fs.mkdirSync(path.join(root, sub), { recursive: true });
  for (const [name, t] of Object.entries(TRANSCRIPTS)) {
    const file = path.join(root, 'tr', name);
    fs.writeFileSync(file, t.bytes);
    fs.utimesSync(file, t.mtime, t.mtime);
  }
  fs.mkdirSync(path.join(root, 'tr', 'a-directory.jsonl'));
}

/**
 * A record of the stub in the form two runs are compared in. The order of the environment is not a promise of either program, so the names are sorted. The first entry of `PATH` is the directory of the node that serves the run, which differs between the two programs by construction: it reads `<node-dir>` only when it is the one this run must have, so a wrong directory stays and the comparison fails.
 */
function normaliseRecord(file: string, nodeDir: string): void {
  const record = JSON.parse(fs.readFileSync(file, 'utf8')) as { argv: string[]; cwd: string; stdin: string; env: Record<string, string> };
  const env = Object.fromEntries(Object.entries(record.env).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  const entries = (env['PATH'] ?? '').split(':');
  if (entries[0] === nodeDir) env['PATH'] = ['<node-dir>', ...entries.slice(1)].join(':');
  fs.writeFileSync(file, `${JSON.stringify({ argv: record.argv, cwd: record.cwd, stdin: record.stdin, env }, null, 1)}\n`);
}

/** Stdin to stdout, byte for byte, and to `file` one line per line that arrived: the time in milliseconds and the line. `open` and `end` are the times of the first and of the last moment. */
function stamp(file: string): void {
  const stamps = fs.openSync(file, 'w');
  fs.writeSync(stamps, `${Date.now()} open\n`);
  let pending = '';
  process.stdin.on('data', (chunk: Buffer) => {
    process.stdout.write(chunk);
    pending += chunk.toString('latin1');
    const lines = pending.split('\n');
    pending = lines.pop() ?? '';
    const now = Date.now();
    for (const line of lines) fs.writeSync(stamps, Buffer.from(`${now} ${line}\n`, 'latin1'));
  });
  process.stdin.on('end', () => {
    const now = Date.now();
    if (pending) fs.writeSync(stamps, Buffer.from(`${now} ${pending}\n`, 'latin1'));
    fs.writeSync(stamps, `${now} end\n`);
    fs.closeSync(stamps);
  });
}

if (what === 'stub') {
  fs.mkdirSync(dir, { recursive: true });
  const plan = JSON.parse(script ?? '{}') as FakeScript;
  const recording = rec === undefined ? {} : { argvFile: path.join(rec, 'argv.json'), countFile: path.join(rec, 'count'), pidFile: path.join(rec, 'pid') };
  fakeClaude({ ...plan, ...recording }, dir);
} else if (what === 'record') {
  normaliseRecord(dir, script ?? '');
} else if (what === 'stamp') {
  stamp(dir);
} else {
  materialise(dir);
}
