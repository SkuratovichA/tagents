// The document section of the knowledge vectors: what `doc.ts` makes of a file, section by section, and of the dates it reads.
//
// Every case is a text and the answer of `parseDoc` for it (or its message), so the Rust reader is held to the same field rules, the same sections and the same refusals. The generated cases are the shapes the rules turn on: a byte-order mark, CRLF, the legacy keys, values that are not strings, each status, offsets, a day the calendar does not have, fences.
import fs from 'node:fs';
import path from 'node:path';
import { DocError, chunk, hashOf, isRealDate, isStale, listFiles, parseDoc, parseOffsetDatetime, readDoc, splitFrontmatter, utcDateOf } from '../../packages/knowledge/src/doc.ts';
import { NOW, fixtureFiles, lcg, plain, relativize, scratch, type CorpusFile } from './util.mts';

const BOM = '\uFEFF';

function parsed(file: string, text: string): unknown {
  try {
    const doc = parseDoc(file, text);
    return { ok: { meta: plain(doc.meta), declaredId: doc.declaredId, body: doc.body, chunks: doc.chunks, hash: doc.hash } };
  } catch (e) {
    if (e instanceof DocError) return { error: e.message };
    throw e;
  }
}

/** A document with the given front matter lines and body. */
const doc = (front: string, body = 'Body.\n'): string => `---\n${front}\n---\n${body}`;

