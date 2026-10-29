# MCP tools

This file is generated from the code by `pnpm plugin:gen`. Do not edit it by hand: change the code and regenerate.

## tagents-knowledge

### knowledge_get

The markdown of one document by id, or of a single "## " section when heading is given.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | document id, the filename stem |
| `heading` | string | no | a "## " heading inside that document; omit for the whole document |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "id": {
      "type": "string",
      "minLength": 1,
      "description": "document id, the filename stem"
    },
    "heading": {
      "description": "a \"## \" heading inside that document; omit for the whole document",
      "type": "string"
    }
  },
  "required": [
    "id"
  ],
  "$schema": "http://json-schema.org/draft-07/schema#"
}
```

### knowledge_list

Every document as JSON: id, title, type, description, tags, status, stale, updated, path, headings. Documents with status deprecated come last.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `type` | string | no | only this type (case-insensitive, for example Runbook) |
| `kind` | string | no | deprecated alias of type |
| `tag` | string | no | only documents carrying this tag |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "type": {
      "description": "only this type (case-insensitive, for example Runbook)",
      "type": "string"
    },
    "kind": {
      "description": "deprecated alias of type",
      "type": "string"
    },
    "tag": {
      "description": "only documents carrying this tag",
      "type": "string"
    }
  },
  "$schema": "http://json-schema.org/draft-07/schema#"
}
```

### knowledge_search

Full-text search over the owner's knowledge documents (Russian and English). Returns the matching sections as JSON: id, title, heading, score, snippet, path, type, description, status, stale. Documents with status deprecated come last. Read a whole section with knowledge_get.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | words to look for; all of them must appear |
| `tag` | string | no | only documents carrying this tag |
| `type` | string | no | only documents of this type (case-insensitive, for example Runbook) |
| `kind` | string | no | deprecated alias of type |
| `limit` | integer | no | how many sections (default 10) |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "minLength": 1,
      "description": "words to look for; all of them must appear"
    },
    "tag": {
      "description": "only documents carrying this tag",
      "type": "string"
    },
    "type": {
      "description": "only documents of this type (case-insensitive, for example Runbook)",
      "type": "string"
    },
    "kind": {
      "description": "deprecated alias of type",
      "type": "string"
    },
    "limit": {
      "description": "how many sections (default 10)",
      "type": "integer",
      "exclusiveMinimum": 0,
      "maximum": 50
    }
  },
  "required": [
    "query"
  ],
  "$schema": "http://json-schema.org/draft-07/schema#"
}
```

### knowledge_usage

What the knowledge documents are used for, as JSON rows, the most read first: id, type, status, gets (times the document or one of its sections was read), hits (times a search returned it), days (distinct UTC dates with a get inside the window), last (UTC date of the newest get, null when never read). Unread documents are listed with zeros. With candidates, only the documents read often enough on enough days to be worth turning into a skill. Looking at the numbers is not a read.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `since` | string | no | the window, a whole number of days and a d, for example 30d (default 30d) |
| `top` | integer | no | how many rows (default 20) |
| `type` | string | no | only documents of this type (case-insensitive, for example Runbook) |
| `all` | boolean | no | also list the ids that have events but are no longer in the folder |
| `candidates` | boolean | no | only the documents that are not deprecated and were read at least min_gets times on at least min_days dates |
| `min_gets` | integer | no | gets a candidate needs inside the window (default 5) |
| `min_days` | integer | no | UTC dates a candidate needs a get on inside the window (default 3) |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "since": {
      "description": "the window, a whole number of days and a d, for example 30d (default 30d)",
      "type": "string"
    },
    "top": {
      "description": "how many rows (default 20)",
      "type": "integer",
      "exclusiveMinimum": 0,
      "maximum": 9007199254740991
    },
    "type": {
      "description": "only documents of this type (case-insensitive, for example Runbook)",
      "type": "string"
    },
    "all": {
      "description": "also list the ids that have events but are no longer in the folder",
      "type": "boolean"
    },
    "candidates": {
      "description": "only the documents that are not deprecated and were read at least min_gets times on at least min_days dates",
      "type": "boolean"
    },
    "min_gets": {
      "description": "gets a candidate needs inside the window (default 5)",
      "type": "integer",
      "exclusiveMinimum": 0,
      "maximum": 9007199254740991
    },
    "min_days": {
      "description": "UTC dates a candidate needs a get on inside the window (default 3)",
      "type": "integer",
      "exclusiveMinimum": 0,
      "maximum": 9007199254740991
    }
  },
  "$schema": "http://json-schema.org/draft-07/schema#"
}
```

