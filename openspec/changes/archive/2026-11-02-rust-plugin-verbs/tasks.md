The tasks serve `plugin add`, `plugin remove`, `plugin new` and `doctor` from the Rust binary and leave `plugin list` with node. The change ships in two pull requests, merged in this order. (a) This proposal and groups 1 to 7: the two fixes of node's config writer, the pins, the front-door group, the generated messages, the config splice, the resolution, and `plugin add` and `plugin remove` with the verbs wired into `plugin::run` and their flags flipped last among the code (task 7.3), so that until that task the front door forwards both to node. (b) Groups 8 to 13, merged after (a): the scaffold, `plugin new`, `doctor`, the completion of the suite, the documents and the archive. Groups 2 to 10 change inputs of the binary (`is_input` in `.github/scripts/core-release.sh:18-23`), so (a) and (b) each raise the workspace version one step above their merge base (`sh .github/scripts/core-release.sh gate origin/main` prints what to change), and a pull request that rebases onto a version another one raised raises it again. Every gate below runs in the worktree of the pull request, shell suites as `env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh`.

## 1. Node's config writer first

- [x] 1.1 A test in `packages/core/test/plugin-cli.test.ts`, written first and seen failing: a `config.toml` that is a symbolic link into another directory stays a link under `plugin add` and `plugin remove` (the link text and the text of its target are checked), a link to nowhere and a link loop fail with exit 1 and the system's error, and neither leaves a file at the end of the link or a temporary file (`pnpm --filter @tagents/core test`)
- [x] 1.2 `plugin-config.ts` writes through the link: `writeTarget` is the real path when the config is a link and the path itself otherwise, asked before the config is read, and the temporary file is written beside it and renamed over it; the test of 1.1 passes, and the test and the fix are one commit `fix(core): ...` (`pnpm --filter @tagents/core test`)
- [x] 1.3 A test, written first and seen failing: a `config.toml` that is a directory fails `plugin add` and `plugin remove` with exit 1 and the text of the error and writes nothing, a file the user cannot read does the same when the tests do not run as root, and a missing config is still read as empty (`pnpm --filter @tagents/core test`)
- [x] 1.4 `readText` in `plugin-config.ts` returns `''` only for a missing file (`errnoCode` of `errno.ts`) and throws every other error; the test of 1.3 passes, and the test and the fix are one commit `fix(core): ...` (`pnpm --filter @tagents/core test`)

## 2. The pins, written before the code

- [x] 2.1 The corpus: `tests/rust-plugin-vectors/corpus/` holds the 27 documents of the design's measurements (comments and hand alignment, CRLF, a byte order mark, dotted keys, inline `plugins`, `plugins` as an array, a string and an array of tables, a syntax error, a duplicate key, an integer at and beyond 2^53, no final newline, unicode keys, a multi-line string with a header-looking line, an entry with a subsection, a quoted key) and a fixture tree of packages for resolution (plain, scoped, linked, `exports` with and without `./package.json`, `exports: null`, a manifest that is not JSON, no `name`, an empty `name`, `apiVersion` 2, a missing and a dangling entry, a `package.json` above the working directory that names the package and has `exports`)
- [x] 2.2 `tests/rust-plugin-vectors.mts` runs node's `addPluginEntry`, `removePluginEntry` and `resolvePluginPackage` on the corpus in scratch directories and writes `crates/tagents-core/tests/fixtures/plugin-vectors.json` (the text that comes out, or the outcome and message, with scratch paths normalised); it also records `relativeSpecifier` and the scaffold's files for a set of `(name, dir, core)` triples, and the output of i18next for every key of both locales with sample values, among them a value that holds `{{x}}` and one that holds `$t(pluginNone)` (`node tests/rust-plugin-vectors.mts`, then `git diff --stat` shows the new fixture)
- [x] 2.3 `crates/tagents-core/tests/plugin_vectors.rs` reads the file and requires, for each vector, Rust's output to equal node's or to be a hand-over where design D3 lists the class, and the test fails because the module does not exist (`cargo test -p tagents-core --test plugin_vectors`, seen failing for that reason)
- [x] 2.4 `tests/rust-plugin-parity.sh` with the scenarios of design D10 for `add` and `remove` (among them a config that is a symbolic link, a link to nowhere, a link loop, a directory and a file that cannot be read), written against `$TAGENTS_CORE_BIN`; the suite takes `PARITY_SELF_TEST=1` (node on both sides, as `tests/rust-notify-parity.sh` does), which proves the harness itself before any Rust verb exists (`PARITY_SELF_TEST=1 bash tests/rust-plugin-parity.sh`, exit 0)
- [x] 2.5 The step "Parity of plugin add and plugin remove with the node ones, files and exit codes included" in `.github/workflows/rust.yml` after the three parity steps of the CLI, the MCP server and the notify daemon, the step that regenerates `plugin-vectors.json` and runs `git diff --exit-code` on it, and `pnpm messages:check` in `.github/workflows/ci.yml` after `pnpm plugin:check` (`actionlint`, the global binary, since the repository has no wrapper)

