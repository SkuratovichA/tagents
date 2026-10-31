## RENAMED Requirements

- FROM: `### Requirement: Editing config.yaml changes only the plugins map`
- TO: `### Requirement: Editing the config changes only the plugins entries`

## MODIFIED Requirements

### Requirement: Plugins are listed explicitly and never discovered
The host SHALL load exactly the plugins named in the `[plugins.<key>]` tables of `config.toml`, in file order, each entry carrying a non-empty `from`, and SHALL NOT scan `node_modules` or any directory for plugins. A missing or unreadable config file, and a config without a `plugins` table, SHALL mean no plugins and not an error; a config that reads but does not parse SHALL be an error naming the file.

#### Scenario: A plugin the config does not name is not loaded
- **WHEN** a valid plugin package sits next to the config but is not listed under `plugins`
- **THEN** the host does not load it

#### Scenario: No config file
- **WHEN** the config file does not exist
- **THEN** the list of plugins is empty and loading reports no error

#### Scenario: An unreadable plugin list is treated as empty
- **WHEN** the config path cannot be read, because it is a directory or its permissions forbid reading
- **THEN** the list of plugins is empty and loading reports no error

#### Scenario: A TOML plugin list that does not parse is an error that names the file
- **WHEN** `config.toml` reads but is not valid TOML
- **THEN** reading the plugin list throws an error whose message names the file

### Requirement: Where the config lives
The tagents config directory SHALL be `$TAGENTS_CONFIG_DIR` when it is set and not blank, otherwise `$XDG_CONFIG_HOME/tagents` when that is set and not blank, otherwise `~/.config/tagents`. The plugin list SHALL be read from `config.toml` in that directory; a `config.yaml` is not looked at.

#### Scenario: The override wins
- **WHEN** `TAGENTS_CONFIG_DIR` and `XDG_CONFIG_HOME` are both set
- **THEN** the config directory is the value of `TAGENTS_CONFIG_DIR`

#### Scenario: The default
- **WHEN** neither variable is set
- **THEN** the config directory is `~/.config/tagents`

#### Scenario: A YAML file is not a config
- **WHEN** the directory holds `config.yaml` and no `config.toml`
- **THEN** the plugin list is empty and nothing is an error

### Requirement: plugin list
`tagents-core plugin list` SHALL print, for each loaded plugin, `<config key> → <from>` and then `  commands: <names> · services: <names> · mcp tools: <names>`, with `—` for an empty group; the name printed is the config key, because that is what `plugin remove` takes. With nothing configured it SHALL print `no plugins configured in <config file>` and exit 0. Each plugin that failed to load SHALL be printed as `<key>: <error>` on stderr and the exit code SHALL be 1.

#### Scenario: Nothing configured
- **WHEN** `plugin list` runs against a config with no plugins
- **THEN** stdout is `no plugins configured in <config dir>/config.toml` and the exit code is 0

#### Scenario: A configured plugin
- **WHEN** a plugin offering verbs, a service and an MCP tool is listed
- **THEN** its key and `from` are printed, then the names it offers in the three groups

#### Scenario: A plugin fails to load
- **WHEN** one listed plugin cannot be imported
- **THEN** the others are still printed, the failure goes to stderr and the exit code is 1

### Requirement: Editing the config changes only the plugins entries
`plugin add` and `plugin remove` SHALL edit the config file in use and change only its `plugins` entries: every other byte, including comments, key order and hand-aligned spacing, SHALL come back unchanged. A config file that does not parse, or an entry the edit cannot place or cut, SHALL be refused with exit 1 and left untouched.

#### Scenario: A hand-written config
- **WHEN** a plugin is added to a config full of comments
- **THEN** the file differs only by the appended entry

#### Scenario: A config that does not parse
- **WHEN** the config has a syntax error
- **THEN** `plugin add` exits 1 and the file is byte for byte unchanged

### Requirement: plugin remove
`tagents-core plugin remove <name>` SHALL take the entry with that config key out of the plugins and print `removed <name> from <config file>`. When it was the last entry, the file is as it was before the entry was added. A name that is not listed, or a missing config, SHALL be refused with exit 3 and `<name> is not listed in <config file>`; no name SHALL be exit 2.

#### Scenario: The last entry
- **WHEN** the only plugin is removed
- **THEN** the config returns to the text it had before the plugin was added

#### Scenario: One of several
- **WHEN** one of two entries is removed
- **THEN** the other entry and the comments after the entries stay as they were

#### Scenario: Not listed
- **WHEN** an unknown name is removed
- **THEN** the exit code is 3 and the file is unchanged

### Requirement: A configured plugin's verbs run as tagents-core verbs
`tagents-core <plugin> <command> [args]` SHALL run the named command of a configured plugin, where `<plugin>` is the plugin's config key or the name its definition gives itself. The core verbs `session`, `sessions`, `plugin`, `doctor` and `help` SHALL be matched first and always win, so a plugin that takes one of those names is unreachable as a verb while still loading. The command's returned number SHALL be the process exit code.

#### Scenario: By key and by own name
- **WHEN** a plugin is listed under `demo` and its definition is named `fixture`
- **THEN** `demo greet` and `fixture greet` run the same command

