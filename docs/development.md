# Development

This page is for working on tagents itself: where to do the work, how to run the test suites, and how a change to behaviour is specified and recorded.

## Work in a clone of your own

The managed copy in `~/.local/share/tagents` stays on `main` and is never developed in; it refuses to move when it has local changes. Clone tagents somewhere else (`~/git/.../tagents`) and run everything from there.

```sh
git clone https://github.com/SkuratovichA/tagents.git ~/git/tagents
cd ~/git/tagents
pnpm install
```

`pnpm install` also switches on `.githooks/pre-commit` for the clone, unless it already has a `core.hooksPath` of its own; the hook keeps the [generated contract](./architecture/contract) current.

`tagents` is the entry point of a checkout, not a file to copy on its own: the rest is `lib/tagents/*.sh` beside it. [What each part is](https://github.com/SkuratovichA/tagents/blob/main/lib/tagents/README.md).

## Running the tests

### The TypeScript packages

```sh
pnpm test         # every package's tests, and the plugin contract is checked not to be stale
pnpm typecheck
pnpm build
```

### The Rust crates

`rust-toolchain.toml` pins the toolchain, with `clippy` and `rustfmt`; `rustup toolchain install` in the clone installs it, as `rust.yml` does. These are the commands the `rust` job of `.github/workflows/rust.yml` runs, on Linux and macOS:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
bash tests/rust-parity.sh        # the Rust sessions verbs against the node CLI
bash tests/rust-mcp-parity.sh    # the Rust MCP server against the node one
node tests/rust-notify-vectors.mts && git diff --exit-code crates/tagents-core/tests/fixtures/notify-vectors.json   # the node rules the daemon copies
bash tests/rust-notify-parity.sh # the Rust notify daemon against the node one
```

What the parity suites compare is in [The parity suite](./architecture/rust-core#the-parity-suite). They need a built `packages/core`, `packages/mcp` and `packages/notify` (`pnpm build`) and build the debug binary themselves when it is missing. A pull request that changes what the `tagents-core` binary is built from also raises the workspace version in `Cargo.toml`: [How a release is made](./architecture/rust-core#how-a-release-is-made) says which files count and how to run the check, `sh .github/scripts/core-release.sh gate origin/main`.

### The bash suites

Every shell suite under `tests/` runs on a scratch tmux server, one at a time:

```sh
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh
```

Each suite runs against a throwaway tmux server of its own (`tmux -L tatest-$$`), never the default socket, and refuses to start unless it is run with a default socket of its own too, so that no stray `tmux` call reaches the server you are working in. `tests/scratch-guard.sh` enforces that. All of them are bash 3.2, run every check, and exit non-zero when any of them fails.

::: warning Do not touch the tree while a suite runs
The tests read `tagents`, `tnotes` and `tusage` from the checkout as they run. A `git stash` or checkout issued while suites run in the background makes half of them exercise one tree and half another, and every suite can still say "passed". Use a scratch worktree for probes.
:::

### What the suites cover

| suite | covers |
|-------|--------|
| `tests/config.sh` | the config reader on the shipped example and the overlays, the rules, the command builder and the checker, with no tmux involved |
| `tests/config-toml.sh` | the TOML reader, which file is read, the per-machine overlay and what `--check` and the status bar say about it, with no tmux involved |
| `tests/launch.sh` | starting and resuming real agents |
| `tests/window-rows.sh` | selecting, joining and killing rows across windows and sessions, and the list's cursor following the viewport |
| `tests/ui.sh` | what the row looks like: the badge column, the hidden ones, the `?` window running a real key, the one-line header, the `ctrl-v` modal, and the order, which is checked by making a state change and asserting that nothing moved |
| `tests/names.sh` | the window naming, including the refusal to overwrite a name you typed |
| `tests/headless.sh` | the sessions with no pane: what the hook writes for one, how the row reads while its process lives and once it does not, and that every verb needing a pane refuses |
| `tests/modules.sh` | the layout itself: every module is sourced and none is orphaned, nothing is defined twice, a module only defines things, and the entry point still finds its modules through a symlink and refuses to run without them |
| `tests/forks.sh` | what one repaint costs in processes: the number of programs `--list` starts does not grow with the records in the state directory, `--counts` reads its config once and reuses its output for five seconds (`TA_COUNTS_EVERY=0` turns that off), and a record that cannot be read does not take the ones after it down. The status bar and the refresher run these hundreds of times a minute, and the endpoint security agent inspects every process they start |
| `tests/refresh.sh` | the real refresher loop with shims for its network: what a wake posts and which programs it starts |
| `tests/rust-parity.sh` | the Rust `tagents-core` against the node CLI on one seeded home: the same stdout, stderr and exit code for every `sessions` case, including the awkward transcripts, and one installer case that packages the debug binary, serves it as a `file://` release in a sandbox and checks that the installer accepts its `--version` line; needs `python3` and a built `packages/core`, and builds the debug binary when it is missing (after a Rust edit or a version bump run `cargo build` first, the suite does not rebuild a binary that exists, and a binary whose version is not the workspace version fails the installer case with a warning that says `for --version`) |
| `tests/rust-mcp-parity.sh` | the Rust MCP server (`tagents-core mcp`) against the node one (`packages/mcp`): the same requests on stdin, with stub programs on `PATH`, and the answers compared byte for byte (the handshake, the tool list of a fixture contract and of the bundled one, every way a call ends, cancellation, and stdin closed with a call in flight); needs a built `packages/mcp`, and builds the debug binary when it is missing; CI runs it in the `rust` job |
| `tests/release.sh` | the release path of the Rust `tagents-core` without GitHub or a network: the workspace version read out of many shapes of `Cargo.toml` and compared with the second copy of the reader in `install.sh`, the release archive and its checksum (two members, modes, accepted by `sha256sum -c` and `shasum -a 256 -c`), the gate that fails a change to an input of the binary unless the workspace version is strictly above the merge base's (a message for a version that stayed and one for a version that went down), the pins between the paths and targets of `release.yml`, `rust.yml` and `install.sh`, and the tag rules |
| `tests/events.sh` | the hook's event stream and what the hook starts |
| `tests/setup.sh` | `tagents setup` on a scratch `HOME`, with no tmux involved: the registration is appended to a `settings.json` and nothing of the user's is lost (other hooks and matchers, every other key and its order), the forms a registered hook takes in a real file, what is refused and left byte for byte (invalid JSON, a top level or a `hooks` of the wrong type, a dangling link), links followed and kept, one file handled once however many config dirs lead to it, profiles, which hooks directory the commands name and how its path is quoted, `--check` writing nothing, modes, backups and a file that changes while it is written; it refuses to start when `HOME` is still the real home |

The other suites in `tests/` are named after the part they cover.

## Specs

What tagents does is written down in [OpenSpec](https://github.com/Fission-AI/OpenSpec) specs under `openspec/specs/`, one capability per spec: the list, the keys, docking, the refresher, the agent-state hook, notes, usage, resurrect, configuration, the headless sessions, the plugin system and each package.

- They describe behaviour someone can observe: keys, verbs, flags, exit codes, config keys, and the files and tmux options other parts read. They do not describe how the code gets there.
- There is no dated log of work: the history stays in git, and [`CHANGELOG.md`](https://github.com/SkuratovichA/tagents/blob/main/CHANGELOG.md) lists what each release of `tagents-core` contains and what `main` holds beyond the last one.

A change starts as a proposal under `openspec/changes/<name>/`: why, what changes, the tasks, and the spec deltas it makes. It is archived into the specs once it has landed. In a Claude Code session in this repository the `/opsx:propose`, `/opsx:apply` and `/opsx:archive` commands drive that. From a shell, the CLI is a pinned dev dependency:

```sh
pnpm exec openspec list --specs        # the capabilities
pnpm exec openspec show refresher      # one of them
pnpm spec:check                        # every spec and change validates (CI runs this too)
```

`LEARNING.md` stays: it records mistakes and how they were fixed, which a spec does not.

## Working on this documentation

The site is [VitePress](https://vitepress.dev) in `docs/`, run through `pnpm dlx`, so the docs toolchain is not a dependency of the repository (and never rides along with the managed copy's `pnpm install`).

```sh
pnpm docs:dev       # a live preview, served under /docs/ like the published site
pnpm docs:build     # the build CI publishes; it fails on a dead link
```

The documentation is published under `/docs/` of [tagents.arstoien.com](https://tagents.arstoien.com/), next to the one-page site of `site/` at `/`. The workflow `.github/workflows/site.yml` builds and checks both on every pull request that touches `docs/`, `site/` or one of the other files the workflow lists under `paths`, and a push to `main` deploys them as one GitHub Pages site, because a repository has one Pages artifact. The `base` of VitePress is `/docs/` for that reason (`docs/.vitepress/config.mjs`), and the site's link check requires `docs/index.html` in the assembled output without reading the pages of the documentation.

The address is a CNAME record `tagents` for `arstoien.com` pointing at `skuratovicha.github.io`, and `tagents.arstoien.com` as the custom domain in the repository's Pages settings, with HTTPS enforced once GitHub has issued the certificate. The order matters: the CNAME record comes first and the Pages setting after it, then HTTPS, and all of it after a deployment built for the domain has succeeded, because from then on `skuratovicha.github.io/tagents/` redirects to the domain, and a site that is not there yet would break.
