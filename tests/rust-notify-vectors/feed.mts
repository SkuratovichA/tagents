// The feed section of the notify vectors: state files to rows and labels, event lines to events, and bytes to text (`agent-state.ts`, `agent-events.ts`).
//
// The sources are imported by their paths: the root of the repository has no node_modules to resolve `@tagents/core` from.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseEventLine } from '../../packages/core/src/agent-events.ts';
import { labelsBySession, parseStateLine, readAgentState, readLabels } from '../../packages/core/src/agent-state.ts';
import type { AgentStateRow } from '../../packages/core/src/agent-state.ts';

const TAB = '\t';

/** The 13 fields of an events line, in the order the hook writes them. */
const EVENT_FIELDS = ['at', 'event', 'key', 'sessionId', 'agentId', 'pane', 'cwd', 'transcript', 'configDir', 'tool', 'sub', 'text', 'label'] as const;
type EventField = (typeof EVENT_FIELDS)[number];

const GOOD_EVENT: Record<EventField, string> = {
  at: '1760000000',
  event: 'Stop',
  key: '12',
  sessionId: 'sess-a',
  agentId: '',
  pane: '%12',
  cwd: '/Users/demo/git/demo',
  transcript: '/Users/demo/.claude/projects/-Users-demo-git-demo/sess-a.jsonl',
  configDir: '',
  tool: '',
  sub: '',
  text: 'Done',
  label: 'dashboard',
};

function eventLine(over: Partial<Record<EventField, string>> = {}): string {
  return EVENT_FIELDS.map((f) => over[f] ?? GOOD_EVENT[f]).join(TAB);
}

/** The lines of the events section: what the follower hands the parser is a line without its newline. */
function eventLines(): string[] {
  const good = eventLine();
  const lines = [
    good,
    eventLine({ at: '1760000000.123', event: 'Notification', agentId: 'agent-9', tool: 'Bash', sub: 'sub', text: 'Claude needs your permission to use Bash', configDir: '/Users/demo/.claude-work' }),
    eventLine({ key: 's-sess-b', pane: '', label: '' }),
    eventLine({ text: 'Готово… ждёт ответа 🙂', cwd: '/tmp/ünïcode dir' }),
    eventLine({ text: ' leading and trailing spaces ', label: ' x ' }),
    eventLine({ key: '', sessionId: '', cwd: '', transcript: '', text: '', label: '' }),
    // The 13 fields of the hook, one fewer, and more.
    good.slice(0, good.lastIndexOf(TAB)),
    good.split(TAB).slice(0, 11).join(TAB),
    good.split(TAB).slice(0, 2).join(TAB),
    `${good}${TAB}extra`,
    `${good}${TAB}extra${TAB}and more${TAB}`,
    `${good}${TAB}${TAB}${TAB}`,
    // A trailing carriage return: one is dropped, a second is part of the last field, one in the middle stays.
    `${good}\r`,
    `${good}\r\r`,
    `${eventLine({ label: '' })}\r`,
    `${eventLine({ text: 'in\rthe middle' })}`,
    `${good}${TAB}extra\r`,
    '',
    '\r',
    'not an event',
    TAB.repeat(12),
    TAB.repeat(13),
  ];
  for (const event of ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification', 'Stop', 'SubagentStop', 'SessionEnd']) {
    lines.push(eventLine({ event }));
  }
  // Names the hook does not write, among them the ones an object would answer to.
  for (const event of ['PreCompact', 'stop', 'STOP', ' Stop', 'Stop ', '', 'toString', '__proto__', 'constructor', 'hasOwnProperty', 'valueOf', 'Stopp', 'SessionEnd\n']) {
    lines.push(eventLine({ event }));
  }
  // Times: what `Number()` reads, and what `.trim()` makes empty.
  const times = [
    '0', '-1', '+5', '17', '007', '.5', '5.', '1e3', '1E3', '1e-3', '0x10', '0X1f', '0b11', '0o7', '0B2', '0xg', '0x', '1e', '--1', '1 2', '1_000', '12abc', 'abc',
    '1760000000.123456', '1760000000123456789', '1e305', '1e999', '-1e999', 'Infinity', '-Infinity', '+Infinity', 'infinity', 'NaN', 'nan', 'inf',
    ' 12 ', '12 ', ' 12', '', ' ', '  ', '\u{a0}', '\u{a0}12\u{a0}', '\u{feff}12', '\u{2028}', '\u{2029} 5', '\u{3000}', '\u{200b}12', '\u0085 12', '\u000b12\u000c', '١٢٣', '１２', '9007199254740993', '0.1', '0.000001', '1e21',
  ];
  for (const at of times) lines.push(eventLine({ at }));
  return lines;
}