### sessions_recent

The latest sessions across every Claude account on this machine, newest first — the same text the sessions CLI prints.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `limit` | integer | no | how many (default 15) |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "limit": {
      "description": "how many (default 15)",
      "type": "integer",
      "exclusiveMinimum": 0,
      "maximum": 50
    }
  },
  "$schema": "http://json-schema.org/draft-07/schema#"
}
```

### sessions_search

Sessions whose project path or opening prompt contains every one of these words — the same text the sessions CLI prints.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `words` | string | yes | words that must all appear |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "words": {
      "type": "string",
      "minLength": 1,
      "description": "words that must all appear"
    }
  },
  "required": [
    "words"
  ],
  "$schema": "http://json-schema.org/draft-07/schema#"
}
```

## tagents

### core_doctor

Prints the node version, the state directory, the config file and whether claude is on PATH.

#### Inputs

This tool takes no inputs.

#### Input schema

```json
{
  "type": "object",
  "properties": {},
  "required": [],
  "additionalProperties": false
}
```

### core_plugin_add

Validates a package manifest and writes the plugin into config.yaml.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `package_or_path` | string | yes |  |
| `name` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "package_or_path": {
      "type": "string"
    },
    "name": {
      "type": "string"
    }
  },
  "required": [
    "package_or_path"
  ],
  "additionalProperties": false
}
```

### core_plugin_list

Lists the configured plugins and what each offers, as lines or with --json one JSON document.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `json` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "json": {
      "type": "boolean"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### core_plugin_new

Scaffolds a package that is already a plugin.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes |  |
| `dir` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    },
    "dir": {
      "type": "string"
    }
  },
  "required": [
    "name"
  ],
  "additionalProperties": false
}
```

### core_plugin_remove

Takes one plugin entry back out of config.yaml.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    }
  },
  "required": [
    "name"
  ],
  "additionalProperties": false
}
```

### core_session_abort

Stops the turn running in a session and prints whether it did, with the id and pid, as JSON.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `ref_json_or_id` | string | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "ref_json_or_id": {
      "type": "string"
    }
  },
  "required": [
    "ref_json_or_id"
  ],
  "additionalProperties": false
}
```

### core_session_last

Prints the last assistant text of a session and when it came, as JSON, or null.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `ref_json_or_id` | string | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "ref_json_or_id": {
      "type": "string"
    }
  },
  "required": [
    "ref_json_or_id"
  ],
  "additionalProperties": false
}
```

### core_session_list

Prints the known sessions as a JSON array of SessionRef, filtered by label and state.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `label` | string | no |  |
| `state` | string[] | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "label": {
      "type": "string"
    },
    "state": {
      "type": "array",
      "items": {
        "type": "string"
      }
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### core_session_open

Prepares a headless Claude session for a directory and prints its SessionRef as JSON; no process starts until a prompt is sent to it.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `cwd` | string | yes |  |
| `label` | string | no |  |
| `model` | string | no |  |
| `effort` | string | no |  |
| `resume` | string | no |  |
| `system-prompt-file` | string | no |  |
| `mcp-config` | string | no |  |
| `config-dir` | string | no |  |
| `no-config-dir` | boolean | no |  |
| `skip-permissions` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "cwd": {
      "type": "string"
    },
    "label": {
      "type": "string"
    },
    "model": {
      "type": "string"
    },
    "effort": {
      "type": "string"
    },
    "resume": {
      "type": "string"
    },
    "system-prompt-file": {
      "type": "string"
    },
    "mcp-config": {
      "type": "string"
    },
    "config-dir": {
      "type": "string"
    },
    "no-config-dir": {
      "type": "boolean"
    },
    "skip-permissions": {
      "type": "boolean"
    }
  },
  "required": [
    "cwd"
  ],
  "additionalProperties": false
}
```

