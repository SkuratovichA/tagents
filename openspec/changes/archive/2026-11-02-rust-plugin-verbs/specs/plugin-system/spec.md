## ADDED Requirements

### Requirement: A symbolic config keeps its link
When `config.toml` is a symbolic link, `plugin add` and `plugin remove` SHALL write the new text to the file the link ends in, through a temporary file beside that file renamed over it, so the link stays a link. A link to nowhere or in a loop SHALL fail with exit 1 and the system's error, and nothing SHALL be written or created.

#### Scenario: A config kept in a dotfiles repository
- **WHEN** `config.toml` is a link to a file in another directory and a plugin is added and then removed
- **THEN** the link text is unchanged both times and the file it points to holds the entry after the add and the old text after the remove

#### Scenario: A link to nowhere
- **WHEN** `config.toml` is a link whose target does not exist and `plugin add` runs
- **THEN** the exit code is 1, stderr holds the `ENOENT` text, and no file exists at the target of the link

#### Scenario: A link loop
- **WHEN** `config.toml` is a link that leads back to itself and `plugin remove` runs
- **THEN** the exit code is 1 and stderr holds the `ELOOP` text

### Requirement: Only a missing config is read as empty
`plugin add` and `plugin remove` SHALL read a missing config (ENOENT) as an empty one. Any other failure to read it, a directory, a refused permission or an I/O error, SHALL fail the verb with exit 1 and the text of the error, and nothing SHALL be written, so a config that cannot be read is never replaced.

#### Scenario: The config is a directory
- **WHEN** `config.toml` is a directory and `plugin add` runs
- **THEN** the exit code is 1, stderr holds the `EISDIR` text, and the directory is as it was

#### Scenario: The config cannot be read
- **WHEN** `config.toml` exists, the user may not read it, and `plugin add` runs
- **THEN** the exit code is 1, stderr holds the `EACCES` text, and the file is byte for byte as it was

#### Scenario: The config is missing
- **WHEN** no `config.toml` exists
- **THEN** `plugin add` creates it and `plugin remove` is refused with exit 3
