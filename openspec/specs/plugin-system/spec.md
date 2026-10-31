# plugin-system Specification

## Purpose
How tagents is extended: a plugin is a package that offers CLI verbs, long-running services and MCP tools as data. This capability covers the plugin definition, how the host finds and loads plugins from `config.toml`, the `tagents-core plugin` verbs, running a plugin's verbs and services, plugin options files, the testkit and `tagents-core doctor`.

## Requirements

### Requirement: A plugin is one definition object
A plugin package SHALL default-export one object made with `definePlugin`, carrying a non-empty `name`, `apiVersion: 1` and, optionally, `commands` (CLI verbs), `services` (long-running things), `mcpTools` (MCP tools) and `locales` (translation resources keyed by locale, then namespace). `definePlugin` SHALL return exactly the object it is given.

#### Scenario: definePlugin is the identity
- **WHEN** a plugin author passes a definition to `definePlugin`
- **THEN** the same object comes back unchanged

#### Scenario: A definition is data
- **WHEN** the host imports a plugin to list what it offers
- **THEN** the commands, services and MCP tools are read from the exported object without running any of them

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

### Requirement: Where a plugin's package is found
`from` SHALL name a package by path or by package name. A path that starts with `.` or is absolute SHALL be resolved against the directory of the config file, not the working directory. When a relative path has no `package.json` there and the config directory is a symlink, it SHALL be tried once more from the real directory; a lexical hit wins, and a miss on both keeps the lexical path in the error. Anything else is a package name, resolved from the config directory.

#### Scenario: Relative to the config, not to the shell
- **WHEN** `from: ../plugins/demo` is listed and the command runs from an unrelated directory
- **THEN** the package is looked up relative to the config file's directory

#### Scenario: A symlinked config directory
- **WHEN** the config directory is a symlink into a dotfiles repository and a relative `from` only resolves from the real directory
- **THEN** the package is found there

#### Scenario: A package name
- **WHEN** `from` is a package name that resolves from the config directory
- **THEN** that package's directory is used

### Requirement: The package manifest says where the code is
A plugin package's `package.json` SHALL declare `"tagents": { "entry": "<file>" }`, resolved against the package directory. Loading SHALL import the entry and take its default export (or, failing that, its export named `plugin`) as the definition, which must have a non-empty `name` and `apiVersion` 1. Each failure SHALL be one sentence naming the file: no `package.json`, no `tagents.entry`, an import error, or an export that is not a definition.

#### Scenario: Imported through the manifest
- **WHEN** a listed package declares `tagents.entry`
- **THEN** that file is imported and its definition is what the host holds for the plugin

#### Scenario: Not a plugin definition
- **WHEN** the entry exports something without `name` and `apiVersion: 1`
- **THEN** loading that plugin fails with a sentence saying the entry must default-export a `definePlugin({ name, apiVersion: 1 })` object

### Requirement: One broken plugin does not stop the others
Loading the configured plugins SHALL report a plugin that fails as an error entry carrying its config key, its `from` and a message, and SHALL still load every plugin that works.

#### Scenario: A broken plugin beside a good one
- **WHEN** the config lists a plugin whose entry file is missing and a working plugin
- **THEN** the working plugin loads, and the broken one is reported with its error

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

### Requirement: plugin list --json
`tagents-core plugin list --json` SHALL print exactly one pretty-printed JSON document on stdout with `file` (the config file path), `plugins` (each with `name` of the definition, `configuredAs` the config key, `from`, `entry`, `apiVersion`, and the name lists `commands`, `services` and `mcpTools`) and `errors` (each with `name`, `from` and `error`). The exit code SHALL be 1 when `errors` is not empty, otherwise 0.

#### Scenario: Empty
- **WHEN** nothing is configured
- **THEN** the document has empty `plugins` and `errors` and the exit code is 0

