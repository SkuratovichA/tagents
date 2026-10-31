// The options section of the notify vectors: documents to options or to the lines that report them (`options.ts`, `plugin-options.ts`).
//
// Each case writes its document to `<configDir>/plugins/notify.toml` in a scratch directory and calls `loadPluginOptions` with `NotifyOptionsSchema`, as `service.ts` does, so the expected result is the one the node daemon reaches: the options, the defaults of a missing file, or the lines it logs. The scratch path is written `<file>` in the lines.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { configDir } from '../../packages/core/src/host.ts';
import { loadPluginOptions, pluginOptionsFile } from '../../packages/core/src/plugin-options.ts';
import { NotifyOptionsSchema } from '../../packages/notify/src/options.ts';

/** How the options file is made, when a document does not say it all. */
type Setup = 'document' | 'missing' | 'directory' | 'unreadable' | 'plugins-is-a-file' | 'dangling-symlink' | 'yaml-only' | 'symlink';

interface Case {
  readonly name: string;
  readonly setup: Setup;
  /** The file's text, for `document` and `symlink`. */
  readonly toml?: string;
  /** The file's bytes in hex, for a file that is not UTF-8. */
  readonly hex?: string;
}

const FILE = '<file>';

// Documents, in the order the requirements name them.
const documents: Array<readonly [name: string, toml: string]> = [
  ['an empty file', ''],
  ['only comments and blank lines', '# nothing here\n\n   \n'],
  ['a partial file', 'click = "goto"\n'],
  ['a partial event', '[events.question]\nenabled = false\n'],
  ['every key set', 'backend = "log"\nclick = "focus"\nicon = "~/pics/tagents.png"\n[events.question]\nenabled = false\nskip_visible = false\n[events.permission]\nenabled = false\n[events.turn_done]\nskip_visible = false\n[events.cache_expiring]\nenabled = false\nskip_visible = true\nafter = "1h30m"\nttl = "2h"\n[events.session_end]\nenabled = true\nskip_visible = false\n'],
  ['dotted keys and an inline table', 'events.question.enabled = false\nevents.session_end = { enabled = true }\n'],
  ['an icon that is a literal string', "icon = 'C:\\icons\\a.png'\n"],
  ['an icon with a multi-line string', 'icon = """\n/a/b.png"""\n'],
  ['an icon of one character', 'icon = "x"\n'],
  ['a unicode icon path', 'icon = "/tmp/\u{1F600}/\u00e9.png"\n'],
  ...['auto', 'macos', 'log', 'none'].map((v) => [`backend ${v}`, `backend = "${v}"\n`] as const),
  ...['dock', 'goto', 'focus'].map((v) => [`click ${v}`, `click = "${v}"\n`] as const),

  // Unknown keys and the order they are written in.
  ['an unknown key', 'icn = "x"\n'],
  ['a misspelt skip_visible', '[events.question]\nskip_visble = false\n'],
  ['two unknown keys', 'zeta = 1\nalpha = 2\n'],
  ['unknown keys in the order of a JavaScript object', 'b = 1\n"2" = 1\n"1" = 1\n'],
  ['array index keys and the rest', 'z = 1\n"2" = 1\n"1" = 1\nb = 1\n"4294967294" = 1\n"4294967295" = 1\n"01" = 1\n"0" = 1\n"-1" = 1\n"1.5" = 1\n'],
  ['an unknown key with a quote in it', '"a\\"b" = 1\nc = 2\n'],
  ['an unknown key named __proto__', '__proto__ = 1\n'],
  ['an unknown key that is not ASCII', '"\u00e9\u00e8" = 1\n'],
  ['an unknown key in events', '[events]\nquestion_asked = { enabled = true }\n'],
  ['two unknown keys in events', '[events]\nb = 1\na = 2\n'],
  ['the old sessions table', '[sessions]\nheadless = true\n'],
  ['an unknown key in an event', '[events.question]\nenabld = true\n'],
  ['an unknown key in cache_expiring', '[events.cache_expiring]\nafterr = "5m"\n'],
  ['an unknown key in session_end', '[events.session_end]\n"2" = 1\nx = 2\n'],
  ['unknown keys at every level', 'x = 1\n[events]\ny = 1\n[events.question]\nz = 1\n[events.cache_expiring]\nw = 1\n'],
  ['an unknown key beside a bad event', '[events.question]\nenabled = "no"\nzz = 1\n'],

  // Values outside a list, and of the wrong type.
  ['click outside its list', 'click = "tap"\n'],
  ['click as a number', 'click = 3\n'],
  ['click as a boolean', 'click = true\n'],
  ['backend outside its list', 'backend = "smtp"\n'],
  ['backend in capitals', 'backend = "AUTO"\n'],
  ['backend as an array', 'backend = ["auto"]\n'],
  ['backend as a date', 'backend = 1979-05-27\n'],
  ['backend as infinity', 'backend = inf\n'],
  ['the empty icon', 'icon = ""\n'],
  ['icon as an integer', 'icon = 3\n'],
  ['icon as a float', 'icon = 1.5\n'],
  ['icon as a boolean', 'icon = true\n'],
  ['icon as an array', 'icon = [1]\n'],
  ['icon as a table', 'icon = { a = 1 }\n'],
  ['icon as a date', 'icon = 1979-05-27\n'],
  ['icon as a time', 'icon = 07:32:00\n'],
  ['icon as a local date-time', 'icon = 1979-05-27T07:32:00\n'],
  ['icon as nan', 'icon = nan\n'],
  ['icon as infinity', 'icon = inf\n'],
  ['icon as minus infinity', 'icon = -inf\n'],
  ['enabled as a string', '[events.question]\nenabled = "yes"\n'],
  ['skip_visible as a number', '[events.permission]\nskip_visible = 1\n'],
  ['enabled as nan', '[events.turn_done]\nenabled = nan\n'],
  ['events as a string', 'events = "x"\n'],
  ['events as an array', 'events = [1]\n'],
  ['events as an array of tables', '[[events]]\nx = 1\n'],
  ['events as a date', 'events = 1979-05-27\n'],
  ['events as a date-time', 'events = 1979-05-27T07:32:00Z\n'],
  ['an event as a date', '[events]\nquestion = 1979-05-27\n'],
  ['cache_expiring as a time', '[events]\ncache_expiring = 07:32:00\n'],
  ['an event as an integer', '[events]\nturn_done = 4\n'],
  ['session_end as a boolean', '[events]\nsession_end = false\n'],

  // Several problems: the order of the lines.
  ['click, backend and an unknown key', 'click = "tap"\nbackend = "x"\nicn = 1\n'],
  ['every top-level problem', 'zz = 1\nicon = ""\nclick = 1\nbackend = 2\n[events]\nquestion = "x"\n'],
  ['problems in every event', '[events]\nsession_end = 1\nturn_done = 1\npermission = 1\nquestion = 1\ncache_expiring = 1\n'],
  ['problems inside the events in the order of the schema', '[events.session_end]\nenabled = 1\n[events.cache_expiring]\nttl = "x"\nafter = "y"\nskip_visible = 2\nenabled = 3\n[events.question]\nskip_visible = 1\nenabled = 1\n'],
  ['an event problem, an unknown key and a top problem', 'icon = 3\n[events]\nx = 1\n[events.question]\nenabled = 1\n'],

  // After and ttl.
  ['after and ttl equal', '[events.cache_expiring]\nafter = "60m"\nttl = "60m"\n'],
  ['after above ttl', '[events.cache_expiring]\nafter = "2h"\nttl = "1h"\n'],
  ['after alone above the default ttl', '[events.cache_expiring]\nafter = "2h"\n'],
  ['ttl alone below the default after', '[events.cache_expiring]\nttl = "30m"\n'],
  ['after and ttl both written as seconds', '[events.cache_expiring]\nafter = 100\nttl = 200\n'],
  ['after zero', '[events.cache_expiring]\nafter = 0\n'],
  ['after not below ttl with an unknown key', '[events.cache_expiring]\nafter = "2h"\nttl = "1h"\nzz = 1\n'],
  ['the check skipped after a bad duration', '[events.cache_expiring]\nafter = "5x"\nttl = "1h"\n'],
  ['the check skipped after a wrong type of enabled', '[events.cache_expiring]\nenabled = "x"\nafter = "2h"\nttl = "1h"\n'],
  ['the check skipped after a wrong type of skip_visible', '[events.cache_expiring]\nskip_visible = 5\nafter = "2h"\nttl = "1h"\n'],
  ['the check skipped after a duration of the wrong type', '[events.cache_expiring]\nafter = true\nttl = "1h"\n'],
  ['two bad durations and an unknown key', '[events.cache_expiring]\nzz = 1\nttl = "1.5h"\nafter = "x"\n'],
  ['a duration that is a date', '[events.cache_expiring]\nafter = 1979-05-27\n'],
  ['a duration that is a time', '[events.cache_expiring]\nttl = 07:32:00\n'],
  ['a duration that is a local date-time', '[events.cache_expiring]\nttl = 1979-05-27T07:32:00\n'],
  ['a duration that is a boolean', '[events.cache_expiring]\nttl = false\n'],
  ['a duration that is an array', '[events.cache_expiring]\nafter = [1]\n'],
  ['a duration that is a table', '[events.cache_expiring]\nafter = { a = 1 }\n'],
  ['a duration that is nan', '[events.cache_expiring]\nafter = nan\n'],
  ['a duration that is infinity', '[events.cache_expiring]\nafter = inf\n'],
  ['a duration that overflows a float', '[events.cache_expiring]\nafter = 1e400\nttl = 5\n'],
  ['a duration that is minus infinity', '[events.cache_expiring]\nafter = -inf\n'],

  // Strings and numbers that are or are not durations, as ttl with a zero after.
  ...[
    '"90"', '"45s"', '"50m"', '"2h"', '"1h30m"', '"1h2m3s"', '"0s"', '"0"', '"00090"', '"1h1h"', '"30m1h"', '"1.5h"', '"1h30"', '"1H"', '"5x"', '"m"', '"h"', '""', '" 5m"', '"5m "', '"1h 30m"', '"-1"', '"+5"', '"1e3"', '"0x10"',
    '"\u0663"', '"\uff19\uff10"', '"90\\n"', '"5m\\n"', '"\\t5m"', '"5\\u0000"', '"a\\"b"', '"a\\\\b"', '"\u{1F600}"', '"5\u00e9"',
    '"9007199254740991"', '"9007199254740992"', '"9007199254740993"', '"9007199254740991s"', '"9007199254740992s"', '"2501999792983h"', '"2501999792984h"', '"150h9007199254740991s"', '"99999999999999999999"', '"99999999999999999999h"',
    '"0h0m0s"', '"1h0m"', '"00h00m01s"', '"3600s"',
    '90', '0', '-0', '+5', '1_000', '0b101', '0o17', '0x1F', '0xff', '1e1', '1.0e1', '1.0', '5e-1', '1.5', '-1', '-1.5', '1e21', '1e300', '-1e400', '1_0.5', '9007199254740991', '4503599627370496', '0.1e1', '12345678.9e-1',
  ].map((lit) => [`ttl as ${lit}`, `[events.cache_expiring]\nafter = 0\nttl = ${lit}\n`] as const),
  ...['"90"', '"1h30m"', '"1h31m"', '90', '"5m"', '5e-1', '"1.5h"', '9007199254740991'].map((lit) => [`after as ${lit}`, `[events.cache_expiring]\nafter = ${lit}\nttl = "9007199254740991"\n`] as const),
  ['ttl at the largest safe number of seconds beside the one below', '[events.cache_expiring]\nafter = 9007199254740990\nttl = 9007199254740991\n'],
  ['after and ttl one second apart at the top of the range', '[events.cache_expiring]\nafter = 9007199254740989\nttl = 9007199254740990\n'],

  // TOML that is not valid, or that node and the Rust parser may read differently.
  ['a missing value', 'click = \n'],
  ['a value that is not TOML', 'click = goto\n'],
  ['an unterminated string', 'click = "goto\n'],
  ['an unterminated table header', '[events\n'],
  ['a key without a value', 'click\n'],
  ['a key defined twice', 'click = "goto"\nclick = "dock"\n'],
  ['a table defined twice', '[events]\n[events]\n'],
  ['a value that redefines a table', 'events = 1\n[events.question]\n'],
  ['trailing garbage', 'click = "goto" x\n'],
  ['a date that does not exist', 'icon = 1979-13-45\n'],
  ['a leading zero', 'after = 01\n'],
  ['a double underscore', '[events.cache_expiring]\nafter = 1__0\n'],
  ['an underscore after the prefix', '[events.cache_expiring]\nafter = 0x_1\n'],
  ['a trailing underscore', '[events.cache_expiring]\nafter = 10_\n'],
  ['a bare plus', '[events.cache_expiring]\nafter = +\n'],
  ['an exponent without digits', '[events.cache_expiring]\nafter = 1e\n'],
  ['a float without digits after the dot', '[events.cache_expiring]\nafter = 1.\n'],
  ['a float without digits before the dot', '[events.cache_expiring]\nafter = .5\n'],
  ['a byte order mark', '\ufeffclick = "goto"\n'],
  ['carriage returns and line feeds', 'click = "goto"\r\n[events.question]\r\nenabled = false\r\n'],
  ['a carriage return alone', 'click = "goto"\r[events.question]\r'],
  ['no newline at the end', 'click = "goto"'],
  ['tabs and spaces around everything', '\t click\t=\t"goto"\t \n  [ events . question ]\n enabled = false\n'],
  ['a control character in a string', 'icon = "a\u0001b"\n'],
  ['an escape of TOML 1.1', 'icon = "a\\eb"\n'],
  ['a hex escape of TOML 1.1', 'icon = "a\\x41b"\n'],
  ['a time without seconds', 'icon = 07:32\n'],
  ['an inline table over two lines', 'events = {\n  question = { enabled = false },\n}\n'],
  ['an unknown key holding an unsafe integer', 'zzz = 9007199254740993\n'],
  ['an unsafe integer inside an array', 'zzz = [1, [9007199254740993]]\n'],
  ['an unsafe integer inside an inline table', 'zzz = { a = { b = -9007199254740993 } }\n'],
  ['an unsafe integer in an array of tables', '[[zzz]]\na = 9007199254740993\n'],
  ['an integer beyond 64 bits', 'zzz = 18446744073709551616\n'],
  ['an integer that is the minimum of 64 bits', 'zzz = -9223372036854775808\n'],
  ['a hexadecimal integer beyond 2^53', 'zzz = 0x20000000000000\n'],
  ['an octal integer beyond 2^53', 'zzz = 0o400000000000000000\n'],
  ['a binary integer beyond 2^53', 'zzz = 0b100000000000000000000000000000000000000000000000000000\n'],
  ['an integer of 2^53 less one in the unknown key', 'zzz = 9007199254740991\n'],
  ['a float beyond 2^53 in an unknown key', 'zzz = 9007199254740993.0\n'],
  ['a float that overflows in an unknown key', 'zzz = 1e400\n'],
  ['nan with a sign in an unknown key', 'zzz = [-nan, +nan, +inf]\n'],
  ['a local date in an unknown key', 'zzz = 1979-05-27\n'],
  ['a mixed array', 'zzz = [1, "a", true]\n'],
  ['an unknown key inside an array of tables', '[[events.question]]\nenabled = true\n'],
];

