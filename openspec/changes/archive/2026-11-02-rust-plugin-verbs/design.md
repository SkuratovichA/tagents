## Context

The verbs are small. `packages/core/src/cli/plugin.ts` (183 lines) parses arguments with `util.parseArgs`, resolves a package, edits or writes files and prints one catalogue line. `packages/core/src/plugin-config.ts` (267 lines) holds the resolution and the config edit. `packages/core/src/cli/scaffold.ts` builds the five files of `plugin new`. `doctor` is `packages/core/src/cli/main.ts:262-271`. The Rust binary already has the pieces a port reuses: the front door (`crates/tagents-core/src/front_door.rs`), `node.rs` (`homedir`, `join`, `basename`, `find_on_path`, `root`), `json.rs` (a parser that follows `JSON.parse`, and `quote`), `js.rs` (JavaScript white space), `child.rs` (a child with a deadline), `host::config_dir` (the twin of `configDir`, re-exported by `notify::options`), `notify::state::{state_dir, read_agent_state}` (the twins of `stateDir` and `readAgentState`), `messages::Locale::of` (`TAGENTS_LOCALE`, re-exported by `notify::phrases`), and the `toml` crate that parses `notify.toml`.

The facts below were measured on the node CLI built from this tree (`node packages/core/dist/cli/main.js`, run under `env -i` with a scratch `HOME` and `TAGENTS_CONFIG_DIR`) and on the `toml` crate 1.1.8 against smol-toml 1.9.1. They decide the design.

- Node does not round-trip the config. `addTomlEntry` parses it only to know whether the key exists, appends `[plugins.KEY]` and `from = "…"` at the end behind one blank line, parses the result again, and writes it with a temporary file `<file>.<pid>.tmp` in the same directory and a rename. `removeTomlEntry` cuts the lines of the `[plugins.KEY]` section and of its subsections (less the comment lines directly above the next header), parses again, and compares the whole document with the entry removed to the whole document after the cut. Every byte outside the splice comes back as it was.
- Both parsers implement TOML 1.1.0. On a corpus of 27 documents (comments and hand alignment, CRLF, a byte order mark, dotted keys, inline tables, arrays of tables, duplicate keys, a missing final newline, unicode keys, multi-line strings that hold a header-looking line, integers at and beyond 2^53) they agreed on whether the text parses and on its content in every case but one: smol-toml refuses an integer beyond ±(2^53−1) and the `toml` crate accepts it. `toml_js::table_holds_lossy_integer` (`toml_js.rs:12`) is that rule, moved out of `notify::options` so both features use it (task 5.1).
- A syntax error is worded by smol-toml with a code frame, which Rust cannot reproduce. `plugins` written as an array, an array of tables or a string is refused with `<file>: plugins must be a table of tables`, and an inline `plugins = { … }` fails the parse of the edit with smol-toml's own text; both leave the file untouched and exit 1.
- `plugin add <name>` resolves with `createRequire(<cwd>/package.json).resolve("<name>/package.json")`, then the global pnpm store. A package with `exports` that does not export `./package.json` is not found; a package whose `package.json` is not JSON is not found; `exports: null` is ignored; a symbolic link resolves to its real directory and the key comes from the manifest's `name`; `plain/package.json` and `plain/src` are not found. A directory argument is `path.resolve(cwd, spec)` with `~` and `~/` expanded, never resolved through node's algorithm.
- Two defects of node's writer, measured on the node CLI of this tree, are decided in D13 and fixed in node before the port. `readText` returns `''` for every read error, not only for a missing file, so a config that cannot be read (a directory, a refused permission, an I/O error) is treated as an empty one and the next write replaces it. And `writeAtomic` renames its temporary file over the config path, so a `config.toml` that is a symbolic link is replaced by a regular file and the link is gone.

## Decisions

### D1. `plugin` is a front-door group that may decline

`front_door.rs` decides by the first word and the group answers everything under it. `plugin` has to be split, because `plugin list` needs JavaScript and `plugin add` does not, and the hand-over of D3 needs the same exit. The group's `run` returns `Option<Output>`, and `None` is `exec_node` with the arguments untouched.