const edgeDocuments: Array<readonly [name: string, text: string, file?: string]> = [
  // The front matter's frame.
  ['a byte-order mark before the first fence', BOM + doc('type: Note\ntitle: Bom')],
  ['a byte-order mark, then no fence', `${BOM}type: Note\n`],
  ['CRLF line endings', '---\r\ntype: Note\r\ntitle: Crlf\r\n---\r\n## One\r\nbody\r\n## Two\r\nmore\r\n'],
  ['the closing fence at the end of the file', '---\ntype: Note\n---'],
  ['the closing fence followed by a newline and nothing', '---\ntype: Note\n---\n'],
  ['text right after the closing dashes', '---\ntype: Note\n---x\nbody here\n'],
  ['an empty front matter', '---\n---\nbody\n'],
  ['no closing fence', '---\ntype: Note\ntitle: Open\n'],
  ['four dashes open the front matter', '----\ntype: Note\n----\nbody\n'],
  ['a leading blank line', '\n---\ntype: Note\n---\nbody\n'],
  ['a leading space', ' ---\ntype: Note\n---\nbody\n'],
  ['not a front matter at all', 'just text\n'],
  ['an empty file', ''],
  ['a fence inside the body is not the front matter', '---\ntype: Note\n---\nbody\n---\nnot yaml: [\n---\nmore\n'],
  ['dashes inside a YAML value', '---\ntype: Note\ntitle: a --- b\n---\nbody\n'],

  // type and the legacy kind.
  ['type missing', doc('title: No type')],
  ['type null', doc('type: null')],
  ['type empty', doc("type: ''")],
  ['type blank', doc("type: '   '")],
  ['type a number', doc('type: 5')],
  ['type a boolean', doc('type: true')],
  ['type a list', doc('type: [a]')],
  ['type with spaces around it is kept as written', doc("type: '  Note  '")],
  ['type in lower case is kept', doc('type: runbook')],
  ['the legacy kind is capitalised', doc('kind: runbook\nupdated: 2026-09-10\ngenerated_from: https://example.org/src')],
  ['the legacy kind with a bad date', doc('kind: runbook\nupdated: 2026-02-30')],
  ['the legacy kind with a date that is not a string', doc('kind: runbook\nupdated: 2026-09-10T10:00:00Z')],
  ['the legacy kind that is empty', doc("kind: ''")],
  ['the legacy kind that is not a string', doc('kind: 7')],
  ['type and kind together: type wins and the document is not legacy', doc('type: Note\nkind: runbook\nupdated: 2026-09-10')],
  ['kind in capitals', doc('kind: RUNBOOK')],
  ['a legacy kind that starts with a non-letter', doc('kind: "1st"')],
  ['a legacy kind that starts with a character with a special upper case', doc('kind: "ǆ"')],
  ['a legacy kind with a sharp s', doc('kind: "ßeta"')],
  ['generated_from that is blank', doc("kind: x\ngenerated_from: '  '")],
  ['generated and sources are ignored in the legacy form', doc('kind: x\ngenerated: {by: a, at: 2026-09-10T10:00:00Z}\nsources: [{resource: r}]')],

  // The tolerant fields.
  ['title missing falls back to the id', doc('type: Note'), 'my-doc.md'],
  ['title blank falls back to the id', doc("type: Note\ntitle: '  '"), 'my-doc.md'],
  ['title a number falls back to the id', doc('type: Note\ntitle: 5'), 'my-doc.md'],
  ['title kept with its spaces', doc("type: Note\ntitle: '  Spaced  '")],
  ['description trimmed', doc("type: Note\ndescription: '  d  '")],
  ['description blank is absent', doc("type: Note\ndescription: '  '")],
  ['description a number is absent', doc('type: Note\ndescription: 5')],
  ['description folded over lines', doc('type: Note\ndescription: >-\n  folded\n  text')],
  ['resource', doc('type: Note\nresource: https://example.org/x')],
  ['resource blank', doc("type: Note\nresource: ' '")],
  ['tags that are not all strings', doc("type: Note\ntags: [a, 1, true, null, [x], {k: v}, 'b', 2026-01-01, '']")],
  ['tags as a string', doc('type: Note\ntags: a, b')],
  ['tags as a mapping', doc('type: Note\ntags: {a: 1}')],
  ['tags empty', doc('type: Note\ntags: []')],
  ['tags in block form with a duplicate', doc('type: Note\ntags:\n  - x\n  - x\n  - "y z"')],
  ['tags with unicode', doc('type: Note\ntags: [диски, café, "日本語"]')],
  ...['draft', 'stable', 'deprecated', 'Draft', 'DEPRECATED', 'archived', "''", '5', 'null', '[stable]'].map(
    (status) => [`status ${status}`, doc(`type: Note\nstatus: ${status}`)] as const
  ),
  ...['global', 'project', 'Global', 'other', '5'].map((scope) => [`scope ${scope}`, doc(`type: Note\nscope: ${scope}`)] as const),
  ['id declared in the front matter', doc('type: Note\nid: other-id'), 'real-id.md'],
  ['id declared as a number', doc('type: Note\nid: 5')],
  ['id declared null', doc('type: Note\nid: null')],

  // generated, sources and stale_after.
  ['generated complete', doc('type: Note\ngenerated:\n  by: tool\n  at: 2026-10-31T10:00:00+02:00')],
  ['generated with an unquoted datetime and a fraction', doc('type: Note\ngenerated: {by: tool, at: 2026-10-31T10:00:00.123Z}')],
  ['generated with a bad time', doc('type: Note\ngenerated: {by: tool, at: 2026-10-31T25:00:00Z}')],
  ['generated without an offset', doc('type: Note\ngenerated: {by: tool, at: 2026-10-31T10:00:00}')],
  ['generated with a blank by', doc("type: Note\ngenerated: {by: ' ', at: 2026-10-31T10:00:00Z}")],
  ['generated with at that is not a string', doc('type: Note\ngenerated: {by: tool, at: 5}')],
  ['generated as a list', doc('type: Note\ngenerated: [a, b]')],
  ['generated by a number', doc('type: Note\ngenerated: {by: 5, at: 2026-10-31T10:00:00Z}')],
  ['sources of every shape', doc("type: Note\nsources:\n  - resource: https://a\n    id: x\n    title: T\n  - resource: ' '\n  - id: no-resource\n  - 5\n  - [a]\n  - {resource: https://b, id: 7, title: ''}")],
  ['sources as a mapping', doc('type: Note\nsources: {resource: r}')],
  ['stale_after with an offset', doc('type: Note\nstale_after: 2026-10-31T12:00:00Z')],
  ['stale_after as a date only', doc('type: Note\nstale_after: 2026-10-31')],
  ['stale_after quoted', doc("type: Note\nstale_after: '2026-10-31T12:00:00+00:00'")],
  ['stale_after that is a number', doc('type: Note\nstale_after: 20261031')],
  ['stale_after on a day the calendar lacks', doc("type: Note\nstale_after: '2026-02-30T00:00:00Z'")],

  // YAML in the front matter.
  ['a front matter that is not YAML', doc('type: [Note')],
  ['a front matter that is a list', doc('- a\n- b')],
  ['a front matter that is a scalar', doc('Note')],
  ['a front matter that is only a comment', doc('# nothing')],
  ['a duplicate key', doc('type: Note\ntype: Other')],
  ['an explicit int tag on a title', doc("type: Note\ntitle: !!int '7'")],
  ['an explicit str tag on a title', doc('type: Note\ntitle: !!str 7')],
  ['a custom tag on a title', doc('type: Note\ntitle: !custom value')],
  ['a custom tag on a mapping', doc('type: Note\ngenerated: !custom {by: tool, at: 2026-10-31T10:00:00Z}')],
  ['an anchor and an alias', doc('type: Note\ntitle: &t Shared\ndescription: *t')],
  ['an alias to a list', doc('type: Note\ntags: &x [a, b]\nresource: x\nsources: [{resource: r, id: z, title: t}]\nscope: global')],
  ['a merge key stays a key', doc('base: &b {scope: global}\ntype: Note\n<<: *b')],
  ['a block scalar for the title', doc('type: Note\ntitle: |\n  Line one\n  Line two\n')],
  ['a quoted type with an escape', doc('type: "Run\\u0431ook"')],
  ['a tab in the indentation', doc('type: Note\ngenerated:\n\tby: tool')],
  ['a key that is not a string', doc('type: Note\n5: five\ntrue: yes')],
  ['yes and no stay strings', doc('type: Note\ntitle: yes\ndescription: no')],
  ['a very large integer where a string is wanted', doc('type: Note\ntitle: 9007199254740993')],

  // Sections.
  ['a preamble and two sections', doc('type: Note', 'Intro line.\n\n## One\nFirst.\n\n## Two\nSecond.\n')],
  ['no preamble when the body opens with a heading', doc('type: Note', '## One\nFirst.\n')],
  ['a body of only whitespace', doc('type: Note', '  \n\n')],
  ['an empty body', '---\ntype: Note\n---\n'],
  ['a heading with nothing after it', doc('type: Note', '## One\n## Two\ntext\n')],
  ['a section header with trailing spaces and tabs', doc('type: Note', '## One \t \nbody\n')],
  ['a third-level heading is not a section', doc('type: Note', '### Not\n## Yes\n#### Not\n')],
  ['a hash without a space is not a heading', doc('type: Note', '##Nope\n## Yes\n')],
  ['a heading inside a backtick fence', doc('type: Note', '## Real\n```sh\n## comment\n## another\n```\n## After\n')],
  ['a heading inside a tilde fence', doc('type: Note', '## Real\n~~~\n## inside\n~~~\n## After\n')],
  ['a fence closed by the other marker stays open', doc('type: Note', '## Real\n```\n## a\n~~~\n## b\n```\n## After\n')],
  ['an unclosed fence swallows the rest', doc('type: Note', '## Real\n```\n## a\n## b\n')],
  ['an indented fence', doc('type: Note', '## Real\n   ```\n## inside\n   ```\n## After\n')],
  ['a fence with an info string and a fence with text after the marker', doc('type: Note', '## Real\n```js title\n## inside\n``` not a close\n## still inside\n```\n## After\n')],
  ['a four-backtick fence is closed by three', doc('type: Note', '## Real\n````\n## inside\n```\n## after\n')],
  ['a heading with a heading mark in it', doc('type: Note', '## ## Weird ##\nbody\n')],
  ['a heading with CRLF', doc('type: Note', '## One\r\nbody\r\n## Two\r\n')],
  ['a heading of a no-break space and a unicode text', doc('type: Note', '##\u00A0Диски\u3000\nbody\n## café\n')],
  ['two spaces after the marks', doc('type: Note', '##  \nbody\n## \u3000\u3000x\n')],
  ['only a space after the marks is no heading', doc('type: Note', '## \nbody\n')],
  ['a line separator inside a heading', doc('type: Note', '## a\u2028b\nbody\n## c\u2029\nbody\n')],
  ['the same heading twice', doc('type: Note', '## Same\none\n## Same\ntwo\n')],
  ['an empty section between two', doc('type: Note', '## A\n\n\n## B\ntext\n')],
  ['a preamble of one blank line then a heading', doc('type: Note', '\n## A\ntext\n')],
  ['sections with a lone CR', doc('type: Note', 'a\rb\n## A\nc\rd\n')],
];

