## MODIFIED Requirements

### Requirement: When the node CLI cannot be run
When a word has to go to the node CLI and `packages/core/dist/cli/main.js` does not exist in the checkout, the Rust binary SHALL print one line on stderr, `tagents-core: cannot find <relative path>: <why>; this binary has to stay in <root>/target/<profile>/ of a root where it is built`, which names the path it looked at, and exit 2. When the node program cannot be started, it SHALL print one line naming it and exit 127 if no such program exists and 126 if it exists and cannot be run.

#### Scenario: Not built
- **WHEN** a word that is not served runs from a checkout with no `packages/core/dist/cli/main.js`
- **THEN** one line on stderr names the path looked at and `<root>/target/<profile>/`, and the exit code is 2

#### Scenario: No node
- **WHEN** a word that is not served runs and `$TAGENTS_NODE` names a file that does not exist
- **THEN** one line on stderr names it and the exit code is 127

#### Scenario: A node that cannot run
- **WHEN** `$TAGENTS_NODE` names a file that exists and is not executable
- **THEN** one line on stderr names it and the exit code is 126