```rust
struct Group {
    word: &'static str,
    verbs: &'static [&'static [&'static str]],
    /// `true` reads an argument that is not UTF-8 with U+FFFD for each bad byte, as node's `process.argv` does; `false` hands such a call to node whole, because a group that works on paths must not look at a file other than the one that was typed.
    lossy_args: bool,
    /// `None` hands the call to the node CLI. It is returned before any file is written.
    run: fn(&[String], &Context) -> Option<Output>,
}

const GROUPS: &[Group] = &[
    Group { word: "sessions", verbs: sessions::VERBS, lossy_args: true,  run: sessions::run },
    Group { word: "plugin",   verbs: plugin::VERBS,   lossy_args: false, run: plugin::run },   // add, remove, new
    Group { word: "doctor",   verbs: doctor::VERBS,   lossy_args: true,  run: doctor::run },
];
```

Options considered. (1) The shape above: one table, one place that dispatches, `--spec` lists `verbs` as it does for `sessions`. (2) A second table of two-word entries beside `STREAMING`, as `notify run` has one: it would repeat the dispatch and could not decline. `notify run` is an arm of its own because it streams, which a group's `run` cannot do. (3) Mark `plugin list` as `impl: rust` and have the group exec node for it: `--spec` would claim a verb the binary does not answer. Chosen: (1), with `plugin list` staying `impl: node`.

The invariant "a verb word is served by one program" in `packages/core/test/cli-spec.test.ts` (the test of that name) is replaced by one the new shape can state: a first word whose commands are served by both programs is allowed only when every `rust` path under it has at least two words, because the group decides by the second word. `sessions` and `doctor` stay whole. A test in `crates/tagents-core/tests/front_door.rs` runs `plugin list`, a bare `plugin` and `plugin bogus` against a recording node and checks that they are forwarded with their arguments.

### D2. The config is edited by the splice node performs, with the `toml` crate as the reader

Node's algorithm is a text splice, so the Rust one is the same splice. `toml` (already a dependency, parse only) answers the two questions node asks of its parser: does the document parse, and what is under `plugins`. Everything else is string work on the file's lines.

Options considered. (A) `toml_edit`: parse to a format-preserving document, insert or remove the table, print. It adds a crate and a second parser for the same file, and it decides where a new table lands (next to an existing `[plugins.x]`, or by its own ordering) and how many blank lines surround it, which is not node's rule, so byte parity would be a fight with the library. (B) The splice with `toml` as the reader: the same bytes as node by construction, no new dependency, one parser for TOML in the binary. (C) Hand every `add` and `remove` to node: no gain. Chosen: (B). The archived S2 plan named `toml_edit`; the measurement above is why it is not used.

