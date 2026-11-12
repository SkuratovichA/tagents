## MODIFIED Requirements

### Requirement: What generation covers
The generator SHALL read four things from the code: the verbs, flags, exit codes, effects and requirements of the CLI specs (`tagents-core`, `okb`, `tagents-notify`, `tagents.cli.json`); the tools of the knowledge MCP server as a client lists them and the tools of the `tagents` server derived from the CLI specs; the public TypeScript API of every public package (not private, with `exports`; the knowledge package is gone); and the `--help` text of the `tagents`, `tusage` and `tnotes` scripts.

#### Scenario: Where the CLI and MCP parts come from
- **WHEN** the CLI contracts and MCP tools are collected
- **THEN** the `tagents-core` and `okb` CLIs are read from `spec/cli/tagents-core.json` and `spec/cli/okb.json`, the other CLIs from the command specs they parse with (and, for the script, from `tagents.cli.json`), the knowledge tools from the server's tool list without opening a database, and the `tagents` tools from the CLI contracts

#### Scenario: Reading the sources, not a build
- **WHEN** a package's built output is older than its sources
- **THEN** the generated contract still follows the sources

#### Scenario: Script help is machine independent
- **WHEN** the scripts' help is collected
- **THEN** each script runs with `--help` under a throwaway home and only the caller's `PATH`, so the text does not depend on the machine

#### Scenario: The API of every public package
- **WHEN** the API reports are produced
- **THEN** there is one per public package, named `<package>.api.md` after the package name without its scope, in the order of the package names

### Requirement: The plugin version follows what the plugin ships
`.claude-plugin/plugin.json` SHALL carry a `version` and a `metadata.digest`, both maintained by the generator. The digest SHALL be a `sha256:` hash over the paths and contents of the payload: the generated files, every file under `skills/` outside `references/`, the launcher `bin/knowledge-mcp`, `.claude-plugin/marketplace.json` when present, and `plugin.json` without its `version` and `digest`. The version SHALL move only when the digest moved.

#### Scenario: The first run
- **WHEN** `plugin.json` has no stored digest
- **THEN** the digest is stored, the version stays as it was and the output says the first digest was stored

#### Scenario: Nothing changed
- **WHEN** the stored digest equals the new one
- **THEN** `plugin.json` is not rewritten, even if its formatting differs

#### Scenario: Only the version and digest differ
- **WHEN** nothing but `version` and `metadata.digest` of `plugin.json` changed
- **THEN** the digest does not move

#### Scenario: The knowledge launcher changes
- **WHEN** only `bin/knowledge-mcp` changed
- **THEN** the digest moves, the version takes a patch step, and the pre-commit hook regenerates the contract for a commit that stages that file

### Requirement: The structured CLI specs
The structured CLI specs are those of `tagents-core` and `okb`, which `spec/cli/tagents-core.json` and `spec/cli/okb.json` hold and the binaries print with `--spec`, and of `tagents-notify`, which the package parses its arguments with, and `tagents.cli.json` at the repository root, which describes the non-interactive flags of the `tagents` script. A spec file that cannot be read or parsed SHALL stop generation, saying which file and why, and exit 1.

#### Scenario: A spec file that is not JSON
- **WHEN** `tagents.cli.json` is not valid JSON
- **THEN** the generator prints `cannot read the CLI spec tagents.cli.json` and the reason on stderr and exits 1

## ADDED Requirements

### Requirement: The okb description is a checked file
`spec/cli/okb.json` SHALL hold the verbs, flags, exit codes and effects of `okb`, and its user-visible texts SHALL be held by a JSON file the binary embeds. A check SHALL fail when the output of `okb --spec` differs from the file, and the generator SHALL read the file, not a package. The API report of the knowledge package SHALL be gone, with the package.

#### Scenario: The file and the binary drift
- **WHEN** a flag is added to the binary and not to `spec/cli/okb.json`
- **THEN** the check fails naming the file (`pnpm -r test`)

### Requirement: The generator knows two plugins
In the second pull request the generator SHALL keep, for each of `tagents` and `okb`, its manifest, generated files, shipped files, digest and version, and `pnpm plugin:check` SHALL fail when either is stale. `contract.json` SHALL list the tools of the `okb` plugin's server `knowledge` and of the `tagents` server separately.

#### Scenario: Only okb's launcher changes
- **WHEN** only `plugins/okb/bin/okb-mcp` changes
- **THEN** the digest and version of `okb` move and those of `tagents` do not (`pnpm -r test`)
