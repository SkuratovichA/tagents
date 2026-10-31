// The words section of the notify vectors: events to verdicts, the words of a notice, phrases in both locales and tmux answers (`kinds.ts`, `compose.ts`, `phrases.ts`, `screen.ts`), and `path.basename` for the inputs that `std::path::Path::file_name` gets wrong.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { AgentEvent } from '@tagents/core';
import { agentName, compose, untitle } from '../../packages/notify/src/compose.ts';
import { classify, countsSession } from '../../packages/notify/src/kinds.ts';
import { currentPhrases, phrasesFor } from '../../packages/notify/src/phrases.ts';
import { parseScreen } from '../../packages/notify/src/screen.ts';

type Hook = AgentEvent['event'];
type Locale = 'en' | 'ru';

// Written with fromCharCode: a backslash-u escape typed through an edit lands as the character itself.
const BOM = String.fromCharCode(0xfeff);
const DOTLESS_I = String.fromCharCode(0x131);
const ROCKET = String.fromCodePoint(0x1f680);
const LOCALES: readonly Locale[] = ['en', 'ru'];
const KINDS = ['question', 'permission', 'turn_done', 'cache_expiring', 'session_end'] as const;
const HOOKS: readonly Hook[] = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'Notification',
  'Stop',
  'SubagentStop',
  'SessionEnd',
];

function event(over: Partial<AgentEvent> = {}): AgentEvent {
  return {
    at: 1_700_000_000_000,
    event: 'Stop',
    key: '12',
    sessionId: 'sess-1',
    agentId: '',
    pane: '%12',
    cwd: '/work/proj',
    transcript: '',
    configDir: '',
    tool: '',
    sub: '',
    text: '',
    label: '',
    ...over,
  };
}

function verdictVectors() {
  const cases: AgentEvent[] = [];
  const keys = ['12', 's-abc'];
  for (const hook of HOOKS) {
    for (const key of keys) {
      switch (hook) {
        case 'PreToolUse':
        case 'PostToolUse':
          for (const tool of ['', 'AskUserQuestion', 'ExitPlanMode', 'Bash', 'askuserquestion'])
            for (const agentId of ['', 'agent-7']) cases.push(event({ event: hook, key, tool, agentId }));
          break;
        case 'Notification':
          for (const sub of ['', 'elicitation_dialog', 'permission_prompt', 'idle_prompt', 'auth_success', 'something_new'])
            for (const text of [
              '',
              'm',
              ' ',
              `${BOM} \n${BOM}`,
              `${BOM}x`,
              'waiting for your input',
              'Claude is Waiting For Your Input',
              `Wa${DOTLESS_I}ting for your input`,
              'WAITING FOR YOUR INPUT.',
            ])
              cases.push(event({ event: hook, key, sub, text }));
          break;
        case 'Stop':
        case 'SubagentStop':
          for (const agentId of ['', 'agent-7']) for (const sub of ['', 'Explore']) cases.push(event({ event: hook, key, agentId, sub }));
          break;
        default:
          cases.push(event({ event: hook, key, sub: hook === 'SessionEnd' ? 'logout' : '' }));
      }
    }
  }
  return cases.map((e) => ({ event: e, verdict: classify(e), counts: countsSession(e.key) }));
}

const noticeCwds = ['', '/work/proj', '/', '.', 'a/..', 'a/.', '/work/proj/', 'proj'];
const longTexts = [
  '',
  'Which one?',
  'x'.repeat(500),
  'y'.repeat(200),
  'y'.repeat(201),
  `${'a'.repeat(199)}${ROCKET}`,
  `${'a'.repeat(200)}${ROCKET}`,
  `${BOM}padded${BOM}`,
];

type TranscriptSpec = null | { missing: true } | { text: string };
const transcripts: TranscriptSpec[] = [
  null,
  { missing: true },
  { text: '' },
  { text: '\n\nFirst line\nsecond' },
  { text: `${BOM}\n ${BOM} \n${BOM}First${BOM}\nsecond` },
  { text: `${BOM}\n${BOM}` },
  { text: 'line one\r\nline two' },
  { text: 'x'.repeat(500) },
  { text: `${'a'.repeat(199)}${ROCKET}${ROCKET}` },
  { text: '   \n\t\n  ' },
];

interface ExtraSpec {
  plan?: boolean;
  idleMin?: number;
  leftMin?: number;
}

