# rust-plugin-verbs Specification

## Purpose
The plugin verbs and `doctor` as verbs of the Rust binary: `tagents-core plugin add`, `plugin remove`, `plugin new` and `doctor` print the same texts, exit with the same codes and leave the same files as the node CLI in `packages/core`, which stays as the fallback and as the reference that the differential suite compares it with byte for byte; how the config is edited, how a package is found, where the texts come from, what is handed to node untouched, and what `doctor` does without node.

## Requirements

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

### Requirement: The arguments are read by a grammar with no error case
An argument SHALL be a positional when it does not start with `-` (a lone `-` is one), `--` SHALL end the options, `add` SHALL take `--name V` when `V` does not start with `-` and `--name=V`, `new` SHALL take `--dir V` and `--dir=V` the same way, the last occurrence SHALL win and a second positional SHALL be ignored. Any other argument starting with `-` SHALL print the node parser's error text on stderr and exit 2.

#### Scenario: An inline value
- **WHEN** `plugin add ./x --name=demo` runs
- **THEN** the key is `demo`

#### Scenario: A value that looks like an option
- **WHEN** `plugin add ./x --name -x` or `plugin add ./x --nope` runs
- **THEN** stderr is the text node's parser gives for it, the exit code is 2 and the node CLI is not started

#### Scenario: After the terminator
- **WHEN** `plugin add -- ./x` runs
- **THEN** `./x` is the package

### Requirement: plugin add resolves a directory in full and a name by a walk
A directory (it starts with `.` or `~`, or is absolute) SHALL be resolved as `path.resolve` does with `~` expanded, and stored absolute. A bare npm name SHALL be resolved as `require.resolve('<name>/package.json')` is, from the working directory and then the global folder, with `exports` honoured; a name found nowhere SHALL give node's line and exit 1. A `--require` hook is not run.

#### Scenario: A relative path
- **WHEN** `plugin add ./demo` runs from the parent directory
- **THEN** the entry's `from` is the absolute path of `demo`

#### Scenario: A package of an ancestor
- **WHEN** `plugin add pkg` runs from a nested directory below the one holding `node_modules/pkg`
- **THEN** the entry's `from` is `pkg` and the key comes from the manifest's `name`

#### Scenario: A package with exports
- **WHEN** the package's manifest has an `exports` field
- **THEN** the binary resolves the name against it as node does, or, for a name found nowhere, prints node's line and exits 1, and the node CLI is not started

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
`doctor` SHALL ignore its arguments, print the node version and path, the agent state directory with its record count, the config file with `present` or `missing`, and the `claude` found on `PATH`, and exit 0. The version and path SHALL come from one `node -p` of the node that `$TAGENTS_NODE`, else `PATH`, names, answered within 10 seconds with an array of exactly two strings; otherwise the first line SHALL be `node: missing`, the other three lines SHALL be printed and the exit code SHALL be 0.

#### Scenario: The four lines
- **WHEN** `doctor` runs with a state directory holding a valid record, a broken one and a file that is not a record
- **THEN** stdout is the four lines node prints, with the count node computes

#### Scenario: No node
- **WHEN** `$TAGENTS_NODE` names a file that does not exist
- **THEN** the first line is `node: missing` and the other three lines are printed

#### Scenario: A node that answers wrongly or too slowly
- **WHEN** `$TAGENTS_NODE` names a program that exits 1, prints an array of three strings, or does not answer within 10 seconds
- **THEN** the first line is `node: missing`, the other three lines are printed and the exit code is 0

### Requirement: A signal during doctor's question stops node
A SIGTERM, SIGINT or SIGHUP that comes while `doctor` waits for node SHALL stop that node and everything it started before `doctor` ends. `doctor` SHALL then print nothing and exit with 128 plus the number of the signal (143, 130 or 129).

#### Scenario: SIGTERM while node is asked
- **WHEN** `$TAGENTS_NODE` names a program that sleeps and SIGTERM is sent to `doctor`
- **THEN** `doctor` exits 143 within 5 seconds, prints nothing, and the program is no longer running

### Requirement: The verbs are pinned to node byte for byte
`tests/rust-plugin-parity.sh` SHALL run each scenario against node and against Rust on the same pristine scratch tree under `env -i` and pass it only when stdout, stderr, the exit code and every file of the tree, bytes and modes, are equal. A generated file of vectors SHALL pin each helper that exists twice, and CI SHALL regenerate it and fail on a difference.

#### Scenario: A difference
- **WHEN** a Rust helper changes one byte of what `plugin add` writes
- **THEN** the suite names the scenario and fails

#### Scenario: Stale vectors
- **WHEN** a node function the vectors cover changes and the file is not regenerated
- **THEN** CI fails on `git diff --exit-code`

### Requirement: The config problems are worded in node's frame
A config that cannot be read, is a link to nowhere or in a loop, or sits in a directory that cannot be written SHALL give the system's line as node words it and exit 1. A document the parser refuses or an edit that does not parse SHALL give `<file>: <reason>` with the Rust parser's words and exit 1, the file as it was. A failed write SHALL remove what the binary wrote and give the line of the error.

#### Scenario: A config with a syntax error
- **WHEN** `plugin add ./x` runs against a config that does not parse
- **THEN** stderr begins with the config's path and a colon, the exit code is 1 and the file is as it was

#### Scenario: A config that cannot be read
- **WHEN** `config.toml` is a directory
- **THEN** stderr is the line of the read as node words it, the exit code is 1 and nothing is written

#### Scenario: A write that fails
- **WHEN** the config directory cannot be written
- **THEN** stderr is the line of the error as node words it, the exit code is 1 and no temporary file is left