const eventVectors = (): unknown =>
  eventLines().map((line) => ({ line, event: parseEventLine(line) }));

/** The seven columns of a state row the Rust copy reads: the account is null for a row written before the column existed. */
function rowOf(r: AgentStateRow): Record<string, unknown> {
  return {
    key: r.key,
    at: r.at,
    state: r.state,
    sessionId: r.sessionId,
    cwd: r.cwd,
    transcript: r.transcript,
    detail: r.detail,
    configDir: r.hasConfigDir ? r.configDir : null,
  };
}

const row = (...fields: string[]): string => fields.join(TAB);

/** Lines of one state row, as `parseStateLine(key, line)` is called with them. */
function stateLines(): { key: string; line: string }[] {
  const full = ['1760000000', 'working', 'sess-a', '/Users/demo/git/demo', '/t/sess-a.jsonl', 'Bash ls', '', '4242', '/tmp/log', 'name', 's-parent', 'parent-sid'];
  const lines: string[] = [];
  // Every column count from 1 to 14, so the cut-offs at 6, 7 and the columns past them are all there.
  for (let n = 1; n <= 14; n++) lines.push(full.concat(['x', 'y']).slice(0, n).join(TAB));
  for (const state of ['new', 'working', 'blocked', 'done', 'gone', 'subdone', 'Working', 'DONE', '', 'toString', '__proto__', 'running', 'subdone ', ' new']) {
    lines.push(row('1760000000', state, 's', '/c', '/t', 'd'));
  }
  const times = ['0', '-1', '17', '.5', '1e3', '0x10', '0b11', '1_0', 'abc', '', ' ', '\u{a0}', '\u{feff}12', '12 ', 'Infinity', '-Infinity', 'NaN', '1e999', '1760000000.5', '1e305', '٣'];
  for (const at of times) lines.push(row(at, 'done', 's', '/c', '/t', 'd'));
  // One trailing newline is dropped and no more; a carriage return is part of the last field.
  lines.push(`${row('1', 'done', 's', '/c', '/t', 'd')}\n`);
  lines.push(`${row('1', 'done', 's', '/c', '/t', 'd')}\n\n`);
  lines.push(`${row('1', 'done', 's', '/c', '/t', 'd')}\r`);
  lines.push(`${row('1', 'done', 's', '/c', '/t', 'd', 'acct')}\n`);
  lines.push(`${row('1', 'done', 's', '/c', '/t', 'd', '')}\n`);
  lines.push(`${row('1', 'done', 's', '/c', '/t')}\n`);
  lines.push(row('1', 'done', 'Сессия', '/ünï', '/t', 'Готово… 🙂', '/Users/демо/.claude'));
  lines.push('');
  lines.push('nope');
  return lines.map((line, i) => ({ key: i % 2 === 0 ? '12' : 's-sess-b', line }));
}

const stateLineVectors = (): unknown =>
  stateLines().map(({ key, line }) => {
    const parsed = parseStateLine(key, line);
    return { key, line, row: parsed ? rowOf(parsed) : null };
  });

interface DirCase {
  readonly name: string;
  /** file name → text, written to a directory of its own. Null: no directory at all. */
  readonly files: Record<string, string> | null;
}