// ---- headings, fuzzed against the regular expression ------------------------------------------

function headingLines(): string[] {
  const alphabet = ['#', ' ', ' ', '\t', '\r', '\u2028', '\u2029', '\u00A0', '\u3000', '\uFEFF', '\u0085', 'a', 'b', 'é', 'я', '`'];
  const next = lcg(20261031);
  const lines = ['##', '## ', '##  ', '## a', '##a', '###', '## a ', '##\t', '##\u2028', '## \u2028', '##  \u2028', '## \u2028 ', '##\u2028x', '## x\u2028y', '## x\u2028', '## x\r', '## \r', '##\r\r', '##\r x', '## \u00A0', '## \u00A0\u00A0\u00A0', '##\u3000\u3000\r', '## \uFEFF', '## \u0085', '## a\u0085', '## a b  c  '];
  for (let i = 0; i < 400; i++) {
    const length = 2 + Math.floor(next() * 7);
    let line = '##';
    for (let j = 0; j < length; j++) line += alphabet[Math.floor(next() * alphabet.length)];
    lines.push(line);
  }
  return lines;
}

/** The heading `line` makes as a section title, or null when it is not one: a heading is never the empty string, so the first chunk's title tells. */
function headingOf(line: string): string | null {
  const first = chunk(`${line}\ntext\n`)[0];
  return first !== undefined && first.heading !== '' ? first.heading : null;
}

