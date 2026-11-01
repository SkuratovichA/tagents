// The config documents the plugin vectors and the parity suite feed through `plugin add` and `plugin remove`.
//
// The first 27 are the documents the design measured the two TOML parsers on (the `toml` crate against smol-toml): they agree on whether each parses and on what it holds, except an integer beyond 2^53, which smol-toml refuses. The rest are what a hand-kept config looks like, and what `cutSections` has to cut around. A document is written as text, or as hex when it is not UTF-8 text, so that what the file holds is readable here and survives any tool that normalises line ends.
//
// `tests/rust-plugin-vectors/materialise.mts <dir>` writes each one to `<dir>/<name>.toml` for the shell suite.

export interface Document {
  readonly name: string;
  /** The file's text. */
  readonly text?: string;
  /** The file's bytes in hex, for a file that is not UTF-8. */
  readonly hex?: string;
}

const entry = (key: string, from: string): string => `[plugins.${key}]\nfrom = "${from}"\n`;

export const documents: readonly Document[] = [
  // What the design measured.
  { name: 'empty', text: '' },
  { name: 'only-comment', text: '# hi' },
  { name: 'bom', text: '\uFEFFa = 1\n' },
  { name: 'crlf', text: 'a = 1\r\n[plugins.x]\r\nfrom = "p"\r\n' },
  { name: 'lone-cr', text: 'a = 1\r[plugins.x]\rfrom = "p"\r' },
  { name: 'dotted', text: 'plugins.x.from = "p"\n' },
  { name: 'dup-key', text: 'a = 1\na = 2\n' },
  { name: 'dup-table', text: '[a]\nx = 1\n[a]\ny = 2\n' },
  { name: 'header-comment', text: '[plugins.x] # c\nfrom = "p"\n' },
  { name: 'tab-ws', text: '[plugins.x]\n\tfrom = "p"\n' },
  { name: 'unicode-key', text: '[plugins."\u00e9\u00e8"]\nfrom = "p"\n' },
  { name: 'dates', text: 'd = 1979-05-27T07:32:00Z\nl = 1979-05-27\n' },
  { name: 'time-noseconds', text: 't = 07:32\n' },
  { name: 'bigint', text: 'a = 9007199254740993\n' },
  { name: 'overflow', text: 'a = 1e400\n' },
  { name: 'esc-e', text: 'a = "\\e"\n' },
  { name: 'esc-x', text: 'a = "\\x41"\n' },
  { name: 'ctrl-del', text: 'a = "x\u007fy"\n' },
  { name: 'nul', hex: Buffer.from('a = "x\u0000y"\n').toString('hex') },
  { name: 'nul-comment', hex: Buffer.from('# x\u0000y\na = 1\n').toString('hex') },
  { name: 'invalid-utf8-comment', hex: Buffer.from([0x23, 0x20, 0x63, 0x61, 0x66, 0xe9, 0x0a, 0x61, 0x20, 0x3d, 0x20, 0x31, 0x0a]).toString('hex') },
  { name: 'inline-newline', text: 'a = {\nb = 1,\nc = 2,\n}\n' },
  { name: 'multiline-array-header-lookalike', text: `x = [\n[1],\n[2]\n]\n${entry('y', 'p')}` },
  { name: 'plugins-string', text: 'plugins = "x"\n' },
  { name: 'plugins-array', text: 'plugins = [1]\n' },
  { name: 'plugins-aot', text: '[[plugins]]\nfrom = "p"\n' },
  { name: 'plugins-inline', text: 'plugins = { x = { from = "p" } }\n' },

  // A config somebody keeps by hand.
  {
    name: 'aligned-comments',
    text: '# tagents config\n# the plugins I use\n\n[plugins.x]   # telegram\nfrom = "/p/x"   # where it lives\n\n[other]\nkey      = "value"    # aligned\nlonger_k = 2\n',
  },
  { name: 'no-final-newline', text: `a = 1\n${entry('x', '/p/x').slice(0, -1)}` },
  { name: 'no-final-newline-plain', text: 'a = 1' },
  { name: 'only-blank-lines', text: '\n\n   \n' },
  {
    name: 'other-sections',
    text: `[server]\nport = 1\n[server.tls]\non = true\n${entry('x', '/p/x')}[plugins.x.opts]\na = 1\n${entry('y', '/p/y')}[tail]\nz = 1\n`,
  },
  { name: 'last-entry-after-add', text: `a = 1\n\n${entry('x', '/p/x')}` },
  { name: 'two-blank-lines-before', text: `a = 1\n\n\n${entry('x', '/p/x')}` },
  { name: 'blank-line-after-entry', text: `${entry('x', '/p/x')}\n[b]\nk = 1\n` },
  { name: 'comment-above-next-header', text: `${entry('x', '/p/x')}# about y\n${entry('y', '/p/y')}` },
  { name: 'comment-above-header', text: `a = 1\n# about x\n${entry('x', '/p/x')}` },
  { name: 'comment-lines-with-blank-between', text: `${entry('x', '/p/x')}# one\n\n# two\n${entry('y', '/p/y')}` },
  { name: 'indented-header', text: '  [plugins.x]\n  from = "/p/x"\n' },
  { name: 'header-spaces-and-quotes', text: '[ plugins . "x" ]\nfrom = "/p/x"\n[\'plugins\'.\'y\']\nfrom = "/p/y"\n' },
  { name: 'array-of-tables-entry', text: '[[plugins.x]]\nfrom = "/p/x"\n' },
  { name: 'inline-entry', text: '[plugins]\nx = { from = "/p/x" }\n' },
  { name: 'dotted-under-plugins', text: '[plugins]\nx.from = "/p/x"\n' },
  { name: 'plugins-header-only', text: '[plugins]\n' },
  { name: 'quoted-key', text: '[plugins."a.b"]\nfrom = "/p/ab"\n' },
  { name: 'literal-string-from', text: "[plugins.x]\nfrom = '/p/x'\n" },
  { name: 'unicode-from', text: '[plugins.x]\nfrom = "/p/\u00e9\u{1F600}"\n' },
  { name: 'crlf-entry-at-end', text: 'a = 1\r\n\r\n[plugins.x]\r\nfrom = "/p/x"\r\n' },
  { name: 'crlf-no-final-newline', text: 'a = 1\r\n[plugins.x]\r\nfrom = "/p/x"' },
  { name: 'bom-entry', text: `\uFEFF${entry('x', '/p/x')}` },
  { name: 'trailing-white-space', text: 'x = 1   \n   \n[plugins.x]  \nfrom = "/p/x"\n   \n' },
  { name: 'nan-inf-and-zero', text: `n = nan\ni = inf\nz = -0.0\nm = -nan\n${entry('x', '/p/x')}` },
  { name: 'numbers-in-other-tables', text: `a = 1_000\nb = 0x1F\nc = 1e3\nd = [1, 2.5, "s"]\n${entry('x', '/p/x')}[t]\ne = { k = 0o17 }\n` },
  { name: 'many-entries', text: `${entry('x', '/p/x')}\n${entry('y', '/p/y')}\n${entry('a.b', '/p/ab').replace('a.b', '"a.b"')}` },
  { name: 'proto-key-in-plugins', text: '[plugins.__proto__]\nfrom = "/p"\n' },
  { name: 'proto-key-at-top', text: `__proto__ = 1\n${entry('x', '/p/x')}` },

  // Text that looks like a header and is not one.
  { name: 'header-lookalike-in-string-under-entry', text: '[plugins.x]\nfrom = "/p/x"\nnote = """\n[plugins.y]\nfrom = "/q"\n"""\n' },
  { name: 'header-lookalike-in-string-elsewhere', text: `[misc]\ntext = """\n[plugins.x]\n"""\n${entry('x', '/p/x')}` },
  { name: 'header-lookalike-in-string-then-real', text: `[misc]\ntext = """\n[plugins.x]\nfrom = "/q"\n"""\n${entry('y', '/p/y')}` },
  { name: 'header-lookalike-in-array', text: `${entry('x', '/p/x')}list = [\n[1],\n[2]\n]\n` },
  { name: 'header-lookalike-line-of-numbers', text: `${entry('x', '/p/x')}list = [\n  [1, 2],\n  [3]\n]\n` },
];

/** The bytes of a document. */
export const bytesOf = (doc: Document): Buffer => (doc.hex === undefined ? Buffer.from(doc.text ?? '', 'utf8') : Buffer.from(doc.hex, 'hex'));

/** Does the document's content decode as UTF-8 without a replacement? */
export function validUtf8(doc: Document): boolean {
  try {
    new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytesOf(doc));
    return true;
  } catch {
    return false;
  }
}
