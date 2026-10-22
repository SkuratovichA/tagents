## Why

Nobody can tell which knowledge documents are read. A runbook every session reaches for looks the same as one nobody has opened in a year, so the documents worth turning into a skill cannot be found. A count taken now costs almost nothing; a count missed cannot be rebuilt later.

## What Changes

- Every `show` and `knowledge_get` records a `get`, and every `search` and `knowledge_search` records a `hit` for each document it returns, as an event in a usage store: a SQLite file of its own, `knowledge-usage.sqlite`, beside the index in use, so that rebuilding the index loses nothing. An event holds the time, the document id, the section heading, the kind and the caller; the text of a query is never stored.
- Recording is best effort: a usage store that is locked, unwritable or corrupt never changes what a read prints or the exit code it returns.
- New verb `usage [--top N] [--since <N>d] [--type T] [--all] [--candidates] [--min-gets N] [--min-days N] [--json]` and MCP tool `knowledge_usage` report, for each document, its `gets`, its `hits`, the number of distinct UTC days with a `get`, and the date of the last `get`, over a window that is 30 days by default. Documents nobody read are listed too; `--candidates` keeps those read often enough, on enough different days, to be worth turning into a skill.
- New location settings `--usage-db` and `TAGENTS_KNOWLEDGE_USAGE_DB`. The variable joins the key of the shared server, so sessions with different usage stores never share a daemon.
- `search` and `show` gain `--verbose`, which says on stderr why a read could not be recorded.
- Recording a new event deletes the events older than 365 days.
- **Stacks on `okf-bundle-format`** (PR #12). Both changes modify "CLI verbs and flags" and "MCP server", so the modified blocks here repeat that change's text with this change's additions, and this change is archived after it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `knowledge`: the usage store and what writes to it, the `usage` verb and the `knowledge_usage` tool, and the CLI verbs, the MCP tool list and the environment of the shared server, which grow with them.

## Impact

- `packages/knowledge`: a new usage module, the path resolution for the store, the CLI, the MCP server, the key of the shared server, the messages (English only) and the tests. The generated `contract.json` and `skills/tagents/references` change with the new verb, flags and tool.
- A new file on the machine, `knowledge-usage.sqlite`, that is not derived from anything and so is never rebuilt: deleting it loses the history. Older copies of the program ignore it.
- "No write tools" stays true of documents. The two read tools now also write an event to the usage store, which is the one exception, and the README and the server's header comment say so.
- Out of scope: ranking by usage (search order does not change), turning a candidate into a skill, syncing usage between machines, storing queries or session ids, and documents in subdirectories.
