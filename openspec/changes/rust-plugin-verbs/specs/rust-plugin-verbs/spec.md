## ADDED Requirements

### Requirement: Four verbs are answered by the Rust binary
`tagents-core plugin add`, `plugin remove`, `plugin new` and `doctor` SHALL be answered by the Rust binary with the node CLI's texts, exit codes and file effects, in `en` and `ru`; `plugin list` and `plugin list --json` SHALL stay the node CLI's. The exit codes are the `exit` table of the data file: 2 for a missing argument or an unusable key, 1 when nothing resolves, 3 for a refusal.

#### Scenario: A served verb
- **WHEN** `tagents-core plugin remove x` runs against a config that lists `x`
- **THEN** the node CLI is not started, stdout is `removed x from <config file>` and the exit code is 0

#### Scenario: A verb that stays with node
- **WHEN** `tagents-core plugin list --json` runs
- **THEN** the node CLI receives `plugin list --json` and its output and exit code are the call's

#### Scenario: Another language
- **WHEN** `TAGENTS_LOCALE=ru` and `plugin remove x` names a key that is not listed
- **THEN** stderr is the Russian text node prints and the exit code is 3

### Requirement: The config is edited by the splice node performs
`plugin add` SHALL append `[plugins.<key>]` and `from = "<value>"` at the end of the config behind one blank line (none when the file is empty, a newline first when it lacks one), and `plugin remove` SHALL cut the section of the key with its subsections and the comment lines directly above the next header. Every other byte SHALL come back unchanged, the edit SHALL be parsed again before it is written, and it SHALL be written by a temporary file in the same directory renamed over the config.

#### Scenario: A hand-written config
- **WHEN** a plugin is added to a config with comments, a byte order mark, CRLF line ends and hand-aligned values
- **THEN** the file differs from the old one only by the appended section

#### Scenario: The last entry
- **WHEN** the only plugin that `add` appended is removed
- **THEN** the file is the text it had before the add

#### Scenario: A key that is not a bare key
- **WHEN** `plugin add ./x --name a.b` runs
- **THEN** the section header is `[plugins."a.b"]`

#### Scenario: A missing config
- **WHEN** `plugin add` runs with no config file and no config directory
- **THEN** the directory and the file are created and the file holds one section

#### Scenario: A config that is a symbolic link
- **WHEN** `config.toml` is a link to a file in another directory and `plugin add ./x` runs
- **THEN** the link is unchanged and the file it points to holds the appended section

### Requirement: What Rust cannot prove identical goes to node untouched
A config that is not valid UTF-8, exists but cannot be read, or is a symbolic link to nowhere or in a loop, one the parser refuses or with an integer beyond ±(2^53−1), a `plugins` that is no table, an edit that does not parse or a section that cannot be cut, a resolution outside the subset below, and arguments outside the grammar below SHALL go to the node CLI, with the same arguments and environment, before Rust writes. A failed write SHALL remove what Rust wrote and hand the call to node.

#### Scenario: A config with a syntax error
- **WHEN** `plugin add ./x` runs against a config that does not parse
- **THEN** the node CLI answers, with its message and exit code 1, and the file is as it was

#### Scenario: An integer beyond 2^53
- **WHEN** the config holds `big = 9007199254740993`
- **THEN** the node CLI answers and the file is as it was

#### Scenario: A config that cannot be read
- **WHEN** `config.toml` is a directory
- **THEN** the node CLI answers with the error of the read and exit code 1, and nothing is written

#### Scenario: A write that fails
- **WHEN** the config directory cannot be written
- **THEN** the node CLI words the error, and no temporary file of Rust's is left

### Requirement: The arguments are read by a grammar with no error case
An argument SHALL be a positional when it does not start with `-` (a lone `-` is one), `--` SHALL end the options, `add` SHALL take `--name V` when `V` does not start with `-` and `--name=V`, `new` SHALL take `--dir V` and `--dir=V` the same way, the last occurrence SHALL win and a second positional SHALL be ignored. Any other argument starting with `-` SHALL be handed to the node CLI, which words its own usage error.

#### Scenario: An inline value
- **WHEN** `plugin add ./x --name=demo` runs
- **THEN** the key is `demo`

#### Scenario: A value that looks like an option
- **WHEN** `plugin add ./x --name -x` or `plugin add ./x --nope` runs
- **THEN** the node CLI answers with its usage error and exit code 2

