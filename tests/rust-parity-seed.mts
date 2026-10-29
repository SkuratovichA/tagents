// Seeds the scratch homes tests/rust-parity.sh runs the node CLI and the Rust front door on.
//
//   node tests/rust-parity-seed.mts <empty scratch dir>
//
// <dir>/fixture    the two sessions the checked-in fixtures were recorded from (packages/core/test/helpers.ts seedSessions)
// <dir>/adversarial every session below, in several accounts, built so JavaScript and a naive Rust port disagree on it
// <dir>/locked     a session no one may read and a directory no one may list, for the error paths
//
// Each block says which divergence it provokes. The comparison itself is the shell script's: this file only writes files.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { seedSessions } from '../packages/core/test/helpers.ts';

const root = process.argv[2];
if (root === undefined || fs.readdirSync(root).length > 0) {
  console.error('usage: node tests/rust-parity-seed.mts <empty scratch dir>');
  process.exit(2);
}

// ------------------------------------------------------------------ fixture ---

seedSessions(path.join(root, 'fixture', '.claude'));

// -------------------------------------------------------------- adversarial ---

const home = path.join(root, 'adversarial');
const enc = home.replaceAll('/', '-');
/** Seconds since the epoch of the newest ordinary session. Everything is placed relative to it so the order never depends on the clock. */
const BASE = 1_780_000_000;
const MINUTE = 60;

const text = (v: unknown): string => JSON.stringify(v);
const PAD = text({ type: 'system', subtype: 'pad', note: 'x'.repeat(2400) });
const user = (content: unknown, extra: Record<string, unknown> = {}): string => text({ type: 'user', ...extra, message: { content } });
const assistant = (...blocks: unknown[]): string => text({ type: 'assistant', message: { content: blocks } });
const say = (t: string): unknown => ({ type: 'text', text: t });
/** A transcript: the lines, the pad so it clears the size floor, a closing newline. */
const doc = (...lines: string[]): string => `${lines.join('\n')}\n${PAD}\n`;

interface Put {
  account?: string;
  slug?: string;
  id: string;
  body: string | Buffer;
  /** seconds since the epoch, fractions allowed */
  mtime: number;
  /** the exact time in nanoseconds, for what utimes cannot say: before 1970, and halves of a millisecond */
  mtimeNs?: bigint;
}

/** The accounts tests/rust-parity.sh puts in CLAUDE_HOMES for the listing cases, which is where the search window below is exact. */
const PRIMARY = ['.claude', '.claude-work', '.claude-averyverylongaccountname', '.claude-😀x', '.claude-a.b_c'];
const listed: { account: string; mtime: number }[] = [];

const exactTimes: [string, string][] = [];