// Cases that need a file system layout and not a document.
const layouts: Case[] = [
  { name: 'no plugins directory', setup: 'missing' },
  { name: 'a directory named notify.toml', setup: 'directory' },
  { name: 'a file without read permission', setup: 'unreadable', toml: 'click = "goto"\n' },
  { name: 'plugins is a file', setup: 'plugins-is-a-file' },
  { name: 'a dangling symlink', setup: 'dangling-symlink' },
  { name: 'only a notify.yaml', setup: 'yaml-only', toml: 'click: goto\n' },
  { name: 'a symlink to a valid file', setup: 'symlink', toml: 'click = "goto"\n' },
  { name: 'a file that is not UTF-8', setup: 'document', hex: '636c69636b203d2022676f746f222023206120ff620a' },
  { name: 'a file that is not UTF-8 inside a string', setup: 'document', hex: '69636f6e203d2022ff2e706e67220a' },
  { name: 'a file that is not UTF-8 in a key', setup: 'document', hex: '22ff22203d20310a' },
];

function make(c: Case, dir: string): void {
  const file = pluginOptionsFile(dir, 'notify');
  const plugins = path.dirname(file);
  const bytes = c.hex !== undefined ? Buffer.from(c.hex, 'hex') : Buffer.from(c.toml ?? '', 'utf8');
  switch (c.setup) {
    case 'missing':
      return;
    case 'plugins-is-a-file':
      fs.writeFileSync(plugins, 'not a directory');
      return;
    case 'directory':
      fs.mkdirSync(file, { recursive: true });
      return;
    case 'dangling-symlink':
      fs.mkdirSync(plugins, { recursive: true });
      fs.symlinkSync(path.join(dir, 'nowhere.toml'), file);
      return;
    case 'yaml-only':
      fs.mkdirSync(plugins, { recursive: true });
      fs.writeFileSync(path.join(plugins, 'notify.yaml'), bytes);
      return;
    case 'symlink':
      fs.mkdirSync(plugins, { recursive: true });
      fs.writeFileSync(path.join(dir, 'real.toml'), bytes);
      fs.symlinkSync(path.join(dir, 'real.toml'), file);
      return;
    case 'unreadable':
      fs.mkdirSync(plugins, { recursive: true });
      fs.writeFileSync(file, bytes);
      fs.chmodSync(file, 0);
      return;
    case 'document':
      fs.mkdirSync(plugins, { recursive: true });
      fs.writeFileSync(file, bytes);
  }
}

