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
| `tests/config.sh` | the config parser, the rules and the command builder, with no tmux involved |
| `tests/launch.sh` | starting and resuming real agents |
| `tests/window-rows.sh` | selecting, joining and killing rows across windows and sessions, and the list's cursor following the viewport |
| `tests/ui.sh` | what the row looks like: the badge column, the hidden ones, the `?` window running a real key, the one-line header, the `ctrl-v` modal, and the order, which is checked by making a state change and asserting that nothing moved |
| `tests/names.sh` | the window naming, including the refusal to overwrite a name you typed |
| `tests/headless.sh` | the sessions with no pane: what the hook writes for one, how the row reads while its process lives and once it does not, and that every verb needing a pane refuses |
| `tests/modules.sh` | the layout itself: every module is sourced and none is orphaned, nothing is defined twice, a module only defines things, and the entry point still finds its modules through a symlink and refuses to run without them |
| `tests/forks.sh` | what one repaint costs in processes: the number of programs `--list` starts does not grow with the records in the state directory, `--counts` reads its config once and reuses its output for five seconds (`TA_COUNTS_EVERY=0` turns that off), and a record that cannot be read does not take the ones after it down. The status bar and the refresher run these hundreds of times a minute, and the endpoint security agent inspects every process they start |
| `tests/refresh.sh` | the real refresher loop with shims for its network: what a wake posts and which programs it starts |
| `tests/events.sh` | the hook's event stream and what the hook starts |

The other suites in `tests/` are named after the part they cover.

## Specs

What tagents does is written down in [OpenSpec](https://github.com/Fission-AI/OpenSpec) specs under `openspec/specs/`, one capability per spec: the list, the keys, docking, the refresher, the agent-state hook, notes, usage, resurrect, configuration, the headless sessions, the plugin system and each package.

- They describe behaviour someone can observe: keys, verbs, flags, exit codes, config keys, and the files and tmux options other parts read. They do not describe how the code gets there.
- They replace the dated changelog this repository used to keep. The history stays in git.

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
pnpm docs:dev       # a live preview
pnpm docs:build     # the build CI publishes; it fails on a dead link
```

Pushes to `main` that touch `docs/` publish the site to GitHub Pages.
