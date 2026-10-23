## ADDED Requirements

### Requirement: The node commands run with the node that installed them
`install.sh` SHALL write into `tagents-core` and `tagents-knowledge`, the two commands it installs that run a node program, the absolute path of the `node` the installing shell finds on its `PATH`, and SHALL write it again on every install and every `tagents update`. Each of the two SHALL run that node while it is an executable file, and otherwise the `node` on the caller's `PATH`.

#### Scenario: A caller whose PATH holds no node
- **WHEN** tagents was installed from a shell that finds node at `/opt/node/bin/node`, and a process whose `PATH` is `/usr/bin:/bin` runs `tagents-knowledge lint`
- **THEN** the command runs on `/opt/node/bin/node`

#### Scenario: The pinned node is gone
- **WHEN** the node the commands were installed with has been removed, and a process whose `PATH` finds another node runs `tagents-core`
- **THEN** the command runs on the node found on that `PATH`

#### Scenario: Installed from a shell that finds no node
- **WHEN** the installing shell finds no node on its `PATH`, or finds it by a path that is not absolute
- **THEN** both commands look node up on the caller's `PATH`

#### Scenario: An update from a shell with another node
- **WHEN** `tagents update` runs from a shell whose `PATH` finds node somewhere else
- **THEN** both commands run on that node from then on