### Requirement: plugin add checks a package without importing it
`tagents-core plugin add <package-or-path> [--name N]` SHALL resolve the argument as a directory (starting with `.` or `~`, or absolute) or as a package name installed where the caller stands (then in the global pnpm store), read its `package.json`, check that the manifest's entry file exists, and SHALL NOT import the package. A directory SHALL be stored as an absolute path, a package name as the name. On success it prints `added <key> → <from> to <config file>` and exits 0.

#### Scenario: A relative path is stored absolute
- **WHEN** `plugin add ./demo` runs from the parent directory
- **THEN** the entry's `from` is the absolute path of `demo`, and the host reads it back

#### Scenario: An installed package name
- **WHEN** the argument is the name of a package installed in the caller's `node_modules`
- **THEN** the entry's `from` is that name

#### Scenario: Nothing is imported
- **WHEN** a package with a valid manifest is added
- **THEN** the check reads `package.json` and stats the entry file only

### Requirement: plugin add exit codes
`plugin add` SHALL exit 2 when no argument is given or the key is unusable, 1 when nothing resolves (`no package at <spec>: …`), and 3 when something is there but is not a plugin or the key is already listed, and in every refusal it SHALL write nothing to the config. A directory without a readable `package.json` counts as nothing resolving; an installed package whose manifest is unreadable or has no `tagents` entry is a refusal.

#### Scenario: Not a plugin
- **WHEN** the package has no `tagents` manifest
- **THEN** the exit code is 3, stderr says the file has no `"tagents"` manifest, and no config file is created

#### Scenario: The entry file is missing
- **WHEN** the manifest points at a file that does not exist
- **THEN** the exit code is 3 and stderr says the manifest points at a file which does not exist

#### Scenario: Nowhere
- **WHEN** the argument names no directory and no installed package
- **THEN** the exit code is 1

#### Scenario: Already listed
- **WHEN** the key is already under `plugins:`
- **THEN** the exit code is 3, stderr says the key is already listed, and the file is unchanged

#### Scenario: No argument
- **WHEN** no package or path is given
- **THEN** the exit code is 2

### Requirement: The key a plugin is added under
The key SHALL be `--name` when given, otherwise the package name with its scope and its `tagents-plugin-` or `plugin-` prefix removed (`@tagents/plugin-telegram` becomes `telegram`, `fixture-plugin` stays). A key SHALL start with a letter or digit and contain only letters, digits, `.`, `_` and `-`; anything else SHALL be refused with exit 2.

#### Scenario: Default key
- **WHEN** a package named `tagents-plugin-notes` is added without `--name`
- **THEN** it is listed under the key `notes`

#### Scenario: Explicit key
- **WHEN** `--name demo` is given
- **THEN** the entry is listed under `demo`

### Requirement: Editing the config changes only the plugins entries
`plugin add` and `plugin remove` SHALL edit the config file in use and change only its `plugins` entries: every other byte, including comments, key order and hand-aligned spacing, SHALL come back unchanged. A config file that does not parse, or an entry the edit cannot place or cut, SHALL be refused with exit 1 and left untouched.

#### Scenario: A hand-written config
- **WHEN** a plugin is added to a config full of comments
- **THEN** the file differs only by the appended entry

#### Scenario: A second entry
- **WHEN** a plugin is added to a map that already has one
- **THEN** the new entry lands after the last one, indented like it

#### Scenario: An empty map
- **WHEN** the file has `plugins:` with nothing under it, or `plugins: {}`
- **THEN** that line becomes a block holding the new entry

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

### Requirement: plugin new scaffolds a working plugin
`tagents-core plugin new <name> [--dir D]` SHALL write into `D` (default `./<name>`) a package `tagents-plugin-<name>` that is already a plugin and typechecks as written, and print `wrote <dir> — install it with: tagents plugin add <dir>`. The name must be usable as a key (exit 2 otherwise). A non-empty target directory SHALL be refused with exit 3 and left alone; an empty one is accepted.

#### Scenario: The files written
- **WHEN** the scaffold is written
- **THEN** the directory holds `package.json`, `tsconfig.json`, `src/plugin.ts` with one verb `hello`, `test/plugin.test.ts` and `README.md`

