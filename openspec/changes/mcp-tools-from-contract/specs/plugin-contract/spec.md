## ADDED Requirements

### Requirement: A verb declares what it does
A command in a structured CLI spec MAY declare an `effect`: `read` (changes nothing), `write` (changes files, settings or the screen), `spawn` (starts a program or window that goes on by itself), `destructive` (removes or stops something that cannot be got back) or `serve` (runs until stopped, so answers no request); and MAY declare `requires: tmux`. The generator SHALL record both on the verb in `contract.json`, and the annotations the effect stands for on its tool.

#### Scenario: Recorded
- **WHEN** a verb declares `effect: destructive`
- **THEN** `contract.json` holds `"effect": "destructive"` on the verb and `destructiveHint: true` on its tool

#### Scenario: A verb that serves
- **WHEN** a verb declares `effect: serve`
- **THEN** it is in `contract.json` and in the references, and has no tool

### Requirement: A verb may be left out of the tools
A command in a structured CLI spec MAY declare `tool: false`, meaning that it is not offered as a tool. The generator SHALL record it on the verb in the `cli` section of `contract.json`, list no tool for the verb, and keep the verb in the contract and in the references, so the CLI is still documented.

#### Scenario: A verb opts out
- **WHEN** a verb declares `tool: false`
- **THEN** `contract.json` holds `"tool": false` on the verb in its `cli` section, `mcp.tagents.tools` has no tool for it, and `references/cli.md` still describes it

### Requirement: A verb may default an option for its tool
A command MAY declare `toolDefaults`, a map from the name of one of its boolean options to the value a tool call uses when the caller leaves the option out. The generator SHALL record it on the verb and give the tool's property that default, and SHALL stop, naming the tool and the option, when the map names an option the verb does not have or one that is not boolean.

#### Scenario: A default for a tool
- **WHEN** `tagents --window` declares `toolDefaults: { detach: true }`
- **THEN** `contract.json` holds the default on the verb and the tool `tagents_window` has a `detach` property whose default is true

#### Scenario: A default for an option that is not there
- **WHEN** a verb declares `toolDefaults: { attach: true }` and has no `--attach` option
- **THEN** generation stops with an error naming the tool and `--attach`

#### Scenario: A default for an option that is not a flag
- **WHEN** a verb declares a default for an option that takes a string
- **THEN** generation stops with an error saying the option takes a string

### Requirement: The tools of the tagents server come from the CLI specs
`contract.json` SHALL list under `mcp.tagents.tools` one tool for each verb of each structured CLI spec that is not `serve` and not `tool: false`, ordered by tool name. A tool SHALL be derived from its verb alone, so the generator holds no list of tools.

#### Scenario: A verb is added to a spec
- **WHEN** a command is added to a spec and `pnpm plugin:gen` runs
- **THEN** `contract.json` lists a new tool for it, the digest is different, the plugin version takes a minor step, and no file that is not generated and not the spec was edited

#### Scenario: A summary is reworded
- **WHEN** only the summary of a verb changes
- **THEN** the tool's description changes and the plugin version takes a patch step

#### Scenario: An effect changes
- **WHEN** a verb's effect changes from `read` to `write`
- **THEN** the plugin version takes a minor step

### Requirement: The structured CLI specs
The structured CLI specs are those of `tagents-core`, `tagents-knowledge` and `tagents-notify`, which the packages parse their arguments with, and `tagents.cli.json` at the repository root, which describes the non-interactive flags of the `tagents` script. A spec file that cannot be read or parsed SHALL stop generation, saying which file and why, and exit 1.

#### Scenario: A spec file that is not JSON
- **WHEN** `tagents.cli.json` is not valid JSON
- **THEN** the generator prints `cannot read the CLI spec tagents.cli.json` and the reason on stderr and exits 1

### Requirement: The script's spec is pinned to its help
Every flag that `tagents.cli.json` describes SHALL appear in the script's `--help` with the same positionals, and every flag of the help SHALL be either in `tagents.cli.json` or in the test's list of flags that are not tools, each with its reason; otherwise the contract package's tests fail. The flags that start something SHALL declare `requires: tmux`.