### core_session_prompt

Runs one Claude turn: sends the prompt to a session, waits for the answer and prints the TurnOutcome as JSON; with --events, NDJSON events with the outcome last.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `ref_json_or_id` | string | yes |  |
| `text` | string | yes |  |
| `timeout` | string | no |  |
| `warn-before` | string | no |  |
| `events` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "ref_json_or_id": {
      "type": "string"
    },
    "text": {
      "type": "string"
    },
    "timeout": {
      "type": "string"
    },
    "warn-before": {
      "type": "string"
    },
    "events": {
      "type": "boolean"
    }
  },
  "required": [
    "ref_json_or_id",
    "text"
  ],
  "additionalProperties": false
}
```

### core_sessions_recent

Prints the most recent transcripts as text.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `n` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "n": {
      "type": "string"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### core_sessions_search

Prints the transcripts that match the words, as text.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `words` | string[] | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "words": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "minItems": 1
    }
  },
  "required": [
    "words"
  ],
  "additionalProperties": false
}
```

### core_sessions_show

Prints the full text of one transcript, picked by id prefix.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `id_prefix` | string | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "id_prefix": {
      "type": "string"
    }
  },
  "required": [
    "id_prefix"
  ],
  "additionalProperties": false
}
```

### knowledge_index

Brings the index in line with the folder; --full rebuilds it from nothing.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |
| `db` | string | no |  |
| `full` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "db": {
      "type": "string"
    },
    "full": {
      "type": "boolean"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### knowledge_lint

Checks the claims each document makes about itself.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### knowledge_list

Prints one line per document: id, type, updated, title and tags; --type filters by type (--kind is its deprecated alias); deprecated documents come last.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |
| `db` | string | no |  |
| `type` | string | no |  |
| `kind` | string | no |  |
| `tag` | string | no |  |
| `json` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "db": {
      "type": "string"
    },
    "type": {
      "type": "string"
    },
    "kind": {
      "type": "string"
    },
    "tag": {
      "type": "string"
    },
    "json": {
      "type": "boolean"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### knowledge_search

Prints one line per hit: id#heading, score and snippet; --type filters by type (--kind is its deprecated alias); deprecated documents come last; each document it returns is recorded as a hit in the usage store (--usage-db F names the file, --verbose says why a read was not recorded).

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `query` | string[] | yes |  |
| `dir` | string | no |  |
| `db` | string | no |  |
| `tag` | string | no |  |
| `type` | string | no |  |
| `kind` | string | no |  |
| `limit` | string | no |  |
| `json` | boolean | no |  |
| `usage-db` | string | no |  |
| `verbose` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "minItems": 1
    },
    "dir": {
      "type": "string"
    },
    "db": {
      "type": "string"
    },
    "tag": {
      "type": "string"
    },
    "type": {
      "type": "string"
    },
    "kind": {
      "type": "string"
    },
    "limit": {
      "type": "string"
    },
    "json": {
      "type": "boolean"
    },
    "usage-db": {
      "type": "string"
    },
    "verbose": {
      "type": "boolean"
    }
  },
  "required": [
    "query"
  ],
  "additionalProperties": false
}
```

### knowledge_show

