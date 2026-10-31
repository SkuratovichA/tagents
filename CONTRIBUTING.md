# Contributing

Issues and pull requests are welcome. [Development](docs/development.md) is the long version of this page: where to work, how to run every test suite, how a change is specified and how the documentation is built.

## Setup

```sh
git clone https://github.com/SkuratovichA/tagents.git && cd tagents
pnpm install    # Node 22.18 or newer; also switches on the pre-commit hook
```

Run `rustup toolchain install` in the clone to install the Rust toolchain that `rust-toolchain.toml` pins. Work in a clone of your own, never in `~/.local/share/tagents` ([why](docs/development.md#work-in-a-clone-of-your-own)).

## The pre-commit hook

`.githooks/pre-commit` regenerates the Claude Code plugin contract (`contract.json`, `.claude-plugin/plugin.json` and the generated references of the skill) when a commit touches what it is generated from, and adds the result to that commit. If the hook did not run, `pnpm plugin:check` is the check that CI runs and fails on a stale contract; `pnpm plugin:gen` regenerates it by hand. [How the contract is generated](docs/architecture/contract.md).

## Tests

Run the suites of the part you changed before you open a pull request: [the TypeScript packages, the bash suites](docs/development.md#running-the-tests) and [the Rust crates](docs/development.md#the-rust-crates). CI runs `pnpm plugin:check`, `pnpm spec:check` and `claude plugin validate` (`ci.yml`), and the Rust lanes, the two parity suites, the version gate, `tests/release.sh` and `tests/install.sh` (`rust.yml`). The TypeScript tests (`pnpm test`) and the tmux suites run only on your machine.

## Releases

A pull request that changes what the `tagents-core` binary is built from raises the workspace version in `Cargo.toml`, and the `release-path` job fails it otherwise: [How a release is made](docs/architecture/rust-core.md#how-a-release-is-made).

A Dependabot pull request that changes `Cargo.lock` fails that job by construction until a maintainer raises the workspace version on its branch (`.github/scripts/core-release.sh:20`). One that changes what the contract is generated from needs `pnpm plugin:gen` run on its branch, because the pre-commit hook does not run on Dependabot's commits.

## Changes to behaviour

What tagents does is specified in `openspec/specs/`. A change that alters behaviour starts as a proposal in `openspec/changes/<id>/` and is archived into the specs when it lands; `pnpm spec:check` validates them and CI runs it. [How specs work](docs/development.md#specs).

## Commits and pull requests

Commits are conventional commits with a scope when one fits, and a short sentence in the subject that says what is true afterwards, not what was done: `fix(tusage): a moved transcript is the same file wherever Claude Code moves it`, `feat(core): tagents-core mcp, the plugin's MCP server in Rust`. The common types are `feat`, `fix`, `docs`, `test`, `refactor` and `ci`; a breaking change is marked with `!`. Pull requests are squash-merged and the title is the squashed subject with the pull request number after it, so write the title the same way.

Fill in the pull request template. Report a security problem as [SECURITY.md](SECURITY.md) says, not in a public issue.
