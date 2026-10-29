## MODIFIED Requirements

### Requirement: What generation covers
The generator SHALL read four things from the code: the verbs, flags and exit codes of the `tagents-core` and `tagents-knowledge` CLIs; the tools of the knowledge MCP server with their input (and output) schemas, as a client lists them; the public TypeScript API of every public package (not private, with `exports`); and the `--help` text of the `tagents`, `tusage` and `tnotes` scripts. `contract.json` SHALL hold the CLI contracts, the MCP tools and a hash of each API report.

#### Scenario: Where the CLI and MCP parts come from
- **WHEN** the CLI contracts and MCP tools are collected
- **THEN** the `tagents-core` CLI is read as the requirement below says, the `tagents-knowledge` CLI from the command spec it parses with, and the tools from the server's tool list without opening a database

#### Scenario: Reading the sources, not a build
- **WHEN** a package's built output is older than its sources
- **THEN** the generated contract still follows the sources

#### Scenario: Script help is machine independent
- **WHEN** the scripts' help is collected
- **THEN** each script runs with `--help` under a throwaway home and only the caller's `PATH`, so the text does not depend on the machine

#### Scenario: The API of every public package
- **WHEN** the API reports are produced
- **THEN** there is one per public package, named `<package>.api.md` after the package name without its scope, in the order of the package names

## ADDED Requirements

### Requirement: The tagents-core verbs come from the CLI spec file
The verbs of `tagents-core` SHALL be read from `spec/cli/tagents-core.json`, whichever implementation serves them, so that moving a verb to Rust changes no byte of the contract.

#### Scenario: A verb changes implementation
- **WHEN** the `impl` of a command in `spec/cli/tagents-core.json` changes from `node` to `rust` and `pnpm plugin:gen` runs
- **THEN** no generated file differs