const work = '/Users/demo/git/demo';
const published: Record<string, string> = {
  '12.tsv': `${row('1760000000', 'working', 'sess-a', work, '/Users/demo/.claude/projects/-Users-demo-git-demo/sess-a.jsonl', 'Bash ls', '')}\n`,
  's-sess-b.tsv': `${row('1760000100', 'blocked', 'sess-b', '/Users/demo/git/other', '', 'Claude needs your permission to use Bash', '/Users/demo/.claude-work', '4242')}\n`,
  '13.tsv': `${row('1759000000', 'done', 'sess-c', '', '', '')}\n`,
  's-sess-d.tsv': `${row('1760000050', 'working', 'sess-d', work, '', '', '', '5151', '/tmp/ticket-agent.log', 'ticket-agent')}\n`,
  's-sess-e.tsv': `${row('1760000060', 'working', 'sess-e', '/Users/demo/git/scratch', '', '', '', '5252', '', '', 's-sess-d', 'sess-d')}\n`,
  'not-a-key.tsv': 'garbage\n',
  'history.tsv': [
    row('1760000000', 'start', 'sess-a', '%12', 'dashboard', work),
    row('1760000100', 'start', 'sess-b', '%0', 'tg-orchestrator', '/Users/demo/git/other'),
    row('1760000200', 'turn', 'sess-b', '%0', 'tg-orchestrator', '/Users/demo/git/other'),
    row('1760000300', 'start', 'sess-e', '', '', '/Users/demo/git/scratch', 'sess-d'),
  ].join('\n') + '\n',
};

const same = (name: string): string => `${row('1760000000', 'done', name, '', '', '')}\n`;
const sameTime: Record<string, string> = Object.fromEntries(['s-a', '5', '10', 's-B', '9', '0', '100', 's-_', 's-.', 's--', 's-1'].map((k) => [`${k}.tsv`, same(k)]));

/** File names that are keys and names that are not. No two differ only in case: the generator also runs on file systems that fold it. */
const names = ['12', '0', '007', 's-a.b_c-d', 's-', '1a', 's-a b', 'S-x', 's-é', '٣', '-1', '', '12.tsv', 's-x/y', 'not-a-key', 's-ünï', '１２', 's-Ж'];
const keyFiles: Record<string, string> = {
  ...Object.fromEntries(names.filter((n) => !n.includes('/')).map((n) => [`${n}.tsv`, same(n)])),
  '12tsv': same('12tsv'),
  '12.tsv.bak': same('12'),
  '.tsv': same('x'),
  '5.tsv.tsv': same('5'),
};

const historyLines = [
  row('1', 'start', 'x', '%1', 'first', '/c'),
  row('2', 'turn', 'x', '%1', 'second', '/c'),
  row('3', 'end', 'x', '%1', '', '/c'),
  row('4', 'bogus', 'x', '%1', 'bogus kind', '/c'),
  row('nan', 'start', 'x', '%1', 'bogus time', '/c'),
  row('5', 'start', 'x', '%1', 'short'),
  row('6', 'start', '', '%1', 'no session', '/c'),
  '',
  row('7', 'start', 'y', '%1', 'other', '/c', 'parent'),
  row('', 'start', 'z', '%1', 'empty time is zero', '/c'),
  row('0x10', 'turn', 'w', '%1', 'hex time', '/c'),
  row('Infinity', 'start', 'v', '%1', 'infinite time', '/c'),
  row('8', 'Start', 'u', '%1', 'kind in capitals', '/c'),
  row('9', 'start', 't', '%1', 'with cr', '/c\r'),
  row('10', 'end', 'ünï', '%1', 'Готово 🙂', '/c'),
  row('11', 'start', 'x', '', 'third', '', 'p1', 'p2'),
];

const labelLines = [
  'sess-a\tRenamed agent',
  '%12\tpane name',
  'no-tab-here',
  '\tno key',
  'sess-b\t',
  'sess-a\tlater line',
  'sess-c\tname\textra',
  'k\t',
  'k\tx',
  '',
  ' \tblank key',
  'cr\tname\r',
  '%1\tПривет 🙂',
  'sess-d\t \t',
];