## 3. The front door

- [x] 3.1 `Group::run` returns `Option<Output>`: `sessions::run` wraps its answer in `Some`, `front_door::run` execs node on `None`, and the module comment at the top of `front_door.rs` says that a group may decline (`cargo test -p tagents-core --lib`)
- [x] 3.2 `sessions::exit` gains `REFUSED = 3`, and a unit test requires `OK`, `ERROR`, `USAGE` and `REFUSED` to equal the `exit` table of `spec/cli/tagents-core.json` as `tagents-spec` loads it
- [x] 3.3 The invariant of `packages/core/test/cli-spec.test.ts` ("a verb word is served by one program") becomes "a first word served by both programs has only `rust` paths of two words or more"; the test is written first and fails against a spec that splits a one-word verb (`pnpm --filter @tagents/core test`)
- [x] 3.4 `crates/tagents-core/tests/front_door.rs`: a test that `plugin list`, a bare `plugin` and `plugin bogus` are forwarded with their arguments, and a unit test that `plugin::run` returns `None` for them (`cargo test -p tagents-core --test front_door`)

## 4. The messages

- [x] 4.1 `packages/core/src/i18n/export.ts` writes `spec/cli/messages.json` from the two resources and refuses a text that uses more of i18next than `{{name}}`; the root `package.json` gets `messages:gen` and `messages:check` (`pnpm messages:gen`, then `pnpm messages:check` exits 0, and exits non-zero after an edit of `en.ts`)
- [x] 4.2 The keys `doctorNodeMissing` in `en.ts` and `ru.ts` (`node: missing`, `node: нет`), with a comment that only the Rust `doctor` prints it, and the test of the catalogues that both languages have the same keys passes (`pnpm --filter @tagents/core test`)
- [x] 4.3 `crates/tagents-spec` parses `messages.json` and refuses an unknown shape; the interpolation (`{{name}}` once, left to right, no rescan of a value) and the locale choice through `messages::Locale::of` are one function, tested against the vectors of 2.2 (`cargo test -p tagents-spec`, `cargo test -p tagents-core --test plugin_vectors`)

## 5. The config splice