// ---- dates -----------------------------------------------------------------------------------

const dateValues = [
  '2026-10-31T12:00:00Z',
  '2026-10-31T12:00Z',
  '2026-10-31T12:00:00+00:00',
  '2026-10-31T12:00:00-00:00',
  '2026-10-31T12:00:00+05:30',
  '2026-10-31T12:00:00-08:00',
  '2026-10-31T23:59:59+23:59',
  '2026-10-31T00:00:00-23:59',
  '2026-10-31T12:00:00+24:00',
  '2026-10-31T12:00:00+05:60',
  '2026-10-31T12:00:00+0530',
  '2026-10-31T12:00:00+05',
  '2026-10-31T12:00:00.1Z',
  '2026-10-31T12:00:00.12Z',
  '2026-10-31T12:00:00.123Z',
  '2026-10-31T12:00:00.1234Z',
  '2026-10-31T12:00:00.9999Z',
  '2026-10-31T12:00:00.123456789+05:30',
  '2026-10-31T12:00Z',
  '2026-10-31T12:00.5Z',
  '2026-10-31T24:00:00Z',
  '2026-10-31T12:60:00Z',
  '2026-10-31T12:00:60Z',
  '2026-10-31T1:00:00Z',
  '2026-10-31t12:00:00Z',
  '2026-10-31T12:00:00z',
  '2026-10-31 12:00:00Z',
  '2026-10-31T12:00:00',
  '2026-10-31',
  ' 2026-10-31T12:00:00Z',
  '2026-10-31T12:00:00Z ',
  '2026-02-29T00:00:00Z',
  '2024-02-29T00:00:00Z',
  '2100-02-29T00:00:00Z',
  '2000-02-29T00:00:00Z',
  '2026-04-31T00:00:00Z',
  '2026-13-01T00:00:00Z',
  '2026-00-10T00:00:00Z',
  '2026-10-00T00:00:00Z',
  '0000-01-01T00:00:00Z',
  '0000-01-01T00:00:00+23:59',
  '0001-01-01T00:00:00Z',
  '1969-12-31T23:59:59Z',
  '1970-01-01T00:00:00Z',
  '9999-12-31T23:59:59Z',
  '9999-12-31T23:59:59-23:59',
  '9999-12-31T23:59:59.999Z',
  '1600-02-29T12:00:00Z',
  '1900-02-29T12:00:00Z',
  '2026-10-31T12:00:00+٠٥:٠٠',
  '٢٠٢٦-10-31T12:00:00Z',
  '',
  'not a date',
];

const staleCases: Array<readonly [staleAfter: string, now: number]> = [
  ['2026-10-31T12:00:00Z', NOW],
  ['2026-10-31T12:00:01Z', NOW],
  ['2026-10-31T11:59:59Z', NOW],
  ['2026-10-31T14:00:00+02:00', NOW],
  ['2026-10-31T13:59:59+02:00', NOW],
  ['2026-10-31T12:00:00.001Z', NOW],
  ['2026-10-31T12:00:00.000Z', NOW],
  ['2026-10-31T11:59:59.999Z', NOW],
  ['nope', NOW],
  ['2026-10-31', NOW],
];

function dateVectors(): unknown {
  return {
    values: dateValues.map((value) => ({
      value,
      real: isRealDate(value),
      offsetMs: parseOffsetDatetime(value),
      utcDate: utcDateOf(value),
    })),
    stale: staleCases.map(([staleAfter, now]) => ({ staleAfter, now, stale: isStale(staleAfter, now) })),
    realDates: ['2026-02-28', '2026-02-29', '2024-02-29', '2026-04-30', '2026-04-31', '2026-13-01', '2026-00-01', '2026-01-00', '2026-1-01', '2026-01-1', '0000-01-01', '9999-12-31', '10000-01-01', '2026-01-01 ', 'x'].map((value) => ({ value, real: isRealDate(value) })),
  };
}

// ---- files on disk ---------------------------------------------------------------------------

