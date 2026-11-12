# MCP tools

This file is generated from the code by `pnpm plugin:gen`. Do not edit it by hand: change the code and regenerate.

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

Takes one plugin entry back out of the config.

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

### notify_send

Posts a desktop notification with this message (the words are joined with a space) through the configured backend, which shows it on the screen; a click docks the pane the command runs in; a title over 256 characters or a message over 2048 is refused.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `message` | string[] | yes |  |
| `title` | string | no |  |

#### Input schema

```json
{
  "type": "object",
  "properties": {
    "message": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "minItems": 1
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

### sessions_recent

The latest sessions across every Claude account on this machine, newest first — the same text the sessions CLI prints.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `limit` | integer | no | how many (default 15) |

#### Input schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "limit": {
      "description": "how many (default 15)",
      "type": "integer",
      "exclusiveMinimum": 0,
      "maximum": 50
    }
  }
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
  "$schema": "http://json-schema.org/draft-07/schema#",
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
  ]
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

Starts a new interactive Claude Code session in DIR (default: the current directory) on the account PROFILE (default: the one the config rules pick), as a window of the tmux server this runs in, which the dashboard lists; detach (the default for a tool call) does not show or select the window, prints the new pane and where it is as session:index, and never opens a dialog, so when the rules say to ask which account it fails and names the profiles to pass.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | no |  |
| `profile` | string | no |  |
| `detach` | boolean | no |  |

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
    },
    "detach": {
      "type": "boolean",
      "default": true
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

Opens a tmux window in DIR that runs COMMAND, one string for the shell, and prints the new pane and where it is; the window closes when the command ends, and it lands in the session that owns DIR on the tmux server this runs in; detach (the default for a tool call) does not show or select the window.

#### Inputs

| Input | Type | Required | Description |
|---|---|---|---|
| `dir` | string | yes |  |
| `command` | string | yes |  |
| `detach` | boolean | no |  |

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
    },
    "detach": {
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "dir",
    "command"
  ],
  "additionalProperties": false
}
```
