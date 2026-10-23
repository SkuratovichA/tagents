## ADDED Requirements

### Requirement: The previous version's tmux verbs are answered quietly
`--poke` and `--unpark`, which the previous version's focus hooks call, and `--undock-pane` and `--undock-window`, which the kill bindings its README handed out call, SHALL exit 0, print nothing, change nothing and SHALL NOT be forwarded to `tagents-core`. An update lands under a running list, and those hooks stay in tmux until the first start of the new version removes them (see the `window-rows` capability).

#### Scenario: A focus hook of the previous version
- **WHEN** `tagents --poke %67` runs
- **THEN** the exit code is 0, nothing is printed and `tagents-core` was not started