#### Scenario: The manifest of the scaffold
- **WHEN** the scaffold is written
- **THEN** its `package.json` declares `"tagents": { "apiVersion": 1, "entry": "./src/plugin.ts" }` and a `link:` dependency on the `@tagents/core` of the checkout it came from

#### Scenario: The scaffold is installable
- **WHEN** `plugin new demo --dir D` runs and then `plugin add D`
- **THEN** the add succeeds and the host lists `demo` pointing at `D`

#### Scenario: Something is in the way
- **WHEN** the target directory holds a file
- **THEN** the exit code is 3, stderr says the directory exists and is not empty, and the file is intact

#### Scenario: A name that cannot be a key
- **WHEN** the name is `../escape`
- **THEN** the exit code is 2

### Requirement: Unknown plugin subcommand
`tagents-core plugin` with a word other than `list`, `add`, `remove` and `new` SHALL print `unknown command: plugin <word>` and the usage on stderr and exit 2. An option these verbs do not know SHALL be a usage error (exit 2).

#### Scenario: Unknown word
- **WHEN** `plugin install x` runs
- **THEN** the exit code is 2 and the usage, which lists `plugin add <package-or-path>`, is printed

### Requirement: A configured plugin's verbs run as tagents-core verbs
`tagents-core <plugin> <command> [args]` SHALL run the named command of a configured plugin, where `<plugin>` is the plugin's config key or the name its definition gives itself. The core verbs `session`, `sessions`, `plugin`, `config`, `doctor` and `help` SHALL be matched first and always win, so a plugin that takes one of those names is unreachable as a verb while still loading. The command's returned number SHALL be the process exit code.

#### Scenario: By key and by own name
- **WHEN** a plugin is listed under `demo` and its definition is named `fixture`
- **THEN** `demo greet` and `fixture greet` run the same command

#### Scenario: A core verb wins
- **WHEN** a plugin is listed under the key `doctor`
- **THEN** `doctor` prints the doctor report

#### Scenario: Exit code
- **WHEN** a command returns 7
- **THEN** the process exits 7

### Requirement: Plugin command arguments
The arguments after the command name SHALL be parsed without knowledge of the command: `--key value` takes the next token unless it starts with `--`, `--key=value` and `--flag` (true) are accepted, `--` ends the options and anything else is a positional; an empty option key is refused as `not a usable option: <arg>` (exit 2). The command's own schema SHALL decide types, coercion, defaults and what is required; a failure prints one `<path>: <message>` line per issue on stderr and exits 2.

#### Scenario: Positionals are refused unless asked for
- **WHEN** positionals are given to a command whose schema does not declare an `_` key
- **THEN** stderr says `<plugin> <command> takes no positional arguments: <args>` and the exit code is 2

#### Scenario: Flag forms
- **WHEN** `--name Sasha --times=3` is given
- **THEN** both reach the schema as `name` and `times`, and a negative value after a flag, as in `--code -1`, is taken as its value

#### Scenario: Invalid arguments
- **WHEN** a required argument is missing or `--times often` is not a number
- **THEN** stderr has one `<key>: <message>` line per issue and the exit code is 2

#### Scenario: Stray positionals
- **WHEN** positionals are given to a command that does not declare `_`
- **THEN** the exit code is 2 and nothing is run

#### Scenario: Positionals taken
- **WHEN** a command declares `_` and gets `a b c`
- **THEN** it receives the three positionals

### Requirement: What a plugin command may print
A plugin command's `ctx.log` output SHALL be written to stderr, one line per call with the parts joined by a space, because stdout belongs to the JSON verbs. A command that throws SHALL cause its message as one line on stderr and exit 1.

#### Scenario: Logging goes to stderr
- **WHEN** a command logs `hello Sasha`
- **THEN** stdout is empty and stderr is `hello Sasha`