`add`: read the file; if the key is present under `plugins`, the answer is `pluginExists` and exit 3 with no write; otherwise append at the end behind one blank line (none when the text is empty, a newline first when the text lacks one) a section built with the writers of `config-file.ts` (`tomlString` escapes `\` and `"` and refuses control characters; `tomlKey` leaves `[A-Za-z0-9_-]+` bare and quotes anything else, so `--name a.b` writes `[plugins."a.b"]`); parse the result and check that `plugins.<key>.from` is the value; write it by temporary file and rename.

`remove`: parse; if the key is absent the answer is `pluginNotListed`, exit 3. Otherwise find the section by parsing each line that starts with `[` on its own and reading the key path of the header it is (`headerPath`), cut the section and its subsections as `cutSections` does, parse the result, and require that the key is gone and that the rest of the document is deeply equal to what it was. JavaScript white space (`js::trim`) decides which lines are blank, and NaN is equal to NaN in the comparison, as in `util.isDeepStrictEqual`.

```rust
fn add(file: &str, key: &str, from: &str) -> Result<Added, HandOver> {
    let text = read_text(file)?;                      // not UTF-8, or any error but NotFound: HandOver
    let doc = parse(&text)?;                          // a syntax error or a lossy integer: HandOver
    if doc.plugins()?.contains_key(key) { return Ok(Added::Exists); }
    let next = splice_append(&text, &section(key, from)?);
    check_added(&next, key, from)?;                   // the edit does not parse, or did not take: HandOver
    write_atomic(file, &next)?;                       // an I/O error: undo, then HandOver
    Ok(Added::Written)
}
```

A person's hand-edited config survives the way it does under node because it is the same splice, and because the proof is a corpus, not a belief: the vectors of group 2 feed every document of the corpus through node's `addPluginEntry` and `removePluginEntry` and record the text that comes out, and a Rust test requires the same text.

### D3. Rust answers only what it can prove identical; the rest goes to node before anything is written

The rule is one sentence: Rust prints only texts of the message catalogue, and any condition that node words with a literal string of its own code, or that depends on a parser or a runtime Rust does not have, is handed to node. The hand-over classes, each pinned by a case of the corpus and a parity scenario:

- Arguments outside the grammar of D4, and arguments that are not valid UTF-8.
- A config that is not valid UTF-8, or that cannot be read for any reason but not existing (node fails with the text of the error, D13, and Rust does not word it), and a `config.toml` that is a symbolic link leading nowhere or in a loop (node fails with the system's text).
- A config the `toml` crate cannot parse (smol-toml words the error with a code frame), and one that holds an integer beyond ±(2^53−1).
- A config whose `plugins` is not a table (`plugins must be a table of tables`), an edit that does not parse when written (an inline `plugins = { … }`), an edit that did not take, a key that cannot be written (a control character), a section that `remove` cannot cut (`remove it by hand`), and a cut that would change something else. Each of these is a literal in `plugin-config.ts`, not a catalogue key.
- A resolution outside the subset of D5.
- Any I/O error in the write sequence (writing the temporary file, renaming it, writing the files of `plugin new`): Rust removes the files it wrote, and for `plugin new` the directories it made below the target, so the target is as empty as node would find it, and hands the call to node, which meets the same error and words it. For `add` the only file Rust has written when a step fails is the temporary one, because the directories it created are the first thing node creates as well. Rust never words an I/O error of the write path, so it does not use `node::io_message` for these verbs, and the pid in node's temporary file name is node's.

The cost is that the unusual cases start node. The benefit is that no text, error number or parser message is copied, so none can drift.

### D4. The argument grammar is the subset of `parseArgs` that Rust can prove

`util.parseArgs` in strict mode words its own errors, and the text depends on the node version. Rust parses the arguments of the three verbs with a grammar that has no error case: a positional is any argument that does not start with `-` (a lone `-` is one); `--` ends the options and everything after it is positional; `add` takes `--name V` when `V` does not start with `-` and `--name=V` for any `V`; `new` takes `--dir V` and `--dir=V` the same way; the last occurrence wins; `remove` takes no option; a second positional is ignored, as in node. Any other argument that starts with `-` (an unknown option, a short option, a cluster, `--name` as the last word, `--name -x`) is handed to node.

### D5. Resolving a package for `plugin add` is the subset of `require.resolve` that Rust can prove

A directory argument (it starts with `.` or `~`, or is absolute) is resolved completely in Rust: `~` and `~/…` through `node::homedir`, then `path.resolve(cwd, …)`, which is a lexical normalisation (`node::resolve` is added to `node.rs` beside `join`). A read or parse failure of its `package.json` is `pluginUnresolved` (exit 1, naming `<dir>/package.json`), a manifest that fails the schema is `pluginBadManifest` and a missing entry file is `pluginNoEntry` (exit 3). The manifest is read with `json::parse` and checked as `ManifestSchema` checks it: `name` a non-empty string if present, `tagents.apiVersion` the number 1 (`1.0` counts), `tagents.entry` a non-empty string, `exports` and the rest ignored.

A bare name is resolved in Rust only when all of these hold, and is node's otherwise. The name follows the npm grammar (`name` or `@scope/name`, characters `A-Za-z0-9._~-`, first character not `.` or `_`). Neither `NODE_OPTIONS` nor `NODE_PRESERVE_SYMLINKS` is set (a `--require` hook or the symlink flag changes resolution). The nearest `package.json` at or above the working directory is not a package of that name that has `exports` (self-reference resolves before `node_modules`). Walking from the working directory up, skipping ancestors named `node_modules`, the first `node_modules/<name>/package.json` that is a regular file is found, and its content is JSON without an `exports` key (a JSON `null` counts as none). The directory is its real path (`node::realpath`, JavaScript's `fs.realpathSync` with the case kept as typed, because on a case-insensitive volume `fs::canonicalize` returns the case the disk has and `plugin add Plain` would then name another directory than node does), the key defaults from the manifest's `name` or the directory's base name, and `from` is the name as typed.

Not found by that walk is node's: node goes on to `NODE_PATH`, `~/.node_modules`, `~/.node_libraries` and `pnpm root -g`, and words the error. A package that has `exports` is node's even when it exports `./package.json`. The corpus of group 1 and the parity suite run node's own `createRequire` on a fixture tree and compare, so a missed rule is a failing case.

### D6. `plugin list` and `plugin list --json` stay with node

What each plugin offers (`commands`, `services`, `mcpTools`, the definition's `name` and `apiVersion`) comes from `import(pathToFileURL(entry))` of the plugin's entry in `host.ts` and from running `definePlugin`. A Rust `list` would have to run JavaScript, so it would start node anyway, and answering the empty-config case alone would copy `readPluginList`'s zod error texts. The plugin host is stage S4; `plugin list` moves with it. Rejected: serving `list` for a config with no plugins.

### D7. Every text comes from the catalogue, exported to a file

The texts are keys of `packages/core/src/i18n/{en,ru}.ts`, interpolated by i18next (`escapeValue: false`). Rust reads them from `spec/cli/messages.json`, which `packages/core/src/i18n/export.ts` writes from the two resources (`pnpm messages:gen`), and CI runs `pnpm messages:check`, which regenerates and fails on a difference, as `pnpm plugin:check` does for the contract. The file holds every key of both locales, so there is no list of keys to keep; the generator refuses a text that uses anything of i18next but `{{name}}` (plural suffixes, nesting, formats), because Rust implements only that. `crates/tagents-spec` parses the file and `Locale::of` (`TAGENTS_LOCALE` is exactly `en` or `ru`, else English) picks the language. Rust's interpolation replaces each `{{name}}` once from left to right and does not rescan a value, which is what i18next does with `skipOnVariables`; a path that holds `{{x}}` or `$t(pluginNone)` prints as typed, pinned by a vector and a parity scenario.

Options considered. (A) The generated file, above. (B) A hand-written table in Rust pinned by vectors, as `notify/phrases.rs` does: 17 keys in two languages typed twice, and a change of wording in `en.ts` needs a second edit that only a failing test announces. (C) Text inside `spec/cli/tagents-core.json`: it fixes one language in a file a localised CLI reads (the archived S0 design rejected it). Chosen: (A), which is also what the S2 plan wrote down, extended to both locales.

The one line only Rust prints is the key `doctorNodeMissing`, whose whole text is `node: missing` (Russian: `node: нет`). It is added to both catalogues and used by Rust alone, so that it is exported with the rest and kept honest by the same check.

Exit codes are the ones in `spec/cli/tagents-core.json` (`exit`), which `tagents-spec` already loads; `sessions::exit` gains `REFUSED = 3` and a test requires every constant to equal the file's value.

### D8. `plugin new` renders one template file

`scaffoldFiles` builds five files from template literals and `JSON.stringify`. Rust cannot share that, so the files move into one text file, `spec/cli/scaffold/plugin.txt`, whose sections start with a line `@@ <relative path>`, followed by the body, with three placeholders: `{{name}}`, `{{dir}}` (the target directory as typed, which the README names), and `{{core|json}}`, the relative specifier of `packages/core` from the target in the JSON string escape without the quotes, which `package.json` writes after `link:`. A value is put in as it is and never read for a placeholder again. Node reads the file at run time as `SPEC_FILE` is read (`new URL('../../../../spec/cli/…', import.meta.url)` from `src/cli` and `dist/cli`), Rust compiles it in with `include_str!`. Both implement the same renderer in a dozen lines, and the escape in Rust is `json::quote`, the `JSON.stringify` twin. `spec/cli/*` is already an input of the release gate, so a change of the template raises the version with no change to `.github/scripts/core-release.sh`.

Options considered. (A) One template file read by both (chosen). (B) Five files under a directory and a list of them in each language: two lists. (C) The files as strings inside a JSON data file: every quote of the TypeScript source is escaped and the template cannot be reviewed. (D) `plugin new` stays with node: it is the one verb of the five that needs no parser, so it is the cheapest to serve.

The characterisation test comes first: before the TypeScript that builds the files is deleted, a test writes the scaffold for several `(name, dir, core)` triples (a quote and a backslash in the directory, a directory whose relative specifier starts with `.`, an empty relative path) and pins the bytes; the template must reproduce them. `relativeSpecifier` keeps its quirk (a relative path that starts with `.`, such as `.hidden/x`, gets no `./`), and `node::relative` is the `path.relative` twin that Rust needs: `plugin/scaffold.rs` calls it to make the specifier `relativeSpecifier` makes from the target to `packages/core`, quirk included, which is the value of `{{core|json}}`. The core directory is `<root>/packages/core` with `<root>` from `node::root()`; when that fails the call is node's.

### D9. `doctor` runs one `node -p`

`doctor` ignores its arguments and prints four lines: the node version and path, the state directory and its record count, the config file and whether it exists, `claude` on `PATH`. The version and the executable path are `process.version` and `process.execPath` of the node that runs the CLI, and `execPath` is what the operating system reports for that node, which can differ from the path that started it. So Rust asks that node once: `node -p 'JSON.stringify([process.version, process.execPath])'`, through `child::run` with a deadline of 10 seconds, with the node chosen as `exec_node` chooses it (`$TAGENTS_NODE`, else `node` on `PATH`; the choice moves into a function of `node.rs` both use). The state directory, the record count and the config dir come from `notify::state::{state_dir, read_agent_state}` and `notify::options::config_dir`; the lookup of `claude` is `node::find_on_path`. A SIGTERM, SIGINT or SIGHUP while node is asked stops it, through one `Stop` tripped from `ending::on_signals` as the MCP server's is, because `child::run` puts node in a group of its own that the terminal's Ctrl-C does not reach; the verb then prints nothing and exits with 128 plus the number of the signal.

When node cannot be started, exits non-zero, does not answer in time or prints something that is not an array of exactly two strings, line one is `doctorNodeMissing` (`node: missing`; the Russian says the same) and the verb still exits 0 with the other three lines: the point of `doctor` is to say what is wrong. Node has no such line, since it cannot run without node, so this is the one output with no oracle; it is asserted by a test, not compared.

Rejected: `node --version` (it gives no executable path, so line one would differ from node's), and reading a version from the environment.

### D10. Pins and parity

Two kinds of copy exist, and each is pinned.

- Helpers that exist twice (the splice and its corpus, the resolution, the interpolation, the scaffold renderer, `relativeSpecifier`, the exit table) are pinned by vectors: `tests/rust-plugin-vectors.mts` runs the node functions on the corpus and writes `crates/tagents-core/tests/fixtures/plugin-vectors.json`; `cargo test -p tagents-core --test plugin_vectors` requires Rust to give the same output or to hand over where D3 says so; CI regenerates the file and runs `git diff --exit-code`, as it does for `tests/rust-notify-vectors.mts`.
- The verbs as a whole are pinned by `tests/rust-plugin-parity.sh`: for each scenario it copies a pristine scratch tree, runs node on it, restores the tree, runs `target/debug/tagents-core` (or `$TAGENTS_CORE_BIN`) on it, and passes only when stdout, stderr, the exit code and the bytes and modes of every file in the tree are equal. It runs under `env -i` with a scratch `HOME`, `TAGENTS_CONFIG_DIR`, `TA_STATE_DIR`, `TAGENTS_NODE` and `PATH`, so no real tagents file, no real tmux server and no real home is touched, and it needs node and bash 3.2 only.

The scenarios, each in `en` and in `ru` where it prints:

- `add` by directory: absolute, `./x`, `../x`, `~/x`, a trailing slash, a `..` inside; by name from a nested working directory, scoped, through a symbolic link, a package with `exports` (node's answer), `exports: null`, a name that is not found.
- `add` refusals: no argument; a directory without `package.json`; a `package.json` that is not JSON; a manifest without `tagents`; `apiVersion` 2; `name: ""`; an entry that is missing or a dangling link; a key that is listed; a bad key (`--name -`, a unicode key).
- `add` arguments: `--name`, `--name=`, `--name -x`, `--name` last, `--nope`, `-x`, `--`, two positionals.
- `add` keys: the default from `@tagents/plugin-telegram`, `tagents-plugin-x`, `plugin-x`, a bare name, a name that trims to nothing; `--name a.b` (quoted).
- The config under `add`: missing (created with its parent directories), empty, no final newline, CRLF, a byte order mark, comments and hand-aligned values, an existing section of another key, dotted `plugins.a.from`, inline `plugins = {}`, `plugins` as an array, a string and an array of tables, a syntax error, an integer beyond 2^53, a duplicate key, text that is not UTF-8, a config that is a directory, a config that is a symbolic link (into another directory, to a file in a directory that is a link, to nowhere, in a loop, to a directory), a config the user cannot read (skipped when the suite runs as root), a config directory that is not writable.
- `remove`: the last entry (the file returns to its text before `add`), one of several, comments above and below a header, a subsection, an entry written dotted, a header-looking line inside a multi-line string, a quoted key, a key that is not listed, a missing config, no name.
- `new`: the default directory, `--dir`, `--dir .` in an empty directory, a directory that holds a file, an empty directory, a directory that is a file, an unwritable parent, a bad name, no name, a quote and a non-ASCII character in the directory, `--dir=` forms.
- `doctor`: a state directory with a valid record, a broken record and a file that is not a record; an empty one and a missing one; the config present and missing; `claude` on `PATH` and not; extra arguments; `TAGENTS_LOCALE=ru`.
- Hand-over: `plugin list`, `plugin list --json`, a bare `plugin`, `plugin bogus`, `plugin add --nope`.

The existing forward loop of `tests/rust-parity.sh` keeps `plugin`, `plugin new`, `doctor` and `doctor --x`; they become comparisons of two Rust-served answers with node's.

### D11. Version, release gate and documents

`spec/cli/*` and `crates/*/src/*` are inputs of the binary (`.github/scripts/core-release.sh:20`), so each pull request that serves a verb raises the workspace version one step above its merge base, as the gate (`sh .github/scripts/core-release.sh gate origin/main`) prints. No new file location needs a gate change, because `messages.json` and the scaffold sit under `spec/cli/`. `pnpm plugin:gen` runs after the flags change and must show no diff in the contract and the references.

`docs/architecture/rust-core.md` gains the verbs in "What is served in Rust today", the group that may decline in "Which program a command goes to", a section on the plugin verbs (the splice, the hand-over classes, the resolution subset, the single sources), the new suite in "The parity suite", the observations of "Known differences" below, and the version lines the gate names.

### D12. Pull requests

(a) This proposal and groups 1 to 7, `plugin add` and `plugin remove`: the two fixes of node's writer (D13), the pins, the group that may decline, the generated messages, the splice, the resolution and the verbs, the flags last. It is the larger half and the riskier one, and it carries the proposal so that the design is reviewed with the code it governs. (b) Groups 8 to 13: the scaffold source, `plugin new`, `doctor`, the documents, the archive. Each of (a) and (b) is mergeable alone with the node fallback intact: the verbs that are not flipped are `impl: node` and reach node through the front door, and the generated messages and the group that may decline change no answer by themselves.

### D13. Two defects of node's writer are fixed in node first

The port would copy two behaviours of `plugin-config.ts` that lose a person's data, so they change in node before Rust mirrors them. Each is a commit of its own, `fix(core): ...`, with a test written first and seen failing, and each has a requirement in the delta spec of `plugin-system`.

A symbolic `config.toml` keeps its link. People keep their configs in a dotfiles repository behind links, and `writeAtomic` renames its temporary file over the path of the link, so the first `plugin add` replaces the link with a regular file and the repository stops holding the config. The edit asks `lstat` whether the path is a link, takes `fs.realpathSync` of it when it is, and writes the temporary file beside that target and renames it over the target. The question is asked before the config is read, so a link to nowhere or in a loop fails at once with the system's error (`ENOENT` or `ELOOP`, with the path the system names) and nothing is created at the end of the link. A path with nothing at it is not a link, and the config is created there. `writeAtomic` itself is not changed: it is exported from `@tagents/core` and the notify package writes its LaunchAgent plist and its tests write `notify.toml` through it, and none of them asked for link-following.

Only a missing config reads as empty. `readText` returns `''` for `ENOENT` (`errnoCode` of `errno.ts`) and rethrows every other error, so a config that cannot be read fails the verb with the error's own text through the catch of `main()` (stderr, exit 1) and nothing is written. The text is not given a file name of its own wording: an `EACCES` or `ENOTDIR` text carries the path, and an `EISDIR` text does not, and the design keeps the system's words rather than invent a prefix. A missing config under `remove` is still `pluginNotListed` with exit 3, and an empty file still means `absent`. The host's reading of the config for `plugin list` and for the plugin commands is a different reader (`parseConfigFile`, `readPluginList`) and keeps its rule that an unreadable file means no plugins.

Rust mirrors both. It asks `symlink_metadata` and `node::realpath` (D5) in the same order and writes `<target>.<pid>.tmp` beside the target; a missing path is not a link; a read error but `NotFound`, and a link that cannot be resolved, are handed to node before any write, so Rust never words the system's errors and the two programs say the same thing because it is node that says it. The parity suite covers the link that is kept, the link to nowhere, the loop, a link to a directory, a config that is a directory and a config the user cannot read.

Options considered. (A) Fix node, then mirror (chosen): one behaviour, one oracle. (B) Mirror node's defects and pin them in the parity suite: the port would spread the data loss to the binary people run most. (C) Fix only Rust: the two programs would differ on the same call, which is what the parity suite exists to forbid. (D) Make `writeAtomic` follow links: it changes a function other packages call, for a need only the config edit has.

## Where the two are known to differ

- `doctor` prints `node: missing` when node cannot be started; node cannot print anything then.

Both programs share one property, which this change does not alter: two adders that race read the same file and the later rename wins, since `<file>.<pid>.tmp` is private to a process and nothing locks the config. Changing it is a change to node's writer first.

## Risks and trade-offs

- A divergence of the two TOML parsers that the corpus did not contain: Rust would write where node refuses, or the reverse. The edit is guarded by the same parse and equality checks as node's, run by the `toml` crate, so a document Rust misreads still has to survive its own check; the corpus is open to additions and each divergence found becomes a hand-over class.
- The subset of resolution is the part that can disagree silently: a package Rust finds that node would not. Every condition that makes node's answer differ (`exports`, `NODE_OPTIONS`, a self-reference, a manifest that is not JSON) is a hand-over, and the parity fixture tree contains one package per condition.
- The two fixes of D13 change what node does for a symbolic config and for an unreadable one. Rust hands every failure of either kind to node, so the only new Rust path is the success path through a link; it is compared with node by the parity suite on a config that is a link.
- A generated `messages.json` is a file under review that nobody edits by hand; `pnpm messages:check` in CI is what keeps it honest.
- The undo of a failed write is code that runs rarely. It is unit-tested with an injected failing writer, and the parity suite covers the failures that can be made in a scratch tree (an unwritable parent, a path component that is a file).

## Open Questions

None. `plugin list` and the plugin host are stage S4's decision.