#### Scenario: After the terminator
- **WHEN** `plugin add -- ./x` runs
- **THEN** `./x` is the package

### Requirement: plugin add resolves a directory in full and a name by a walk
A directory (it starts with `.` or `~`, or is absolute) SHALL be resolved as `path.resolve` does with `~` expanded, and stored absolute. A bare npm name SHALL be resolved by Rust only when `NODE_OPTIONS` and `NODE_PRESERVE_SYMLINKS` are unset, no enclosing package of that name has `exports`, and walking up from the working directory finds `node_modules/<name>/package.json` holding JSON without `exports`; any other name, including one not found, SHALL be the node CLI's.

#### Scenario: A relative path
- **WHEN** `plugin add ./demo` runs from the parent directory
- **THEN** the entry's `from` is the absolute path of `demo`

#### Scenario: A package of an ancestor
- **WHEN** `plugin add pkg` runs from a nested directory below the one holding `node_modules/pkg`
- **THEN** the entry's `from` is `pkg` and the key comes from the manifest's `name`

#### Scenario: A package with exports
- **WHEN** the package's manifest has an `exports` field
- **THEN** the node CLI answers, as it does for a name that is found nowhere

### Requirement: Every text comes from the catalogue file
Each text the verbs print SHALL be a key of `packages/core/src/i18n/en.ts` and `ru.ts`, read by Rust from `spec/cli/messages.json`, which `pnpm messages:gen` writes from those files and `pnpm messages:check` verifies. `{{name}}` SHALL be replaced once, left to right, without rescanning a value; `TAGENTS_LOCALE` exactly `ru` selects Russian and anything else English.

#### Scenario: A stale file
- **WHEN** a text of `en.ts` changes and `spec/cli/messages.json` is not regenerated
- **THEN** `pnpm messages:check` fails

#### Scenario: A value that looks like a placeholder
- **WHEN** `plugin add` is given a directory whose path holds `{{name}}` or `$t(pluginNone)`
- **THEN** the success line prints the path as typed

### Requirement: plugin new renders one template
`plugin new <name> [--dir D]` SHALL write the files of the scaffold from `spec/cli/scaffold/plugin.txt`, the one source that node reads at run time and Rust compiles in, with the bytes node writes for the same arguments. The name SHALL be a usable key (exit 2), a target that holds anything SHALL be refused with exit 3 and left alone, and an empty target SHALL be accepted.

#### Scenario: The files
- **WHEN** `plugin new demo` runs in an empty directory
- **THEN** it holds `package.json`, `tsconfig.json`, `src/plugin.ts`, `test/plugin.test.ts` and `README.md`, equal byte for byte to node's

#### Scenario: A quote in the directory
- **WHEN** `--dir` names a directory whose path holds `"` and a backslash
- **THEN** `package.json` is valid JSON and equals what node writes

#### Scenario: A file in the way
- **WHEN** the target directory holds a file
- **THEN** the exit code is 3 and the file is intact

### Requirement: doctor asks node once and survives its absence
`doctor` SHALL ignore its arguments, print the node version and path, the agent state directory with its record count, the config file with `present` or `missing`, and the `claude` found on `PATH`, and exit 0. The version and path SHALL come from one `node -p` of the node that `$TAGENTS_NODE`, else `PATH`, names; when it cannot be started the first line SHALL be `node: missing` and the exit code 0.

#### Scenario: The four lines
- **WHEN** `doctor` runs with a state directory holding a valid record, a broken one and a file that is not a record
- **THEN** stdout is the four lines node prints, with the count node computes

#### Scenario: No node
- **WHEN** `$TAGENTS_NODE` names a file that does not exist
- **THEN** the first line is `node: missing` and the other three lines are printed

### Requirement: The verbs are pinned to node byte for byte
`tests/rust-plugin-parity.sh` SHALL run each scenario against node and against Rust on the same pristine scratch tree under `env -i` and pass it only when stdout, stderr, the exit code and every file of the tree, bytes and modes, are equal. A generated file of vectors SHALL pin each helper that exists twice, and CI SHALL regenerate it and fail on a difference.

#### Scenario: A difference
- **WHEN** a Rust helper changes one byte of what `plugin add` writes
- **THEN** the suite names the scenario and fails

#### Scenario: Stale vectors
- **WHEN** a node function the vectors cover changes and the file is not regenerated
- **THEN** CI fails on `git diff --exit-code`