#### Scenario: A flag is renamed in the help
- **WHEN** the help names `--window` as `--open` and the spec is unchanged
- **THEN** the pin test fails naming `--window`

#### Scenario: A positional changes
- **WHEN** `--new` takes a third positional in the help and the spec is unchanged
- **THEN** the pin test fails naming `--new`

### Requirement: Verbs without an effect are reported, not refused
`pnpm plugin:gen` and `pnpm plugin:check` SHALL print one `notice:` line naming every verb (as `<program> <verb>`) that declares no effect, saying that each is offered as a tool that is not read-only. The notice SHALL NOT change the exit code and SHALL NOT mark the tree stale.

#### Scenario: A verb added by another change
- **WHEN** a command without an `effect` is added to a spec and `pnpm plugin:check` runs on a regenerated tree
- **THEN** the output holds a `notice:` line naming it, the exit code is 0, and its tool is not read-only

#### Scenario: Everything declared
- **WHEN** every verb declares an effect
- **THEN** no notice is printed

### Requirement: The contract file holds what generation read
`contract.json` SHALL hold the CLI contracts, the MCP tools of both servers, with their input (and output) schemas, and a hash of each API report.

#### Scenario: Both servers are in the file
- **WHEN** the contract is generated
- **THEN** `contract.json` lists the tools of the knowledge server and of the `tagents` server, and one API report hash per public package

### Requirement: The sources of the contract
The sources of the contract SHALL be files under `packages/<package>/src/`, a package's `package.json` or `tsconfig*.json`, `pnpm-lock.yaml`, `tagents`, `tagents.cli.json`, `tusage`, `tnotes`, anything under `skills/` or `.claude-plugin/`, and `contract.json`.

#### Scenario: A skill file changed
- **WHEN** a commit stages a change under `skills/`
- **THEN** the hook regenerates the contract files

## MODIFIED Requirements

### Requirement: What generation covers
The generator SHALL read four things from the code: the verbs, flags, exit codes, effects and requirements of the CLI specs (`tagents-core`, `tagents-knowledge`, `tagents-notify`, `tagents.cli.json`); the tools of the knowledge MCP server as a client lists them and the tools of the `tagents` server derived from the CLI specs; the public TypeScript API of every public package (not private, with `exports`); and the `--help` text of the `tagents`, `tusage` and `tnotes` scripts.

#### Scenario: Where the CLI and MCP parts come from
- **WHEN** the CLI contracts and MCP tools are collected
- **THEN** the CLIs are read from the command specs they parse with (and, for the script, from `tagents.cli.json`), the knowledge tools from the server's tool list without opening a database, and the `tagents` tools from the CLI contracts

#### Scenario: Reading the sources, not a build
- **WHEN** a package's built output is older than its sources
- **THEN** the generated contract still follows the sources

#### Scenario: Script help is machine independent
- **WHEN** the scripts' help is collected
- **THEN** each script runs with `--help` under a throwaway home and only the caller's `PATH`, so the text does not depend on the machine

#### Scenario: The API of every public package
- **WHEN** the API reports are produced
- **THEN** there is one per public package, named `<package>.api.md` after the package name without its scope, in the order of the package names

### Requirement: The pre-commit hook regenerates the contract
`.githooks/pre-commit` SHALL, when a commit stages a change (including a deletion) to a source of the contract, run the generator and add `contract.json`, `.claude-plugin/plugin.json` and `skills/tagents/references/*.md` to that same commit. Any other commit passes untouched.

#### Scenario: A source changed
- **WHEN** a commit stages a change under `packages/core/src/`
- **THEN** the regenerated contract files are in the same commit

#### Scenario: The script's spec changed
- **WHEN** a commit stages a change to `tagents.cli.json`
- **THEN** the regenerated contract files are in the same commit

#### Scenario: A partially staged file
- **WHEN** a source file is only partly staged
- **THEN** the generator still reads all of it from the working tree

#### Scenario: Unrelated commit
- **WHEN** a commit stages only a README
- **THEN** the hook does nothing
