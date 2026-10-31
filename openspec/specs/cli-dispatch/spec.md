# cli-dispatch Specification

## Purpose
The `tagents` script is the one name that reaches all of tagents: it answers its own `--flag` vocabulary itself and hands every other verb to `tagents-core` unchanged. This capability covers what the script's top level handles, how it finds `tagents-core`, what an unknown option does, and the rules for loading its modules that a user can observe.

## Requirements

### Requirement: No argument opens the dashboard
Running `tagents` with no argument SHALL start the interactive dashboard, after loading the configuration. What the dashboard shows and does is the business of the `dashboard-list` and `dashboard-keys` capabilities.

#### Scenario: Bare invocation
- **WHEN** `tagents` runs with no arguments
- **THEN** the dashboard starts and nothing is forwarded to `tagents-core`

### Requirement: The dashboard's own flags are answered by the script
Every option that starts with `-` and that the dashboard knows SHALL be answered by the `tagents` script itself and SHALL NEVER be forwarded to `tagents-core`, so a typo in one of them cannot start another process. These flags are matched before any verb is considered, so forwarding can shadow none of them. What each flag does is recorded by the capability that owns it.

#### Scenario: The flags the script answers
- **WHEN** one of `-h`, `--help`, `--list`, `--flat`, `--toggle-group`, `--timeline`, `--label`, `--ask-rename`, `--ask-send`, `--ask-kill`, `--ask-profile`, `--ask-columns`, `--col-rows`, `--toggle-col`, `--hidden-cols`, `--ask-keys`, `--ask-usage`, `--closed-rows`, `--closed-preview`, `--ask-closed`, `--resurrect-save`, `--resurrect-rows`, `--resurrect`, `--keys`, `--header`, `--act` is given
- **THEN** the script handles it itself

#### Scenario: The rest of the flags
- **WHEN** one of `--new`, `--window`, `--profile-for`, `--config`, `--check`, `--agent-cmd`, `--counts`, `--preview`, `--ask-preview`, `--preview-popup`, `--follow`, `--sync-names`, `--refresher`, `--ensure-dash`, `--goto`, `--viewport` is given
- **THEN** the script handles it itself

#### Scenario: Removed flags
- **WHEN** one of `--focus-hooks`, `--slot`, `--unpark`, `--poke`, `--undock-pane`, `--undock-window`, `--collapse`, `--seats`, `--current-seat` or `--ensure-seat` is given
- **THEN** the script does not treat it as a flag of its own

#### Scenario: Answered here
- **WHEN** `tagents --keys`, `--hidden-cols`, `--config`, `--check`, `--header` or `--help` runs while a `tagents-core` is available
- **THEN** the script answers it and `tagents-core` is not started

### Requirement: --help prints the manual
`tagents -h` and `tagents --help` SHALL print the manual kept as the comment block at the top of the script, up to the first line that is not a comment, with the comment markers removed, and SHALL load no module to do so, so that even an incomplete copy of the script can answer it.

#### Scenario: Help from a lone copy
- **WHEN** the script is copied alone, without `lib/tagents/`, and run with `--help`
- **THEN** the manual is printed and the exit code is 0

### Requirement: An unknown option is an error here
An argument starting with `-` that the dashboard does not know SHALL print `tagents: unknown option <argument>` on stderr and exit 2, and SHALL NOT be forwarded to `tagents-core`.

#### Scenario: A typo
- **WHEN** `tagents --nope` runs
- **THEN** stderr has `tagents: unknown option --nope`, the exit code is 2 and `tagents-core` was not started

### Requirement: Any other verb goes to tagents-core unchanged
A first argument that does not start with `-`, other than `update` and `setup`, which the script answers itself, SHALL be handed to `tagents-core` with the whole argument list exactly as given, each argument still one argument, by replacing the script's process, so that the verb's exit code is the exit code of `tagents`. `tagents session list` and `tagents-core session list` are the same call, and an unknown verb is refused by `tagents-core`, not by the script.

#### Scenario: Arguments survive
- **WHEN** `tagents session prompt ref "two words"` runs
- **THEN** `tagents-core` receives four arguments, `session`, `prompt`, `ref` and `two words`

#### Scenario: A refusal is not swallowed
- **WHEN** `tagents-core` exits 3 for `plugin add ./x`
- **THEN** `tagents` exits 3 as well

#### Scenario: An unknown verb
- **WHEN** `tagents nonsense` runs
- **THEN** `tagents-core` is handed `nonsense` and its exit code (2 for an unknown verb) is the result

#### Scenario: The verbs the script answers
- **WHEN** `tagents setup --check` or `tagents update --check` runs
- **THEN** the script answers it and `tagents-core` is not started

### Requirement: Where tagents-core is looked for
The script SHALL use the `tagents-core` found on `PATH` first, because that is the installed one and the one the user chose. Failing that, in a repository checkout it SHALL use the Rust binary `target/release/tagents-core` beside the script when that is an executable file, and failing that the built `packages/core/dist/cli/main.js` beside it, executed directly when it is executable and through `node` when it is only readable and `node` is on `PATH`.

