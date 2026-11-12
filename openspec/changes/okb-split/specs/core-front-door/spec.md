## ADDED Requirements

### Requirement: tagents-core knowledge is okb's
`tagents-core knowledge <arguments>` SHALL replace itself with `okb <arguments>` when an executable `okb` is found next to the `tagents-core` binary or on `PATH`, with the same environment, standard streams and working directory, so the exit code is okb's. Otherwise it SHALL print one line on standard error that names `okb` and `tagents update`, nothing on standard output, and exit 69. No word after `knowledge` SHALL reach the node CLI, and `tagents-core --spec` SHALL list no `knowledge` verb.

#### Scenario: okb is installed
- **WHEN** `tagents-core knowledge search x` runs and `okb` is on `PATH`
- **THEN** `okb` runs with the arguments `search` and `x`, and the exit code is its own (`cargo test --workspace --locked`)

#### Scenario: okb is not installed
- **WHEN** `tagents-core knowledge search x` runs and no `okb` is found
- **THEN** one line names `okb` and `tagents update`, standard output is empty and the exit code is 69 (`cargo test --workspace --locked`)

#### Scenario: The table of verbs
- **WHEN** `tagents-core --spec` runs
- **THEN** no `knowledge` verb is listed and the generated tool list of the plugin gains none (`pnpm plugin:check`)