function run(c: Case): Record<string, unknown> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-vectors-'));
  try {
    make(c, dir);
    const r = loadPluginOptions(dir, 'notify', NotifyOptionsSchema);
    const base = { name: c.name, setup: c.setup, ...(c.toml !== undefined ? { toml: c.toml } : {}), ...(c.hex !== undefined ? { hex: c.hex } : {}) };
    if (r.ok) return { ...base, expect: { kind: r.found ? 'found' : 'missing', options: r.value } };
    const file = r.file;
    const problems = r.problems.map((p) => p.replaceAll(file, FILE));
    // A message of the TOML parser ends in a code excerpt that the Rust parser does not write: only its first line is kept, and `reason` says whether that line is pinned or only the start of it.
    const syntax = problems.length === 1 && problems[0]!.startsWith(`${FILE}: Invalid TOML document: `);
    if (!syntax) return { ...base, expect: { kind: 'invalid', problems } };
    const first = problems[0]!.split('\n')[0]!;
    return { ...base, expect: { kind: 'invalid', problems: [first], syntax: true, pinned: first.includes('cannot be represented losslessly') } };
  } finally {
    // A file made unreadable cannot be removed by the recursive removal of its directory on every system, so it is made readable first.
    for (const f of [path.join(dir, 'plugins', 'notify.toml')]) {
      try {
        fs.chmodSync(f, 0o600);
      } catch {
        // Nothing to restore.
      }
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// The environments `configDir` is asked about, with the home directory it falls back to.
const HOME = '/h';
const environments: Array<Record<string, string>> = [
  {},
  { TAGENTS_CONFIG_DIR: '/c' },
  { TAGENTS_CONFIG_DIR: ' /c ' },
  { TAGENTS_CONFIG_DIR: '' },
  { TAGENTS_CONFIG_DIR: '  \t' },
  { TAGENTS_CONFIG_DIR: '\ufeff', XDG_CONFIG_HOME: '/x' },
  { TAGENTS_CONFIG_DIR: '\u00a0\u2028\u2029\u3000' },
  { TAGENTS_CONFIG_DIR: '\u200b' },
  { TAGENTS_CONFIG_DIR: '\u180e' },
  { TAGENTS_CONFIG_DIR: '\u0085' },
  { TAGENTS_CONFIG_DIR: '/c', XDG_CONFIG_HOME: '/x' },
  { TAGENTS_CONFIG_DIR: ' ', XDG_CONFIG_HOME: '/x' },
  { TAGENTS_CONFIG_DIR: '', XDG_CONFIG_HOME: '' },
  { XDG_CONFIG_HOME: '/x' },
  { XDG_CONFIG_HOME: '/x/../y/' },
  { XDG_CONFIG_HOME: 'rel/./dir//' },
  { XDG_CONFIG_HOME: ' ' },
  { XDG_CONFIG_HOME: '\ufeff' },
  { XDG_CONFIG_HOME: '' },
  { XDG_CONFIG_HOME: '/' },
  { XDG_CONFIG_HOME: '..' },
  { TAGENTS_CONFIG_DIR: 'relative/dir' },
];

function configDirs(): unknown[] {
  const home = process.env['HOME'];
  process.env['HOME'] = HOME;
  try {
    return environments.map((env) => ({ env, home: HOME, expect: configDir(env) }));
  } finally {
    if (home === undefined) delete process.env['HOME'];
    else process.env['HOME'] = home;
  }
}

export async function optionsVectors(): Promise<unknown> {
  return { documents: [...documents.map(([name, toml]) => run({ name, setup: 'document', toml })), ...layouts.map(run)], configDirs: configDirs() };
}