/** Files in a folder, listed and read the way `listFiles` and `readDoc` do. */
function folderVectors(): unknown {
  const dir = scratch('folder');
  const names = [
    'b.md', 'a.md', 'A-upper.md', 'Z.md', '.hidden.md', 'index.md', 'log.md', 'notes.txt', 'z.MD', 'a b.md', 'under_score.md', 'two--dash.md', 'ünï.md', 'Читать.md', '\uFF21.md', '\u{1F600}.md', 'ok-1.md', '-lead.md', 'trail-.md',
  ];
  for (const name of names) fs.writeFileSync(path.join(dir, name), `---\ntype: Note\n---\nbody of ${name}\n`);
  fs.mkdirSync(path.join(dir, 'dir.md'));
  fs.symlinkSync(path.join(dir, 'a.md'), path.join(dir, 'link.md'));
  const listed = listFiles(dir).map((file) => path.basename(file));
  const reads = names.concat(['link.md']).map((name) => {
    try {
      const read = readDoc(path.join(dir, name));
      return { name, ok: { id: read.meta.id, hash: read.hash } };
    } catch (e) {
      if (e instanceof DocError) return { name, error: relativize(e.message, dir) };
      throw e;
    }
  });
  let missing: string;
  try {
    listFiles(path.join(dir, 'nowhere'));
    missing = 'listed';
  } catch (e) {
    missing = relativize(e instanceof Error ? e.message : String(e), dir);
  }
  return { names: [...names, 'dir.md (a directory)', 'link.md (a symlink)'], listed, reads, missingFolder: missing };
}

/** Bytes, the text node decodes them to, and what a document of them is. */
function decodeVectors(): unknown {
  const dir = scratch('decode');
  const head = Buffer.from('---\ntype: Note\ntitle: T\n---\n## S\n', 'utf8');
  const tail = Buffer.from('\n', 'utf8');
  const bodies: Array<readonly [string, Buffer]> = [
    ['plain', Buffer.from('plain', 'utf8')],
    ['a byte that starts nothing', Buffer.from([0xff])],
    ['a truncated two-byte sequence', Buffer.from([0xc3])],
    ['a truncated three-byte sequence', Buffer.from([0xe2, 0x82])],
    ['a truncated four-byte sequence', Buffer.from([0xf0, 0x9f, 0x98])],
    ['an overlong NUL', Buffer.from([0xc0, 0x80])],
    ['an overlong slash', Buffer.from([0xe0, 0x80, 0xaf])],
    ['an encoded surrogate', Buffer.from([0xed, 0xa0, 0x80])],
    ['a code point past the range', Buffer.from([0xf4, 0x90, 0x80, 0x80])],
    ['five-byte lead', Buffer.from([0xf8, 0x88, 0x80, 0x80, 0x80])],
    ['a continuation byte alone', Buffer.from([0x80])],
    ['a good sequence after a bad lead', Buffer.from([0xe2, 0x41])],
    ['a bad second byte', Buffer.from([0xe2, 0x28, 0xa1])],
    ['a noncharacter, which is valid', Buffer.from('\uFFFE\uFFFF', 'utf8')],
    ['a NUL, which is valid', Buffer.from([0x61, 0x00, 0x62])],
  ];
  const withBom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), head, Buffer.from('ok', 'utf8'), tail]);
  const cases = [...bodies.map(([name, bytes]) => [name, Buffer.concat([head, bytes, tail])] as const), ['a byte-order mark first', withBom] as const];
  return cases.map(([name, bytes], i) => {
    const file = path.join(dir, `case-${i}.md`);
    fs.writeFileSync(file, bytes);
    const read = readDoc(file);
    return { name, hex: bytes.toString('hex'), stem: `case-${i}`, hash: read.hash, chunks: read.chunks, meta: plain(read.meta) };
  });
}

export function docVectors(): unknown {
  const fixtures: Array<readonly [string, CorpusFile]> = [
    ...fixtureFiles('knowledge').map((f) => ['knowledge', f] as const),
    ...fixtureFiles('okf').map((f) => ['okf', f] as const),
  ];
  const documents = [
    ...fixtures.map(([folder, f]) => ({ name: `${folder}/${f.name}`, file: f.name, text: f.text })),
    ...edgeDocuments.map(([name, text, file]) => ({ name, file: file ?? 'edge.md', text })),
  ].map((c) => ({ ...c, split: plain(splitFrontmatter(c.text)), result: parsed(`/k/${c.file}`, c.text) }));
  return {
    documents,
    headings: headingLines().map((line) => ({ line, heading: headingOf(line) })),
    dates: dateVectors(),
    folder: folderVectors(),
    decode: decodeVectors(),
    hashes: ['', 'a', 'é', 'Диски', BOM, 'line\r\n', '\u{1F600}'].map((text) => ({ text, hash: hashOf(text) })),
  };
}