- [x] 5.1 The lossy-integer check of `notify/options.rs` (`table_holds_lossy_integer`, `holds_lossy_integer`, `integer`) moves to a module both use, with the notify tests unchanged (`cargo test -p tagents-core notify::options`)
- [x] 5.2 `crates/tagents-core/src/plugin/config.rs`: `write_target` (the real path when the config is a symbolic link, a hand-over when that fails), `read_text` (a hand-over for non-UTF-8 and for any error but not found), `parse` through `toml::de::DeTable` (a hand-over for a syntax error and a lossy integer), the shape check, `splice_append`, `header_path` of a single line, `cut_sections`, the re-parse and the equality of documents with NaN equal to NaN, `write_atomic` as `<target>.<pid>.tmp` beside the target plus a rename over it, removing the temporary file when a step fails; JavaScript white space through `js::trim` (`cargo test -p tagents-core plugin::config`, `cargo test -p tagents-core --test plugin_vectors`)
- [x] 5.3 The writers of `config-file.ts` in Rust: `toml_string` (escape `\` and `"`, refuse a control character) and `toml_key` (bare for `[A-Za-z0-9_-]+`), their vectors in 2.2 (`cargo test -p tagents-core --test plugin_vectors`)
- [x] 5.4 An injected failing writer proves that a failed step removes the temporary file and hands over (`cargo test -p tagents-core plugin::config`)

## 6. Resolution

- [x] 6.1 `node.rs` gains `resolve` (`path.resolve`) beside `join`, `relative` (`path.relative`) and `interpreter` (`$TAGENTS_NODE`, else `node`, the choice `exec` makes), each with unit tests against the vectors, and `exec` calls `interpreter` (`cargo test -p tagents-core node::`)
- [x] 6.2 `crates/tagents-core/src/plugin/resolve.rs`: the directory path in full, the bare name by the walk of design D5, `ManifestSchema` over `json::parse`, the three problems `not-found`, `bad-manifest` and `no-entry`, `from` and the default key (`defaultPluginName`), and a hand-over for every condition of D5 (`cargo test -p tagents-core plugin::resolve`, `cargo test -p tagents-core --test plugin_vectors`)

## 7. plugin add and plugin remove

- [x] 7.1 `crates/tagents-core/src/plugin.rs`: `VERBS`, the argument grammar of D4, the order of checks of `plugin.ts` (missing argument, resolve, key, config), `NAME`, and the catalogue lines `pluginAdded`, `pluginExists`, `pluginRemoved`, `pluginNotListed`, `pluginUnresolved`, `pluginBadManifest`, `pluginNoEntry`, `pluginBadName`, `missingOption`; the functions `add` and `remove` are not yet called by `run`, which returns `None` for everything (`cargo test -p tagents-core plugin::`)
- [x] 7.2 Unit tests for the grammar: `--name V`, `--name=V`, `--name=`, `--name ""`, `--name -x`, `--name` last, `-x`, `-`, `--`, `-- --name`, two positionals, a non-UTF-8 argument
- [x] 7.3 The verbs: `add` and `remove` wired into `plugin::run`, which returns `None` for `list`, an unknown verb, a bare `plugin` and every hand-over; the group `plugin` in `GROUPS`; `"impl": "rust"` for `["plugin", "add"]` and `["plugin", "remove"]` in `spec/cli/tagents-core.json`; the last task of the code of this pull request. `pnpm plugin:gen` and `pnpm plugin:check` show no diff, `--spec` lists the two, and `cargo test -p tagents-core --test front_door` passes
- [x] 7.4 `tests/rust-plugin-parity.sh` against the live Rust verbs, with the scenarios of design D10 for `add` and `remove`, in `en` and `ru` (`bash tests/rust-plugin-parity.sh`, exit 0)
- [x] 7.5 Mutations of the Rust code each make `plugin_vectors` or the suite fail: the blank line before the section left out, a comment line cut with the section, `NaN` unequal to itself, the lossy-integer check dropped, `exports` ignored, `NODE_OPTIONS` ignored, the temporary file left behind by a failed write, the symbolic link replaced by a regular file, any read error taken as an empty config (one failing check each, listed in the pull request)
- [x] 7.6 `docs/architecture/rust-core.md`: the two verbs in "What is served in Rust today", the group that may decline in "Which program a command goes to", the section "The plugin verbs" (the splice, the hand-over classes, the resolution subset, the catalogue file), the suite in "The parity suite", and the version lines the gate names; the sentences elsewhere in `docs/` that say node runs `plugin add` or `plugin remove` (`pnpm docs:check` if it exists, else `grep -rn "plugin add" docs`)
- [x] 7.7 `CHANGELOG.md`: one line under `[Unreleased]` in "Added" saying that `tagents-core plugin add` and `plugin remove` run in the prebuilt Rust binary when the installer has put one on the machine, with no `(#N)`
- [x] 7.8 The release gate: the workspace version raised one step in `Cargo.toml`, `Cargo.lock` and the version lines of `docs/architecture/rust-core.md` (`sh .github/scripts/core-release.sh gate origin/main` exits 0, `bash tests/release.sh` exits 0)
- [x] 7.9 The gates: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked`, `pnpm build`, `pnpm --filter @tagents/core test`, `pnpm spec:check` and `pnpm exec openspec validate rust-plugin-verbs --strict`, each exit 0
- [x] 7.10 `LEARNING.md`: the line "A task list that registers a verb group in `GROUPS` before flipping the flags makes every verb live at once; wire each verb into `run` and flip its `impl` flag last, then run parity" under "Rust core and the MCP server", dated 01.11.2026

Where (a) differs from the wording above, each in one line:

- The corpus is the module `tests/rust-plugin-vectors/corpus.mts` with 61 documents (the 27 of the design and realistic ones beside them), not a directory (2.1), and `materialise.mts` writes it and the package tree to disk for the parity suite.
- The Rust vector test is the directory `crates/tagents-core/tests/plugin_vectors/` (`main.rs`, `config.rs`, `messages.rs`, `resolve.rs`), not one file (2.3).
- The scaffold's vector records are not in the fixture yet: they move to 8.1, with the characterisation test they belong to (2.2).
- `GROUPS` wraps `sessions::run` in `Some` (3.1), and `lossy_args` is a second field of `Group` that lets a group of paths refuse a call with an argument that is not UTF-8 (3.1).
- The interpolation of 4.3 follows i18next 26 and not the sentence "once, left to right, no rescan of a value": after each placeholder i18next replaces the first occurrence of its text in the whole string, so a value that holds a later placeholder takes that placeholder's value (`Texts::t`, `crates/tagents-core/src/messages.rs`; the vector `name = {{error}}`).
- `node::realpath` (JavaScript's `fs.realpathSync`, case kept as typed) replaces `fs::canonicalize` in the resolution and in `write_target` (D5, D13), because on a case-insensitive volume `canonicalize` returns the case the disk has and `plugin add Plain` would differ from node.
- A directory argument is answered in Rust under `NODE_OPTIONS` and `NODE_PRESERVE_SYMLINKS`; only the resolution of a bare name hands over on them (D5).


## 8. The scaffold source

- [x] 8.1 The characterisation test of node's `scaffoldFiles` for the triples of 2.2, written first and passing against the current TypeScript (`pnpm --filter @tagents/core test`)
- [x] 8.2 `spec/cli/scaffold/plugin.txt` (sections `@@ <path>`, placeholders `{{name}}`, `{{dir}}` and `{{core|json}}`), and `scaffold.ts` reduced to reading it and rendering it, with the characterisation test unchanged and green; `relativeSpecifier` stays as it is, its quirk included (`pnpm --filter @tagents/core test`, `pnpm --filter @tagents/core typecheck`)
- [x] 8.3 `crates/tagents-core/src/plugin/scaffold.rs`: `include_str!` of the file, the renderer with `json::quote` for the filter, `<root>/packages/core` from `node::root()` (a hand-over when it fails), the value of `{{core|json}}` made as `relativeSpecifier` makes it, from `node::relative` (the one caller of that function), the vectors of 2.2 (`cargo test -p tagents-core plugin::scaffold`, `cargo test -p tagents-core --test plugin_vectors`)

## 9. plugin new

- [x] 9.1 `plugin::new` in `plugin.rs`: the name check (exit 2), `--dir` through `node::resolve`, a target that holds anything refused with `pluginTargetExists` (exit 3), an empty or missing one accepted, the five files written in order, `pluginScaffolded`, the undo of D3 on a failed write, and a hand-over for a target that cannot be listed; not yet called by `run` (`cargo test -p tagents-core plugin::`)
- [x] 9.2 Unit tests with an injected failing writer for the undo of `plugin new`, and for the refusal of a non-empty target and the acceptance of an empty one (`cargo test -p tagents-core plugin::`)
- [x] 9.3 `new` wired into `plugin::run` and `"impl": "rust"` for `["plugin", "new"]` in `spec/cli/tagents-core.json`; `pnpm plugin:gen` and `pnpm plugin:check` show no diff, `cargo test -p tagents-core --test front_door` passes
- [x] 9.4 The parity scenarios of design D10 for `new`, including the directory that is a file and the unwritable parent, with the tree compared by path, bytes and mode (`bash tests/rust-plugin-parity.sh`, exit 0)

## 10. doctor

- [x] 10.1 `crates/tagents-core/src/doctor.rs`: `VERBS`, one `node -p` through `child::run` with a deadline, `notify::state::{state_dir, read_agent_state}`, `host::config_dir`, `node::find_on_path`, the four lines, `doctorNodeMissing` when node cannot be started or answers anything but the array, exit 0, arguments ignored; the module is not yet in `GROUPS` (`cargo test -p tagents-core doctor::`)
- [x] 10.2 Unit tests for a state directory with a valid record, a broken one and a file that is not a record, for the config present and missing, for `claude` on and off `PATH`, and for `$TAGENTS_NODE` naming a missing file, which prints `node: missing` and the other three lines (`cargo test -p tagents-core doctor::`)
- [x] 10.3 `doctor` in `GROUPS` and `"impl": "rust"` for `["doctor"]`, in the same commit as the change of the forwarded word of `crates/tagents-core/tests/front_door.rs` from `doctor` to `session list`, one constant for the whole file, and of the module comment of `front_door.rs`, which stops naming `doctor` as a forwarded word; `pnpm plugin:gen` and `pnpm plugin:check` show no diff, `--spec` lists it (`cargo test -p tagents-core --test front_door`)
- [x] 10.4 The parity scenarios of design D10 for `doctor` (`bash tests/rust-plugin-parity.sh`, exit 0)

## 11. The suite, completed

- [x] 11.1 The forward loop of `tests/rust-parity.sh` keeps `plugin`, `plugin list`, `plugin list --json`, `plugin bogus`, `plugin new`, `doctor` and `doctor --x`; they compare node with a Rust answer or with the hand-over (`bash tests/rust-parity.sh`, exit 0)
- [x] 11.2 Mutations of the Rust code each make the suite or the vectors fail: the template placeholder `{{core|json}}` unescaped, `relativeSpecifier`'s quirk fixed, the locale ignored, the state count counting a broken record, `node: missing` printed with exit 1, the undo of `plugin new` left out (one failing check each, listed in the pull request)

## 12. Documents and release

- [x] 12.1 `docs/architecture/rust-core.md`: the other two verbs and `doctor`, the template and the scaffold source, "Where the two are known to differ" (`node: missing`), the list of what is not decided (`plugin list` and the plugin host), the version lines the gate names; the sentences elsewhere in `docs/` that say node runs `plugin new` or `doctor`; `docs/` needs a breadcrumb line and a row in its directory `README.md` only for a new page, and there is none
- [x] 12.2 `CHANGELOG.md`: one line under `[Unreleased]` in "Added" saying that `tagents-core plugin new` and `doctor` run in the prebuilt Rust binary when the installer has put one on the machine, and node stays the fallback, with no `(#N)`
- [x] 12.3 The release gate: the workspace version raised one step above the merge base (`sh .github/scripts/core-release.sh gate origin/main` exits 0, `bash tests/release.sh` exits 0, `bash tests/install.sh` exits 0)
- [x] 12.4 The gates of 7.9 again, each exit 0, and `git diff --exit-code` after `pnpm plugin:gen`, `pnpm messages:gen` and `node tests/rust-plugin-vectors.mts`

## 13. Archive

- [x] 13.1 Archive the change with `/opsx:archive` as the last commit of pull request (b): `openspec/specs/rust-plugin-verbs/spec.md` is created, `core-front-door` is updated, and `pnpm spec:check` exits 0