#### Scenario: A throw
- **WHEN** a command throws an error with the message `the fixture exploded`
- **THEN** stderr is that line and the exit code is 1

### Requirement: Listing what a plugin offers
`tagents-core <plugin>` with no command, or with a command the plugin does not have, SHALL list the plugin's commands on stderr as `commands of <plugin>:` followed by `  <name> — <describe>` lines and exit 2; for an unknown command it SHALL first print `unknown command: <plugin> <word>`. A plugin with no commands SHALL print `<plugin> offers no commands` and exit 2.

#### Scenario: Bare plugin name
- **WHEN** `demo` is run with no command
- **THEN** stdout is empty, stderr lists the commands, no `unknown command` line is printed and the exit code is 2

#### Scenario: Unknown command
- **WHEN** `demo nope` is run
- **THEN** stderr says `unknown command: demo nope`, lists the commands, and the exit code is 2

### Requirement: Words no plugin answers to, and plugins that did not load
A first word that is no core verb and no configured plugin SHALL be reported as `unknown command: <word>` with the usage on stderr and exit 2. A word that names a configured plugin that failed to load SHALL report the load error as `<key>: <error>` and exit 1, never as an unknown command.

#### Scenario: Unknown word
- **WHEN** `telegram status` runs and no plugin answers to `telegram`
- **THEN** stderr has `unknown command: telegram` and the usage, and the exit code is 2

#### Scenario: A broken plugin
- **WHEN** the plugin `broken` cannot be loaded and `broken anything` runs
- **THEN** stderr starts with `broken: `, stdout is empty and the exit code is 1

#### Scenario: The others still work
- **WHEN** one configured plugin is broken
- **THEN** a verb of a working plugin runs normally

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

### Requirement: The context a plugin is given
A plugin SHALL receive a context with a session `driver` (a plugin never spawns `claude` itself), a translator `t`, a `log` function, the `configDir` of the host (as defined above, unless a caller passes another) and an `agents` feed (the state rows and event stream of the `agent-state` and `event-stream` capabilities). Two contexts in one process SHALL be independent. A caller may pass its own driver, feed, log, config directory or locale; without a log nothing is logged.

#### Scenario: Default parts
- **WHEN** a context is created for a plugin with no overrides
- **THEN** it has a driver, a translator on the plugin's catalogue, a config directory and an agent feed on the default state directory

#### Scenario: Passed parts are used
- **WHEN** an agent feed or driver is passed
- **THEN** the context carries exactly that one

### Requirement: Translations a plugin brings
The translator SHALL be bound to the core catalogue with the plugin's `locales` laid over it, locale by locale and namespace by namespace, so the plugin owns its own namespaces and core keeps `core` and neither shadows the other's keys; a locale only the plugin speaks SHALL be available. The locale SHALL be the one passed by the caller, else `TAGENTS_LOCALE`, if the merged catalogue has it, else the default locale; missing keys SHALL fall back to the default locale.

#### Scenario: Merged catalogues
- **WHEN** a plugin supplies messages under its own namespace
- **THEN** its keys and core's keys both resolve

#### Scenario: A plugin-only locale
- **WHEN** only the plugin speaks a locale and it is requested
- **THEN** the context uses that locale

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

### Requirement: Signals are wired only on request
Running a service with `signals: true` SHALL turn SIGINT, SIGTERM and SIGHUP into `stop(<signal name>)`, installed before the service's start is awaited; the first signal counts, one arriving during start is acted on once the start has settled, and later ones are swallowed until the service is done, when the handlers are removed. A failed start, or a throwing stop for an early signal, SHALL remove the handlers and rethrow. Without `signals: true` the process keeps its own signal handling.

#### Scenario: A signal stops the service
- **WHEN** a service runs with `signals: true` and SIGTERM arrives
- **THEN** the service is stopped with the reason `SIGTERM` and the listeners leave with it

#### Scenario: A signal during start
- **WHEN** a signal arrives while the service's start is still running
- **THEN** the service is stopped once the start has resolved

