## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: What Rust cannot prove identical goes to node untouched
**Reason**: No call of a verb of the binary reaches node.
**Migration**: The binary words the problems itself: a config that cannot be read, a link to nowhere or in a loop, a directory that cannot be written and a failed write give node's line and exit 1; a document the TOML parser refuses gives node's frame with the parser's words and exit 1; arguments outside the grammar give the parser's text and exit 2.

## ADDED Requirements

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
