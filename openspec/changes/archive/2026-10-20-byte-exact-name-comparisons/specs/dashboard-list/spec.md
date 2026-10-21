## MODIFIED Requirements

### Requirement: Rows are grouped into a tree by project
By default rows SHALL be grouped by project: one header line per project followed by that project's rows, drawn with `├` and `└` tees. A project is the repository root of the session's directory. A session started in a subdirectory stays in its project's group and shows the subdirectory, relative to the project, in front of its detail text.

#### Scenario: Tree is the default
- **WHEN** two sessions run in `~/projects/app` and nothing has been toggled to flat
- **THEN** the list has one header line for `app` and two rows under it

#### Scenario: Subdirectory
- **WHEN** a session runs in `~/projects/app/packages/client`
- **THEN** it is listed under the `app` header and its detail text starts with `packages/client`


#### Scenario: Two projects that differ only in a Cyrillic letter
- **WHEN** sessions run in `~/projects/я` and `~/projects/ю`, two of them in the first
- **THEN** the list has a header for each, the two rows of `я` sit together under its header, and the last row of each project is drawn with `└`

#### Scenario: Two directories that differ only in a Cyrillic letter
- **WHEN** sessions run in `~/projects/я/src` and `~/projects/ю/src`, each below its own repository
- **THEN** the headers are `я` and `ю`, and no header is `src`

#### Scenario: The home directory with a letter after it
- **WHEN** a session runs in a project whose path is the home directory followed by `я`
- **THEN** its header names the project after the directory, not `~`