function put({ account = '.claude', slug = `${enc}-git-app`, id, body, mtime, mtimeNs }: Put): string {
  const dir = path.join(home, account, 'projects', slug);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${id}.jsonl`);
  fs.writeFileSync(file, body);
  fs.utimesSync(file, mtime, mtime);
  if (mtimeNs !== undefined) exactTimes.push([file, String(mtimeNs)]);
  if (fs.statSync(file).size >= 2000) listed.push({ account, mtime });
  return file;
}

let slot = 0;
/** The next-newest ordinary time, one minute apart. */
const next = (): number => BASE - MINUTE * ++slot;

// UTF-16 lengths: a cut at 150 (listing) and at 1500 (show), and the 8 characters of an id.
put({ slug: `${enc}-git-кириллица`, id: 'cyrillic-long', body: doc(user('Привет мир '.repeat(30))), mtime: next() });
put({ id: 'emoji-cut-150', body: doc(user(`${'a'.repeat(149)}😀tail`)), mtime: next() });
put({ id: 'emoji-cut-1500', body: doc(user(`${'b'.repeat(1499)}😀z`), assistant(say(`${'r'.repeat(1499)}😀y`))), mtime: next() });
put({ id: 'emoji-ok-150', body: doc(user(`${'c'.repeat(148)}😀tail`)), mtime: next() });
put({ id: 'ab😀😀😀', body: doc(user('emoji id, eight units exactly')), mtime: next() });
put({ id: 'a😀😀😀😀x', body: doc(user('emoji id, cut inside a pair')), mtime: next() });
put({ account: '.claude-😀x', slug: `${enc}-git-emoji-account`, id: 'emoji-account', body: doc(user('account name of three units')), mtime: next() });
put({ account: '.claude-averyverylongaccountname', slug: `${enc}-git-long-account`, id: 'long-account', body: doc(user('account name past the padding')), mtime: next() });

// Whitespace as JavaScript counts it: trim and \s agree on U+00A0, U+FEFF, U+2028, U+3000, and disagree with Rust on U+0085, U+180E, U+200B.
const spaceCases: [string, string][] = [
  ['ws-nbsp', '    nbsp lead'],
  ['ws-feff', '﻿﻿bom lead'],
  ['ws-nel', '\u0085nel lead'],
  ['ws-mongolian', '᠎mongolian lead'],
  ['ws-zwsp', '​zwsp lead'],
  ['ws-line-sep', 'line sep and　ideographic'],
  ['ws-mixed', '  tabs\tand\nnewlines\r\n  and   runs   of  spaces  '],
  ['ws-nbsp-tag', ' <tag> after a no-break space'],
];
for (const [id, content] of spaceCases) put({ slug: `${enc}-ws`, id, body: doc(user(content)), mtime: next() });
// Skipped prompts: only white space, a tag, a list instead of a string, null.
put({ slug: `${enc}-skip`, id: 'skip-blank', body: doc(user('  ﻿\n'), user('after blank')), mtime: next() });
put({ slug: `${enc}-skip`, id: 'skip-tag', body: doc(user('<local-command-stdout>x</local-command-stdout>'), user('after tag')), mtime: next() });
put({ slug: `${enc}-skip`, id: 'skip-list', body: doc(user([{ type: 'text', text: 'list prompt' }]), user('after list')), mtime: next() });
put({ slug: `${enc}-skip`, id: 'skip-null', body: doc(user(null), user('after null')), mtime: next() });
put({ slug: `${enc}-skip`, id: 'skip-none', body: doc(text({ type: 'user' }), text({ type: 'assistant' })), mtime: next() });
put({ slug: `${enc}-skip`, id: 'skip-all', body: doc(user('<only a tag>')), mtime: next() });

// isMeta as JavaScript truthiness: 0, -0, "", null, false, 1e-999 are falsy; "0", [], {}, 1e999, true are not.
const metaCases: [string, string][] = [
  ['meta-zero', '0'],
  ['meta-negzero', '-0'],
  ['meta-empty', '""'],
  ['meta-null', 'null'],
  ['meta-false', 'false'],
  ['meta-tiny', '1e-999'],
  ['meta-fraction', '0.0e5'],
  ['meta-zerostr', '"0"'],
  ['meta-array', '[]'],
  ['meta-object', '{}'],
  ['meta-huge', '1e999'],
  ['meta-true', 'true'],
  ['meta-one', '1'],
];
for (const [id, literal] of metaCases) {
  put({
    slug: `${enc}-meta`,
    id,
    body: doc(`{"type":"user","isMeta":${literal},"message":{"content":"first of ${id}"}}`, user(`second of ${id}`)),
    mtime: next(),
  });
}

// JSON.parse versus a strict parser: a lone surrogate escape, a number that overflows a float, 30000 levels of nesting, a key written twice, a BOM, CRLF line ends.
put({ slug: `${enc}-json`, id: 'json-lone-surrogate', body: doc('{"type":"user","message":{"content":"lone \\ud800 and \\udc00 and pair \\ud83d\\ude00 end"}}'), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-overflow', body: doc('{"type":"user","big":1e999,"small":-1e999,"message":{"content":"line with 1e999 in it"}}'), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-deep', body: doc(`{"type":"user","deep":${'['.repeat(30000)}${']'.repeat(30000)},"message":{"content":"thirty thousand levels"}}`), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-dup-key', body: doc('{"type":"x","type":"user","message":{"content":"last duplicate wins"}}', '{"type":"user","type":"x","message":{"content":"never"}}'), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-bom', body: `﻿${doc(user('first line has a BOM'), user('second line has none'))}`, mtime: next() });
put({ slug: `${enc}-json`, id: 'json-crlf', body: doc(user('crlf one'), assistant(say('crlf reply'))).replaceAll('\n', '\r\n'), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-escaped-type', body: doc('{"type":"\\u0075ser","message":{"content":"never read"}}', user('fallback after escaped type')), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-trailing-comma', body: doc('{"type":"user","message":{"content":"never",}}', user('fallback after trailing comma')), mtime: next() });
put({ slug: `${enc}-json`, id: 'json-string-escapes', body: doc(user('quote " backslash \\ slash / tab\there \u0001 control')), mtime: next() });

// Invalid UTF-8, decoded the way Buffer#toString does: one U+FFFD per maximal invalid prefix.
const invalid: [string, Buffer][] = [
  ['bad-ff', Buffer.from([0x62, 0x61, 0x64, 0xff, 0x62, 0x79, 0x74, 0x65])],
  ['bad-truncated-3', Buffer.from([0x61, 0xe2, 0x82, 0x62])],
  ['bad-truncated-4', Buffer.from([0x61, 0xf0, 0x9f, 0x98, 0x62])],
  ['bad-overlong', Buffer.from([0x61, 0xc0, 0xaf, 0x62])],
  ['bad-surrogate', Buffer.from([0x61, 0xed, 0xa0, 0x80, 0x62])],
  ['bad-too-high', Buffer.from([0x61, 0xf4, 0x90, 0x80, 0x80, 0x62])],
  ['bad-continuation', Buffer.from([0x61, 0x80, 0xbf, 0x62])],
  ['bad-at-end', Buffer.from([0x61, 0xe2])],
];
for (const [id, bytes] of invalid) {
  const line = Buffer.concat([Buffer.from('{"type":"user","message":{"content":"'), bytes, Buffer.from('"}}')]);
  put({ slug: `${enc}-invalid`, id, body: Buffer.concat([line, Buffer.from(`\n${PAD}\n`)]), mtime: next() });
}
put({
  slug: `${enc}-invalid`,
  id: 'bad-reply',
  body: Buffer.concat([
    Buffer.from(`${user('prompt of bad-reply')}\n${PAD}\n{"type":"assistant","message":{"content":[{"type":"text","text":"reply `),
    Buffer.from([0xff, 0xe2, 0x82]),
    Buffer.from(' end"}]}}\n'),
  ]),
  mtime: next(),
});

// Replies: the last non-blank text block wins, a string content is ignored, a later blank block does not erase an earlier one.
put({ slug: `${enc}-reply`, id: 'reply-blank-after', body: doc(user('reply cases one'), assistant(say('real reply')), assistant(say('   \n ')), assistant({ type: 'tool_use', name: 'x' })), mtime: next() });
put({ slug: `${enc}-reply`, id: 'reply-string-content', body: doc(user('reply cases two'), assistant(say('block reply')), text({ type: 'assistant', message: { content: 'plain string' } })), mtime: next() });
put({ slug: `${enc}-reply`, id: 'reply-two-blocks', body: doc(user('reply cases three'), assistant(say('first'), { type: 'thinking', text: 'no' }, say('  second  \n\tlines  '))), mtime: next() });
put({ slug: `${enc}-reply`, id: 'reply-none', body: doc(user('reply cases four')), mtime: next() });
put({ slug: `${enc}-reply`, id: 'reply-typed-wrong', body: doc(user('reply cases five'), text({ type: 'assistant', message: { content: [{ type: 'tool_result', text: 'not text' }, { text: 'no type' }] } })), mtime: next() });

// Case folding: final sigma, dotted capital I, sharp capital S.
put({ slug: `${enc}-case`, id: 'case-sigma', body: doc(user('οδος ΟΔΟΣ Σ')), mtime: next() });
put({ slug: `${enc}-case`, id: 'case-dotted-i', body: doc(user('İstanbul and ISTANBUL')), mtime: next() });
put({ slug: `${enc}-case`, id: 'case-sharp-s', body: doc(user('STRASSE ẞ straße')), mtime: next() });
put({ slug: `${enc}-case`, id: 'case-kelvin', body: doc(user('Kelvin \u212a sign')), mtime: next() });

// A project path under HOME is folded to ~.
put({ slug: `${enc}-git-app`, id: 'home-app', body: doc(user('under home')), mtime: next() });
put({ slug: `${enc}x-foo`, id: 'home-prefix-only', body: doc(user('sibling of home')), mtime: next() });
put({ slug: enc, id: 'home-exact', body: doc(user('the home itself')), mtime: next() });
put({ slug: `${enc}-`, id: 'home-trailing-dash', body: doc(user('home and a dash')), mtime: next() });
put({ slug: '-Users-elsewhere-git-x', id: 'elsewhere', body: doc(user('outside home')), mtime: next() });
put({ slug: 'no-leading-dash', id: 'no-dash', body: doc(user('slug without a leading dash')), mtime: next() });

// Time: the epoch, before it, half milliseconds both sides of zero, the future, and the 24 hour edge with an hour to spare.
// Math.round sends halves up where a Rust f64::round sends them away from zero, so -1000.5 ms is the moment that tells them apart.
const now = Date.now() / 1000;
const timed: [string, string, bigint][] = [
  ['time-epoch', 'mtime zero', 0n],
  ['time-neg-half', 'minus one thousand and a half milliseconds', -1_000_500_000n],
  ['time-pos-half', 'plus one thousand and a half milliseconds', 1_000_500_000n],
  ['time-1969', 'the last millisecond of 1969', -1_000_000n],
  ['time-1900', 'a date in 1900', -2_208_988_800_000_000_000n],
  ['time-sub-down', 'down', 1_700_000_000_000_400_000n],
  ['time-sub-up', 'up', 1_700_000_000_000_600_000n],
  ['time-sub-half', 'half', 1_700_000_000_000_500_000n],
  ['time-2200', 'a date in 2200', 7_258_118_400_000_000_000n],
];
for (const [id, prompt, ns] of timed) put({ slug: `${enc}-time`, id, body: doc(user(prompt)), mtime: Math.max(0, Number(ns) / 1e9), mtimeNs: ns });
put({ slug: `${enc}-time`, id: 'time-future', body: doc(user('written in 2096')), mtime: 4_000_000_000 });
put({ slug: `${enc}-time`, id: 'time-23h', body: doc(user('twenty three hours ago')), mtime: now - 23 * 3600 });
put({ slug: `${enc}-time`, id: 'time-25h', body: doc(user('twenty five hours ago')), mtime: now - 25 * 3600 });
put({ slug: `${enc}-time`, id: 'time-in-1h', body: doc(user('an hour from now')), mtime: now + 3600 });

// Ties in mtime are broken by the order the directories are walked: bytes, not locale, not UTF-16.
const tie = BASE - 3 * 3600;
for (const slug of ['-Z-tie', '-a-tie', '-é-tie', '-～-tie', '-😀-tie', '-10-tie', '-9-tie', '-_x-tie', '-.y-tie']) {
  for (const id of ['10', '9', 'Z', 'a', '_x', 'é', '～', '😀']) put({ slug, id, body: doc(user(`tie ${slug} ${id}`)), mtime: tie });
}
put({ account: '.claude-work', slug: '-Z-tie', id: 'tie-in-work-account', body: doc(user('same time in another account')), mtime: tie });

// Size floor: 1999 bytes is not listed, 2000 is.
const exact = (size: number, marker: string): string => {
  const head = `${user(marker)}\n`;
  const fill = (n: number): string => text({ type: 'system', note: 'x'.repeat(n) });
  const base = Buffer.byteLength(head) + Buffer.byteLength(fill(0)) + 1;
  return `${head}${fill(size - base)}\n`;
};
put({ slug: `${enc}-size`, id: 'size-1999', body: exact(1999, 'size 1999'), mtime: next() });
put({ slug: `${enc}-size`, id: 'size-2000', body: exact(2000, 'size 2000'), mtime: next() });
put({ slug: `${enc}-size`, id: 'size-2001', body: exact(2001, 'size 2001'), mtime: next() });

// File kinds: only a regular file whose name ends in .jsonl is a session.
{
  const dir = path.join(home, '.claude', 'projects', `${enc}-kinds`);
  fs.mkdirSync(dir, { recursive: true });
  const real = put({ slug: `${enc}-kinds`, id: 'real', body: doc(user('the real one')), mtime: next() });
  fs.symlinkSync(real, path.join(dir, 'symlink.jsonl'));
  fs.symlinkSync(path.join(dir, 'nowhere'), path.join(dir, 'dangling.jsonl'));
  fs.mkdirSync(path.join(dir, 'directory.jsonl'));
  fs.writeFileSync(path.join(dir, 'notes.txt'), doc(user('text file')));
  fs.writeFileSync(path.join(dir, 'real.jsonl.bak'), doc(user('backup')));
  fs.writeFileSync(path.join(dir, 'UPPER.JSONL'), doc(user('upper case extension')));
  put({ slug: `${enc}-kinds`, id: '', body: doc(user('a file named just .jsonl')), mtime: next() });
  fs.writeFileSync(path.join(home, '.claude', 'projects', 'a-file-not-a-directory'), 'x');
  fs.mkdirSync(path.join(home, '.claude', 'projects', 'an-empty-project'));
  fs.writeFileSync(path.join(home, '.claude', 'not-projects'), 'x');
}

// Windows. The head is 65536 bytes, the tail 49152, and a tail drops its first line however complete it is.
const filler = (bytes: number): string => text({ type: 'system', note: 'y'.repeat(bytes) });
{
  // The prompt line ends exactly at byte 65536, with no newline after it: the line is whole, so it is read.
  const prompt = user('prompt ending on the head boundary');
  const lead = `${filler(60000)}\n`;
  const pad = 65536 - Buffer.byteLength(lead) - Buffer.byteLength(prompt) - Buffer.byteLength(filler(0)) - 1;
  const body = `${lead}${filler(pad)}\n${prompt}\n${PAD}\n`;
  const at = Buffer.byteLength(lead) + Buffer.byteLength(filler(pad)) + 1 + Buffer.byteLength(prompt);
  if (at !== 65536) throw new Error(`head boundary layout is off by ${at - 65536}`);
  put({ slug: `${enc}-window`, id: 'head-exact', body, mtime: next() });
  // One byte more: the line is cut, does not parse, and the session has no opening prompt.
  put({ slug: `${enc}-window`, id: 'head-cut', body: `${lead}${filler(pad + 1)}\n${prompt}\n${PAD}\n`, mtime: next() });
  // The prompt starts past the window.
  put({ slug: `${enc}-window`, id: 'head-past', body: `${filler(70000)}\n${user('prompt past the head window')}\n`, mtime: next() });
}
{
  const reply = assistant(say('reply on the tail boundary'));
  const prompt = `${user('tail boundary prompt')}\n`;
  const sized = (bytes: number): string => filler(bytes - Buffer.byteLength(filler(0)));
  // The reply line starts exactly where the tail window starts: its first line is dropped however whole it is.
  const closing = `${sized(49152 - Buffer.byteLength(reply) - 2)}\n`;
  const exactBody = `${prompt}${filler(1000)}\n${reply}\n${closing}`;
  if (Buffer.byteLength(exactBody) - 49152 !== Buffer.byteLength(`${prompt}${filler(1000)}\n`)) throw new Error('tail boundary layout is off');
  put({ slug: `${enc}-window`, id: 'tail-line-start', body: exactBody, mtime: next() });
  // One byte less after it: the window starts on the newline before the reply, and the reply is read.
  put({ slug: `${enc}-window`, id: 'tail-line-start-1', body: `${prompt}${filler(1000)}\n${reply}\n${sized(49152 - Buffer.byteLength(reply) - 3)}\n`, mtime: next() });
  // A reply well inside the window is read.
  put({ slug: `${enc}-window`, id: 'tail-inside', body: `${prompt}${filler(80000)}\n${reply}\n`, mtime: next() });
  // One huge line and no newline in the whole tail window.
  put({ slug: `${enc}-window`, id: 'tail-one-line', body: `${prompt}${assistant(say('z'.repeat(90000)))}`, mtime: next() });
  // Multi-byte text across both boundaries.
  const cyr = `${text({ type: 'system', note: 'щ'.repeat(40000) })}\n`;
  put({ slug: `${enc}-window`, id: 'multibyte-edges', body: `${prompt}${cyr}${cyr}${assistant(say('reply after cyrillic'))}\n`, mtime: next() });
}

// A second account, found by discovery and by CLAUDE_HOMES, and entries the discovery must ignore.
put({ account: '.claude-work', slug: `${enc}-git-work`, id: 'work-1', body: doc(user('work account session')), mtime: next() });
put({ account: '.claude-a.b_c', slug: `${enc}-git-dotted`, id: 'dotted-1', body: doc(user('dotted account session')), mtime: next() });
put({ account: '.claudeX', slug: `${enc}-git-nodash`, id: 'ignored-1', body: doc(user('ignored: no dash')), mtime: next() });
put({ account: '.claude-é', slug: `${enc}-git-nonascii`, id: 'ignored-2', body: doc(user('ignored: not a word character')), mtime: next() });
fs.writeFileSync(path.join(home, '.claude-afile'), 'a file, not a directory');
fs.mkdirSync(path.join(home, '.claude-'), { recursive: true });
fs.mkdirSync(path.join(home, '.claude-empty'), { recursive: true });
fs.mkdirSync(path.join(home, '.claude-noprojects', 'other'), { recursive: true });

// Search: more hits than the cap, and a match just inside and just beyond the 400 sessions search looks at (exact for the PRIMARY accounts).
const BULK_TOP = 1_690_000_000;
const newer = listed.filter((x) => PRIMARY.includes(x.account) && x.mtime > BULK_TOP).length;
const bulk = 430;
const inside = 399 - newer;
const beyond = 400 - newer;
for (let i = 0; i < bulk; i++) {
  const tag = i === inside ? ' scanlast' : i === beyond ? ' scanbeyond' : '';
  const cap = i >= 10 && i < 25 ? ' capword' : '';
  put({ slug: `${enc}-bulk`, id: `bulk-${String(i).padStart(3, '0')}`, body: doc(user(`bulk session ${i} common${cap}${tag}`)), mtime: BULK_TOP - i * MINUTE });
}

// utimes takes seconds and refuses the past: python sets the exact nanoseconds.
const applied = spawnSync('python3', ['-I', '-c', 'import json, os, sys\nfor path, ns in json.load(sys.stdin):\n    os.utime(path, ns=(int(ns), int(ns)))'], {
  input: JSON.stringify(exactTimes),
  encoding: 'utf8',
});
if (applied.status !== 0) {
  console.error(`rust-parity-seed: python3 could not set the exact times: ${applied.stderr || applied.error}`);
  process.exit(2);
}

// ------------------------------------------------------------------- locked ---

const locked = path.join(root, 'locked', '.claude', 'projects');
fs.mkdirSync(path.join(locked, '-locked-a'), { recursive: true });
fs.mkdirSync(path.join(locked, '-locked-dir'), { recursive: true });
for (const [id, mtime, dir] of [
  ['unlocked-new', BASE, '-locked-a'],
  ['locked-file', BASE - 600, '-locked-a'],
  ['unlocked-old', BASE - 1200, '-locked-a'],
  ['inside-locked-dir', BASE - 1800, '-locked-dir'],
] as const) {
  const file = path.join(locked, dir, `${id}.jsonl`);
  fs.writeFileSync(file, doc(user(`prompt of ${id}`)));
  fs.utimesSync(file, mtime, mtime);
}
fs.chmodSync(path.join(locked, '-locked-a', 'locked-file.jsonl'), 0o000);
fs.chmodSync(path.join(locked, '-locked-dir'), 0o000);