Prints the markdown of a document, or of one section of it; the read is recorded as a get in the usage store (--usage-db F names the file, --verbose says why a read was not recorded).

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `id_heading` | string | yes |  |
| `dir` | string | no |  |
| `db` | string | no |  |
| `usage-db` | string | no |  |
| `verbose` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "id_heading": {
      "type": "string"
    },
    "dir": {
      "type": "string"
    },
    "db": {
      "type": "string"
    },
    "usage-db": {
      "type": "string"
    },
    "verbose": {
      "type": "boolean"
    }
  },
  "required": [
    "id_heading"
  ],
  "additionalProperties": false
}
```

### knowledge_toc

Writes index.md, the OKF table of contents of the folder, grouped by type; --check writes nothing and exits 1 when index.md is absent or out of date.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |
| `check` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "check": {
      "type": "boolean"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### knowledge_usage

Reports what was read: one line per document with its type, status, gets, hits, the UTC days with a get and the date of the last get, the most read first; --since Nd sets the window (default 30d), --top N the number of lines (default 20), --type T keeps one type, --all adds ids that left the folder, --candidates keeps the documents read at least --min-gets times (default 5) on at least --min-days days (default 3), the ones worth turning into a skill; --usage-db F names the usage store.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |
| `db` | string | no |  |
| `usage-db` | string | no |  |
| `since` | string | no |  |
| `top` | string | no |  |
| `type` | string | no |  |
| `all` | boolean | no |  |
| `candidates` | boolean | no |  |
| `min-gets` | string | no |  |
| `min-days` | string | no |  |
| `json` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "db": {
      "type": "string"
    },
    "usage-db": {
      "type": "string"
    },
    "since": {
      "type": "string"
    },
    "top": {
      "type": "string"
    },
    "type": {
      "type": "string"
    },
    "all": {
      "type": "boolean"
    },
    "candidates": {
      "type": "boolean"
    },
    "min-gets": {
      "type": "string"
    },
    "min-days": {
      "type": "string"
    },
    "json": {
      "type": "boolean"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### notify_install

Installs and starts the notification service as a login item, builds its helper app and asks macOS for permission to notify.

#### Inputs

This tool takes no inputs.

#### Input schema

```json
{
  "type": "object",
  "properties": {},
  "required": [],
  "additionalProperties": false
}
```

### notify_send

Posts a desktop notification with this message through the configured backend, which shows it on the screen; a click docks the pane the command runs in.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `message` | string | yes |  |
| `title` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "message": {
      "type": "string"
    },
    "title": {
      "type": "string"
    }
  },
  "required": [
    "message"
  ],
  "additionalProperties": false
}
```

### notify_status

Prints whether notifications will arrive: the service, the permission, the options and the click script.

#### Inputs

This tool takes no inputs.

#### Input schema

```json
{
  "type": "object",
  "properties": {},
  "required": [],
  "additionalProperties": false
}
```

### notify_test

Posts one sample notice of the given kind through the configured backend, which shows it on the screen.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `kind` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "kind": {
      "type": "string"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### notify_uninstall

Stops and removes the notification service; with purge it also deletes the helper app.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `purge` | boolean | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "purge": {
      "type": "boolean"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### tagents_check

Prints what is wrong with the config, one line each, and exits 1 while anything is; prints nothing and exits 0 when it is sound.

#### Inputs

This tool takes no inputs.

#### Input schema

```json
{
  "type": "object",
  "properties": {},
  "required": [],
  "additionalProperties": false
}
```

### tagents_config

Prints the config as tagents reads it, one path and value per line, which includes the account profiles a session can be started on.

#### Inputs

This tool takes no inputs.

#### Input schema

```json
{
  "type": "object",
  "properties": {},
  "required": [],
  "additionalProperties": false
}
```

### tagents_label

Names an agent on the dashboard; K is its session id or pane id, and an empty NAME clears the name back to the window title.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `k` | string | yes |  |
| `name` | string | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "k": {
      "type": "string"
    },
    "name": {
      "type": "string"
    }
  },
  "required": [
    "k",
    "name"
  ],
  "additionalProperties": false
}
```

### tagents_new

Starts a new interactive Claude Code session in DIR (default: the current directory) on the account PROFILE (default: the one the config rules pick), as a window of the tmux server this runs in, which the dashboard lists.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |
| `profile` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "profile": {
      "type": "string"
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### tagents_profile_for

Prints which account profile the config rules pick for DIR (and the tmux SESSION, when given), or ask, without starting anything; prints nothing and exits 1 when no profiles are configured.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | yes |  |
| `session` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "session": {
      "type": "string"
    }
  },
  "required": [
    "dir"
  ],
  "additionalProperties": false
}
```

### tagents_window

Opens a tmux window in DIR that runs COMMAND, one string for the shell, and prints the new pane and where it is; the window closes when the command ends, and it lands in the session that owns DIR on the tmux server this runs in.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | yes |  |
| `command` | string | yes |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "dir": {
      "type": "string"
    },
    "command": {
      "type": "string"
    }
  },
  "required": [
    "dir",
    "command"
  ],
  "additionalProperties": false
}
```
