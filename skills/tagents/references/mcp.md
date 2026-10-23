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
