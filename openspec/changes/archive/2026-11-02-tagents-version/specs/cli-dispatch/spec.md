## ADDED Requirements

### Requirement: --version prints the version and the commit
`tagents --version` and `tagents -V` SHALL print one line, `tagents <workspace version> (<short commit>)`, read from the checkout the script file lives in (symlinks followed), and exit 0. A version that cannot be read SHALL print as `unknown` and a commit that cannot be read SHALL be left out. No module is loaded, so an incomplete copy answers.

#### Scenario: The normal line
- **WHEN** `tagents --version` or `tagents -V` runs in a checkout whose `Cargo.toml` says 0.6.2 and whose HEAD is ddc1ae1
- **THEN** it prints `tagents 0.6.2 (ddc1ae1)` and exits 0, and no tmux server is started

#### Scenario: No readable version
- **WHEN** the checkout's `Cargo.toml` holds no workspace version
- **THEN** it prints `tagents unknown (ddc1ae1)` and exits 0

#### Scenario: No readable commit
- **WHEN** the checkout is not a git repository
- **THEN** it prints `tagents 0.6.2` and exits 0, and with neither part readable it prints `tagents unknown`

#### Scenario: Through a symlink
- **WHEN** `tagents` is a symlink to the script in a checkout
- **THEN** the line describes that checkout