function noticeVectors() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rust-notify-words-'));
  try {
    const out: unknown[] = [];
    const add = (kind: (typeof KINDS)[number], locale: Locale, over: Partial<AgentEvent>, name: string, extra: ExtraSpec, spec: TranscriptSpec) => {
      let transcript = '';
      if (spec !== null && 'missing' in spec) transcript = '/nonexistent/t.jsonl';
      else if (spec !== null) {
        transcript = path.join(dir, `t${out.length}.jsonl`);
        const line = { type: 'assistant', message: { content: [{ type: 'text', text: spec.text }] } };
        fs.writeFileSync(transcript, `${JSON.stringify(line)}\n`);
      }
      const e = event({ ...over, transcript });
      out.push({ kind, locale, event: { ...e, transcript: '' }, transcript: spec, name, extra, composed: compose(kind, e, name, extra, phrasesFor(locale)) });
    };
    for (const kind of KINDS)
      for (const locale of LOCALES)
        for (const name of ['proj', 'build agent', ''])
          for (const cwd of noticeCwds) add(kind, locale, { cwd }, name, {}, null);
    for (const kind of KINDS)
      for (const locale of LOCALES)
        for (const text of longTexts) for (const sub of ['', 'logout', `${BOM}x`]) add(kind, locale, { text, sub }, 'proj', {}, null);
    for (const locale of LOCALES) {
      add('question', locale, {}, 'proj', { plan: true }, null);
      add('question', locale, {}, 'build agent', { plan: true }, null);
      add('question', locale, {}, 'proj', { plan: false }, null);
      for (const [idleMin, leftMin] of [[50, 10], [55, 0], [55, 1], [55, 5], [0, 0], [1, 59], [0.4, 0.5], [3, 1.5], [60, -3], [100000, 1e21], [1e-7, 0.000001]])
        add('cache_expiring', locale, {}, 'proj', { idleMin, leftMin }, null);
      add('cache_expiring', locale, {}, 'proj', { idleMin: 7 }, null);
      add('cache_expiring', locale, {}, 'proj', { leftMin: 7 }, null);
      add('cache_expiring', locale, {}, 'proj', {}, null);
      for (const spec of transcripts) {
        add('turn_done', locale, {}, 'proj', {}, spec);
        add('turn_done', locale, { text: 'Fresh answer' }, 'proj', {}, spec);
      }
    }
    return out;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const titles = [
  '✳ два слова',
  'два слова',
  '✳ Search index rebuild',
  'Search index rebuild',
  'A thing',
  '⚠️ two code points',
  ' leading space',
  'x',
  '',
  '✳  two spaces after the glyph',
  '7 days',
  'я иду',
  'é tout',
  'ω omega',
  '中 文',
  '· middle dot',
  '- dash',
  '⠂ braille spinner',
  '→ arrow',
  '🚀 rocket',
  '✳',
  '✳ ',
  `${BOM} word`,
  ...[0x1fff, 0x2000, 0x2bff, 0x2c00, 0x1efff, 0x1f000, 0x1ffff, 0x7f, 0x80].map((cp) => `${String.fromCodePoint(cp)} word`),
];

function nameVectors() {
  const base = { sessionId: 'sess-1', pane: '%12', paneTitle: '✳ pane title', label: 'ticket-agent', cwd: '/work/some-project', hostname: 'mbp.local' };
  const variants: Array<Partial<typeof base> & { labels?: Array<[string, string]> }> = [
    {},
    { labels: [['sess-1', 'by session'], ['%12', 'by pane']] },
    { labels: [['%12', 'by pane']] },
    { labels: [['sess-1', '']] },
    { labels: [['sess-1', ''], ['%12', 'by pane']] },
    { paneTitle: '' },
    { paneTitle: '', label: '' },
    { paneTitle: 'mbp.local' },
    { paneTitle: 'mbp' },
    { paneTitle: '', label: 'mbp' },
    { paneTitle: 'mbp.local', hostname: 'mbp' },
    { paneTitle: 'other', hostname: '' },
    { paneTitle: '', label: '', hostname: '' },
    { pane: '', paneTitle: '', labels: [['', 'must not be used']] },
    { sessionId: '', paneTitle: '', labels: [['', 'must not be used'], ['%12', 'by pane']] },
    ...['/', '', '/a/b/', 'a/..', 'a/.', '.'].map((cwd) => ({ paneTitle: '', label: '', cwd })),
  ];
  return variants.map((v) => {
    const { labels = [], ...over } = v;
    const inputs = { ...base, ...over };
    return { inputs, labels, name: agentName({ ...inputs, labels: new Map(labels) }) };
  });
}

const basenames = ['', '/', '//', '.', '..', './', 'a/.', '/.', 'a/..', '/a/b', '/a/b/', '/a/b//', 'a', 'a/', '/work/proj', 'dir/ünï', `${BOM}/x`, 'a b/c d', '/a/./b', '///a'];

function phraseVectors() {
  const tables = LOCALES.map((locale) => {
    const { cacheBody, ...texts } = phrasesFor(locale);
    const minutes: Array<[number, number]> = [[0, 0], [0, 1], [5, 0.5], [5, 1], [10, 2], [55, -1], [1.5, 2.5], [1e21, 1e21], [1e-7, 1e-7], [123456789, 987654321]];
    return { locale, texts, cache: minutes.map(([idle, left]) => ({ idle, left, text: cacheBody(idle, left) })) };
  });
  const values: Array<string | null> = [null, '', 'en', 'ru', 'EN', 'RU', 'ru ', ' ru', 'de', 'ru_RU', 'en-US'];
  const locales = values.map((value) => ({
    value,
    kindTurnDone: currentPhrases(value === null ? {} : { TAGENTS_LOCALE: value }).kindTurnDone,
  }));
  return { tables, locales };
}

const screens = [
  'P|@|@3|@|✳ build\nC|@|1700000100|@|4001|@|@3\nC|@|1700000200|@|4002|@|@1\n',
  'P|@|@3|@|build\nC|@|1700000100|@|4001|@|@1\nC|@|1700000900|@|4002|@|@2\nC|@|1700000500|@|4003|@|@1',
  'P|@|@3|@|build\nC|@|1700000100|@|4001|@|@3\nC|@|1700000900|@|4002|@|@3\nC|@|1700009999|@|4003|@|@9',
  'P|@|@3|@|build\nC|@|5|@|4001|@|@3\nC|@|5|@|4002|@|@3',
  'P|@|@3|@|build\n',
  'P|@|@3|@|a |@| b |@|\nC|@|1|@|9|@|@3',
  'P|@|@3|@|\n',
  '',
  '\n',
  'C|@|1|@|9|@|@3\n',
  'P|@|@3\n',
  'P|@|@3|@|first\nP|@|@4|@|second',
  'P|@|@3|@|t\nC|@|soon|@|9|@|@3\nC|@|5|@|x|@|@3\nC|@|7|@|8|@|@1',
  'P|@|@3|@|t\nC|@|٣|@|9|@|@3\nC|@||@|9|@|@3\nC|@|1|@|+9|@|@3\nC|@|1|@|0x9|@|@3\nC|@|1e3|@|9|@|@3',
  'P|@|@3|@|t\nC|@|1|@|9\nC|@|1|@|9|@|@3|@|tty\nC|@|1|@|9|@|@3|@|tty|@|s|@|extra',
  'P|@|@3|@|t\r\nC|@|1|@|9|@|@3\r\n',
  'P|@|@3|@|t\nC|@|99999999999999999999|@|4001|@|@1\nC|@|99999999999999999998|@|4002|@|@1',
  'P|@||@|\nC|@|5|@|9|@|@3\n',
  'P|@||@|',
  'V|@|/dev/ttys009\nP|@|@3|@|build\nC|@|1|@|9|@|@3|@|/dev/ttys009|@|alpha',
  'P|@|@3|@|build\nV|@|/dev/ttys009\nC|@|1700000900|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|1700000100|@|4001|@|@7|@|/dev/ttys001|@|tagents\nC|@|1700000300|@|4002|@|@7|@|/dev/ttys002|@|tagents\nC|@|1700009999|@|4003|@|@1|@|/dev/ttys003|@|beta\n',
  'P|@|@3|@|build\nV|@|/dev/ttys009\nC|@|1700000900|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|1700000100|@|4003|@|@1|@|/dev/ttys003|@|beta\n',
  'P|@|@3|@|build\nV|@|/dev/ttys009\nC|@|1700000900|@|5555|@|@3|@|/dev/ttys009|@|alpha',
  'P|@|@3|@|b\nV|@|/dev/ttys009\nC|@|1700000900|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|1|@|4001|@|@3|@|/dev/ttys001|@|beta\nC|@|2|@|4002|@|@7|@|/dev/ttys002|@|tagents',
  'P|@|@3|@|b\nV|@|\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|2|@|4002|@|@7|@|/dev/ttys002|@|tagents',
  'P|@|@3|@|b\nV|@|\nC|@|5|@|5555|@|@3|@||@|alpha',
  'P|@|@3|@|b\nV|@|/dev/ttys009\nV|@|\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha',
  'P|@|@3|@|b\nV|@|/dev/ttys009\nV|@|/dev/ttys001\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|2|@|4001|@|@3|@|/dev/ttys001|@|tagents',
  'P|@|@3|@|b\nV|@|/dev/ttys009|@|extra\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha',
  'P|@|@3|@|b\nV|@|/dev/ttys009\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|2|@|4001|@|@3|@|/dev/ttys009|@|tagents',
  'P|@|@3|@|b\nV|@|/dev/ttys009\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|2|@|4001|@|@3|@|/dev/ttys001|@|tagents\nC|@|9|@|4002|@|@3|@|/dev/ttys002|@|tagents',
  'P|@|@3|@|b\nV|@|/dev/ttys009\nC|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha\nC|@|2|@|4001|@|@7|@|/dev/ttys001|@|tagents\nC|@|9|@|4002|@|@7|@|/dev/ttys002|@|beta',
  `P|@|@3|@|${BOM}title${BOM}\nC|@|1|@|9|@|@3`,
  'P|@|@3|@|build\nC|@|1|@|9|@|@3\n\n\nC|@|2|@|10|@|@3\n',
];

export async function wordsVectors(): Promise<unknown> {
  return {
    verdicts: verdictVectors(),
    notices: noticeVectors(),
    untitles: titles.map((title) => ({ title, out: untitle(title) })),
    names: nameVectors(),
    basenames: basenames.map((p) => ({ path: p, out: path.basename(p) })),
    phrases: phraseVectors(),
    screens: screens.map((out) => ({ out, screen: parseScreen(out) })),
  };
}