#### Scenario: Start fails
- **WHEN** the start rejects
- **THEN** no handler stays behind and nothing is stopped

#### Scenario: A second signal while draining
- **WHEN** a second signal arrives while the first stop is still draining
- **THEN** it is swallowed and the handlers go when the service is done

#### Scenario: Not requested
- **WHEN** `signals` is not set
- **THEN** no signal listener is added by the call

### Requirement: Plugin options live in a file of their own
A plugin's options SHALL be read from `<configDir>/plugins/<name>.toml`, and checked against the plugin's schema, without throwing. Reading an options file SHALL say nothing about the file's format.

#### Scenario: No file
- **WHEN** the options file does not exist
- **THEN** the result is the schema's defaults and `found` is false

#### Scenario: Broken YAML
- **WHEN** only `<name>.yaml` exists, valid or not
- **THEN** it is not looked at and the result is the schema's defaults with `found` false

#### Scenario: Broken TOML
- **WHEN** `<name>.toml` exists and is not valid TOML
- **THEN** there is one problem and it names the file

#### Scenario: Schema mismatch
- **WHEN** two fields do not fit the schema
- **THEN** there are two problem lines, each `<path>: <message>`

#### Scenario: A valid file
- **WHEN** `<name>.toml` is valid and fits the schema
- **THEN** the result is the parsed value

### Requirement: doctor
`tagents-core doctor` SHALL print four lines on stdout and exit 0 with nothing on stderr: `node <version> (<path of the node binary>)`, `agent state <state dir> (<n> record(s))`, `config <config file>: present|missing` and `claude: <path of claude on PATH>|missing`. The `claude` line SHALL be answered by looking along `PATH`, not by running it. The words are localised; the state dir and the records are those of the `agent-state` capability.

#### Scenario: A fresh machine
- **WHEN** doctor runs with no config file
- **THEN** stdout starts with `node v`, reports the state directory and its record count, and says `config <file>: missing`

#### Scenario: Not shadowed
- **WHEN** a plugin is listed under the key `doctor`
- **THEN** `doctor` still prints this report

### Requirement: The usage names the plugin verbs
The usage that `tagents-core help`, `--help` and `-h` print (exit 0; no arguments prints it and exits 2) SHALL list the four `plugin` verbs with their options, `doctor`, the line `<plugin> <command> [args]` for a configured plugin's own verb, the line `reserved: session · sessions · plugin · doctor · help — a core verb always wins` and the exit codes `0 ok · 1 error · 2 usage · 3 refused · 4 timeout`.

#### Scenario: Help
- **WHEN** `help` runs
- **THEN** the exit code is 0 and the plugin line and the reserved words are in the output

### Requirement: The testkit for plugin authors
`@tagents/core` SHALL export `fakeClaude(script)`, which writes a real executable named `claude` into a temporary directory and returns its directory, its full path and a `cleanup()`, so a test can put the directory on `PATH` or pass the file as the session binary. The fake is single-shot: a count file gets one line per invocation, an argv file the invocation's arguments and environment. It SHALL also export `tmpDir`, `sleep`, `drained` and `FakeClock`.

#### Scenario: A fake claude
- **WHEN** a test writes a fake with a scripted result and puts its directory on `PATH`
- **THEN** spawning `claude` runs the script and prints its scripted stream

#### Scenario: Waiting
- **WHEN** a condition checked by `drained` never becomes true within the timeout
- **THEN** it rejects with `timed out waiting for <what>`

#### Scenario: A fake clock
- **WHEN** a test advances a `FakeClock` by some milliseconds
- **THEN** the timers that fall inside that span fire in order and the clock's now moves by that amount

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

### Requirement: A missing or empty plugin options file
A missing plugin options file SHALL give the schema's defaults and report that it was not found, naming the `.toml` path; an empty file the defaults, found; a valid file the parsed value.

#### Scenario: An empty file
- **WHEN** the options file is empty
- **THEN** the result is the schema's defaults and `found` is true
