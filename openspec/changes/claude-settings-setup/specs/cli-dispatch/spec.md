## MODIFIED Requirements

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