#### Scenario: A checkout with nothing on PATH
- **WHEN** a built core sits beside the script and no `tagents-core` is on `PATH`
- **THEN** the verb is handed to the built file with its exit code passed through

#### Scenario: Installed beats checkout
- **WHEN** both exist
- **THEN** the one on `PATH` is used

#### Scenario: A Rust binary that is not executable
- **WHEN** `target/release/tagents-core` exists without the executable bit and a built core sits beside the script
- **THEN** the verb is handed to the built core

#### Scenario: A directory where the Rust binary would be
- **WHEN** `target/release/tagents-core` is a directory and a built core sits beside the script
- **THEN** the verb is handed to the built core

#### Scenario: No Rust binary
- **WHEN** there is no `target/release/tagents-core` beside the script
- **THEN** the verb is handled exactly as it was before the Rust binary existed

### Requirement: Without tagents-core the verb says where it went
When there is no `tagents-core` on `PATH`, no executable Rust binary and no built file beside the script, a forwarded verb SHALL print one line on stderr, `tagents: no tagents-core on PATH and none at <path to packages/core/dist/cli/main.js>, so "<verb>" goes nowhere`, and exit 2, the code of a usage error.

#### Scenario: Nothing to forward to
- **WHEN** `tagents session list` runs with neither a `tagents-core` on `PATH`, nor a Rust binary, nor a built core
- **THEN** exactly one line is printed, naming the verb, saying there is no `tagents-core` on `PATH` and naming the built path, and the exit code is 2

### Requirement: The script finds its modules beside the real file
Apart from `-h` and `--help`, every invocation SHALL load the modules in `lib/tagents/` that lie beside the real file of the script, following a chain of symbolic links, so that an installed `~/.local/bin/tagents` pointing into a checkout finds them. They are loaded before the first argument is looked at.

#### Scenario: Through a link
- **WHEN** the script is run through a symlink, or a symlink to a symlink
- **THEN** it finds its modules and runs normally

### Requirement: A lone copy refuses to run
When a module is missing or unreadable, the script SHALL print `tagents: cannot load <module path>` and `tagents: this is the entry point of a checkout, not a file to copy alone` on stderr and exit 1, rather than run half a program.

#### Scenario: Copied on its own
- **WHEN** the script file is copied somewhere without `lib/tagents/` and run with `--config`
- **THEN** the exit code is 1 and the output says what is missing and that this is the entry point of a checkout

### Requirement: The module layout stays consistent
The list of modules the script loads and the files in `lib/tagents/` SHALL name the same modules, and no function SHALL be defined in two modules. Sourcing all modules SHALL print nothing and run nothing, because they are read on every invocation, including those of the tmux status line, and anything they printed would corrupt parsed output such as `--list`. Every function the top-level dispatch calls SHALL be defined.

#### Scenario: List and directory agree
- **WHEN** the modules named in the script are compared with `lib/tagents/*.sh`
- **THEN** they are the same set

#### Scenario: Sourcing is silent
- **WHEN** every module is sourced in a clean environment
- **THEN** nothing is printed and the program's functions are defined

#### Scenario: No duplicates
- **WHEN** the function definitions of all modules are compared
- **THEN** none is defined twice

#### Scenario: Every dispatched function exists
- **WHEN** each function the dispatch calls is looked up
- **THEN** it is defined in a module, in the script or on `PATH`

### Requirement: The previous version's tmux verbs are answered quietly
`--poke` and `--unpark`, which the previous version's focus hooks call, and `--undock-pane` and `--undock-window`, which the kill bindings its README handed out call, SHALL exit 0, print nothing, change nothing and SHALL NOT be forwarded to `tagents-core`. An update lands under a running list, and those hooks stay in tmux until the first start of the new version removes them (see the `window-rows` capability).

#### Scenario: A focus hook of the previous version
- **WHEN** `tagents --poke %67` runs
- **THEN** the exit code is 0, nothing is printed and `tagents-core` was not started

### Requirement: A Rust binary beside the script gets the verb whole
The Rust binary serves the verbs ported to Rust and hands every other word to the node CLI, so the script SHALL pass it the whole argument list and return its exit code. A Rust binary that is present and cannot be run SHALL be an error of its own, never a reason to try the next lookup.

#### Scenario: A Rust binary beside the script
- **WHEN** an executable `target/release/tagents-core` and a built core sit beside the script and no `tagents-core` is on `PATH`
- **THEN** the verb is handed to the Rust binary with the whole argument list and its exit code is passed through

#### Scenario: A Rust binary that cannot run
- **WHEN** an executable file `target/release/tagents-core` whose interpreter is missing sits beside the script and no `tagents-core` is on `PATH`
- **THEN** the command fails with a non-zero exit code and a message on stderr, and the node CLI is not run