#### Scenario: A core verb wins
- **WHEN** a plugin is listed under the key `doctor`
- **THEN** `doctor` prints the doctor report

#### Scenario: Exit code
- **WHEN** a command returns 7
- **THEN** the process exits 7

### Requirement: Plugin options live in a file of their own
A plugin's options SHALL be read from `<configDir>/plugins/<name>.toml`, and checked against the plugin's schema, without throwing. Reading an options file SHALL say nothing about the file's format.

#### Scenario: No file
- **WHEN** the options file does not exist
- **THEN** the result is the schema's defaults and `found` is false

#### Scenario: A YAML options file
- **WHEN** only `<name>.yaml` exists, valid or not
- **THEN** it is not looked at and the result is the schema's defaults with `found` false

#### Scenario: A valid file
- **WHEN** `<name>.toml` is valid and fits the schema
- **THEN** the result is the parsed value

### Requirement: A plugin's own executable
A plugin package SHALL be able to ship its own executable that ends in one call to `runPluginBin(plugin)` and uses the result as the process exit code, which runs the plugin's verbs with no registration in the config; the verbs, argument rules, listings and exit codes are exactly those of `tagents-core <plugin> <verb>`, with arguments taken from the process arguments by default.

#### Scenario: A known verb
- **WHEN** the executable runs a verb the plugin declares
- **THEN** the verb runs with its parsed arguments and its return value is the exit code

#### Scenario: No verb or an unknown one
- **WHEN** the executable is run with no verb or an unknown verb
- **THEN** the plugin's commands are listed and the exit code is 2

#### Scenario: A bad flag and a throw
- **WHEN** a flag cannot be parsed, or a verb throws
- **THEN** the exit code is 2 for the flag and 1, with the message, for the throw

### Requirement: Running one service without a config file
A caller holding a plugin definition SHALL be able to start one of its services under a context, with no config file, and receive `drain()` (finish what is in flight, take no new work), `stop(reason?)` (give up now; the reason reaches the service) and `done` (settles when the service is over). `done` is the service's own when it supplies one; otherwise it settles once `drain` or `stop` was called. An unknown service SHALL fail naming the plugin, the service and the services it has.

#### Scenario: Started and stopped
- **WHEN** a named service is run and then stopped
- **THEN** the service saw the stop and `done` resolves

#### Scenario: A service that decides for itself
- **WHEN** the service supplies its own `done`
- **THEN** `done` follows it, not the stop call

#### Scenario: A service the plugin lacks
- **WHEN** the name matches no service
- **THEN** the call fails with `plugin "<name>" has no service "<service>" (it has: <names>)`, an empty list reading `none`

### Requirement: The usage names the plugin verbs
The usage that `tagents-core help`, `--help` and `-h` print (exit 0; no arguments prints it and exits 2) SHALL list the four `plugin` verbs with their options, `doctor`, the line `<plugin> <command> [args]` for a configured plugin's own verb, the line `reserved: session · sessions · plugin · doctor · help — a core verb always wins` and the exit codes `0 ok · 1 error · 2 usage · 3 refused · 4 timeout`.

#### Scenario: Help
- **WHEN** `help` runs
- **THEN** the exit code is 0 and the plugin line and the reserved words are in the output

## ADDED Requirements

### Requirement: Adding to a TOML config
In a `config.toml` a new entry SHALL be a `[plugins.<key>]` table with a `from` line, appended after everything else behind one blank line.

#### Scenario: A second entry in a TOML config
- **WHEN** a plugin is added to a `config.toml` that already has `[plugins.a]`
- **THEN** `[plugins.b]` follows the rest of the file and `[plugins.a]` is unchanged

### Requirement: Removing from a TOML config
Removing an entry from a `config.toml` SHALL cut its `[plugins.<key>]` table and any `[plugins.<key>.…]` tables under it, with the comment lines just above the next header that belong to it, and the result SHALL be parsed again before it is written.

#### Scenario: Removing the only entry
- **WHEN** `plugin remove x` runs on a `config.toml` whose only plugin is `[plugins.x]`, followed by a `[usage]` table
- **THEN** the `[plugins.x]` table is cut, no empty `[plugins]` is left, and `[usage]` is unchanged

### Requirement: A new config is TOML
When no config exists, `plugin add` SHALL create `config.toml`.

#### Scenario: No config yet
- **WHEN** `plugin add` runs in a config directory with no config file
- **THEN** `config.toml` is created holding the entry

### Requirement: A plugin options file with a problem
A plugin's options file that cannot be read or parsed SHALL give one problem naming the file; one that does not fit the plugin's schema SHALL give one `<path>: <message>` line per issue, with dotted paths.

#### Scenario: Broken TOML
- **WHEN** the file is not valid TOML
- **THEN** there is one problem and it names the file

#### Scenario: Schema mismatch
- **WHEN** two fields do not fit the schema
- **THEN** there are two problem lines, each `<path>: <message>`

### Requirement: A missing or empty plugin options file
A missing plugin options file SHALL give the schema's defaults and report that it was not found, naming the `.toml` path; an empty file the defaults, found; a valid file the parsed value.

#### Scenario: An empty file
- **WHEN** the options file is empty
- **THEN** the result is the schema's defaults and `found` is true