const dirCases: DirCase[] = [
  { name: 'a directory that does not exist', files: null },
  { name: 'an empty directory', files: {} },
  { name: 'what the hook published', files: published },
  { name: 'rows with one time keep the order of their names', files: sameTime },
  { name: 'which file names are keys', files: keyFiles },
  { name: 'an upper case extension is not .tsv', files: { '12.TSV': same('12') } },
  { name: 'only the first line of a row file counts', files: { '7.tsv': `${row('1', 'done', 's', '/c', '/t', 'first')}\n${row('2', 'working', 't', '/c', '/t', 'second')}\n` } },
  { name: 'a row file with no newline, with a carriage return, empty, and with a byte order mark', files: {
    '1.tsv': row('1', 'done', 's', '/c', '/t', 'no newline'),
    '2.tsv': `${row('2', 'done', 's', '/c', '/t', 'cr')}\r\n`,
    '3.tsv': '',
    '4.tsv': `\u{feff}${row('4', 'done', 's', '/c', '/t', 'bom')}\n`,
    '5.tsv': `\n${row('5', 'done', 's', '/c', '/t', 'a blank first line')}\n`,
  } },
  { name: 'history of starts and turns', files: { 'history.tsv': `${historyLines.join('\n')}\n` } },
  { name: 'history without a final newline, and with carriage returns', files: { 'history.tsv': historyLines.join('\r\n') } },
  { name: 'labels typed by the owner', files: { 'labels.tsv': `${labelLines.join('\n')}\n` } },
  { name: 'labels with carriage returns and no final newline', files: { 'labels.tsv': labelLines.join('\r\n') } },
  { name: 'a directory where a file should be', files: { '8.tsv/inner': 'x', 'history.tsv/inner': 'x', 'labels.tsv/inner': 'x' } },
];

/** Write the files of a case into a fresh directory; a name with a slash is a file in a directory. */
function build(dir: string, files: Record<string, string>): void {
  for (const [name, text] of Object.entries(files)) {
    const file = path.join(dir, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
  }
}

function dirVectors(): unknown {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-feed-vectors-'));
  try {
    return dirCases.map((c, i) => {
      const dir = path.join(root, `case-${i}`);
      if (c.files) {
        fs.mkdirSync(dir);
        build(dir, c.files);
      }
      return {
        name: c.name,
        files: c.files,
        rows: readAgentState(dir).map(rowOf),
        labelsBySession: Object.fromEntries(labelsBySession(dir)),
        labels: Object.fromEntries(readLabels(dir)),
      };
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

/** What `Buffer.toString('utf8')` makes of bytes, where they are not UTF-8: the follower and the row reader rely on it being what Rust's lossy decoding makes. */
const BYTES = [
  '', '41', 'e282ac', 'ff', '80', 'bf', 'c0', 'c080', 'c0af', 'c1bf', 'c2', 'c2c2', 'c2a9', 'e2', 'e282', 'e282e282ac', 'e28241', 'e0', 'e08080', 'e0a080', 'e09f80',
  'eda080', 'edbfbf', 'ed9fbf', 'ef', 'efbbbf41', 'efbfbd', 'f0', 'f09f', 'f09f98', 'f09f9880', 'f0808080', 'f08f8080', 'f48f8080', 'f4908080', 'f5808080', 'f8888080', 'fc',
  '4180', '4180ff42', '80808080', 'ff00ff', '0a41', '41e2828a42', 'e282acff', 'f09f9880f09f98', 'c3a9', 'c3', 'c328', '4100',
];

const decodeVectors = (): unknown =>
  BYTES.map((hex) => ({ hex, text: Buffer.from(hex, 'hex').toString('utf8') }));

export async function feedVectors(): Promise<unknown> {
  return {
    eventLines: eventVectors(),
    stateLines: stateLineVectors(),
    stateDirs: dirVectors(),
    decode: decodeVectors(),
  };
}
